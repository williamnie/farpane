//! Headless data-control clipboard backend. All protocol and pipe work runs on
//! the existing Host clipboard worker; no surface, focus request or Xwayland.
use bytes::Bytes;
use farpane_protocol::clipboard::{self, Direction, Format, Part, Policy, Token};
use hbb_common::{libc, ResultType};
use std::{
    collections::HashMap,
    io,
    os::{
        fd::{AsFd, AsRawFd, FromRawFd, OwnedFd, RawFd},
        unix::{ffi::OsStrExt, net::UnixStream},
    },
    sync::Arc,
    time::{Duration, Instant},
};
use wayland_client::{
    backend::ObjectId,
    event_created_child,
    protocol::{wl_callback, wl_registry, wl_seat},
    Connection, Dispatch, EventQueue, Proxy, QueueHandle,
};
use wayland_protocols::ext::data_control::v1::client::{
    ext_data_control_device_v1 as ext_device, ext_data_control_manager_v1 as ext_manager,
    ext_data_control_offer_v1 as ext_offer, ext_data_control_source_v1 as ext_source,
};
use wayland_protocols_wlr::data_control::v1::client::{
    zwlr_data_control_device_v1 as wlr_device, zwlr_data_control_manager_v1 as wlr_manager,
    zwlr_data_control_offer_v1 as wlr_offer, zwlr_data_control_source_v1 as wlr_source,
};

const CHUNK: usize = 64 * 1024;
const IDLE: Duration = Duration::from_secs(3);
const TOTAL: Duration = Duration::from_secs(30);
const MAX_TRANSFERS: usize = 4;
const RETAINED_LIMIT: usize = 2 * clipboard::IMAGE_LIMIT;
const OWNER: &str = "application/x-farpane-clipboard";
const FORMATS: &[(Format, &str)] = &[
    (Format::Png, "image/png"),
    (Format::Svg, "image/svg+xml"),
    (Format::Html, "text/html"),
    (Format::Rtf, "text/rtf"),
    (Format::Rtf, "application/rtf"),
    (Format::Text, "text/plain;charset=utf-8"),
    (Format::Text, "text/plain;charset=UTF-8"),
    (Format::Text, "text/plain"),
];

enum Manager {
    Ext(ext_manager::ExtDataControlManagerV1),
    Wlr(wlr_manager::ZwlrDataControlManagerV1),
}
enum Device {
    Ext(ext_device::ExtDataControlDeviceV1),
    Wlr(wlr_device::ZwlrDataControlDeviceV1),
}
enum Offer {
    Ext(ext_offer::ExtDataControlOfferV1),
    Wlr(wlr_offer::ZwlrDataControlOfferV1),
}
enum Source {
    Ext(ext_source::ExtDataControlSourceV1),
    Wlr(wlr_source::ZwlrDataControlSourceV1),
}
macro_rules! object {
    ($object:expr, $binding:ident, $body:expr) => {
        match $object {
            Self::Ext($binding) => $body,
            Self::Wlr($binding) => $body,
        }
    };
}
impl Offer {
    fn id(&self) -> ObjectId {
        object!(self, value, value.id())
    }
    fn receive(&self, mime: &str, fd: &OwnedFd) {
        object!(self, value, value.receive(mime.to_owned(), fd.as_fd()));
    }
}
impl Drop for Offer {
    fn drop(&mut self) {
        object!(
            self,
            value,
            if value.is_alive() {
                value.destroy();
            }
        );
    }
}
impl Source {
    fn id(&self) -> ObjectId {
        object!(self, value, value.id())
    }
    fn offer(&self, mime: &str) {
        object!(self, value, value.offer(mime.to_owned()));
    }
}
impl Drop for Source {
    fn drop(&mut self) {
        object!(
            self,
            value,
            if value.is_alive() {
                value.destroy();
            }
        );
    }
}
impl Drop for Device {
    fn drop(&mut self) {
        object!(
            self,
            value,
            if value.is_alive() {
                value.destroy();
            }
        );
    }
}
impl Drop for Manager {
    fn drop(&mut self) {
        object!(
            self,
            value,
            if value.is_alive() {
                value.destroy();
            }
        );
    }
}
struct Offered {
    object: Offer,
    mimes: Vec<String>,
    invalid: bool,
}
struct Selection {
    values: Vec<(&'static str, Bytes)>,
    bytes: usize,
}
struct Owned {
    _object: Source,
    selection: Arc<Selection>,
}
struct Transfer {
    fd: OwnedFd,
    selection: Arc<Selection>,
    index: usize,
    offset: usize,
    started: Instant,
    touched: Instant,
}
#[derive(Default)]
struct Events {
    globals: Vec<(u32, String, u32)>,
    used_globals: Vec<u32>,
    failed: bool,
    sync: u64,
    reading: bool,
    initial_selection: bool,
    changed: bool,
    generation: u64,
    pending: HashMap<ObjectId, Offered>,
    current: Option<Offered>,
    sources: HashMap<ObjectId, Owned>,
    transfers: Vec<Transfer>,
}
impl Events {
    fn offer(&mut self, object: Offer) {
        if self.pending.len() >= 16 {
            self.failed = true;
            return;
        }
        self.pending.insert(
            object.id(),
            Offered {
                object,
                mimes: Vec::new(),
                invalid: false,
            },
        );
    }
    fn mime(&mut self, id: ObjectId, mime: String) {
        if let Some(offer) = self.pending.get_mut(&id) {
            if offer.mimes.len() >= 32 || mime.len() > 256 || mime.contains('\0') {
                offer.invalid = true;
            } else if !offer.mimes.contains(&mime) {
                offer.mimes.push(mime);
            }
        }
    }
    fn selection(&mut self, id: Option<ObjectId>) {
        self.initial_selection = true;
        self.generation = self.generation.wrapping_add(1);
        let offer = id.and_then(|id| self.pending.remove(&id));
        if self.reading {
            self.current = offer;
            self.changed = true;
        }
    }
    fn send(&mut self, id: ObjectId, mime: String, fd: OwnedFd) {
        if self.transfers.len() >= MAX_TRANSFERS {
            return;
        }
        let Some(source) = self.sources.get(&id) else {
            return;
        };
        let Some(index) = source
            .selection
            .values
            .iter()
            .position(|value| value.0 == mime)
        else {
            return;
        };
        let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
        {
            return;
        }
        let now = Instant::now();
        self.transfers.push(Transfer {
            fd,
            selection: source.selection.clone(),
            index,
            offset: 0,
            started: now,
            touched: now,
        });
    }
    fn retained(&self) -> usize {
        let mut values: Vec<&Arc<Selection>> = Vec::new();
        for value in self
            .sources
            .values()
            .map(|v| &v.selection)
            .chain(self.transfers.iter().map(|v| &v.selection))
        {
            if !values.iter().any(|old| Arc::ptr_eq(old, value)) {
                values.push(value);
            }
        }
        values.iter().map(|v| v.bytes).sum()
    }
    fn write_pipes(&mut self) {
        let now = Instant::now();
        self.transfers.retain_mut(|transfer| {
            if now >= transfer.touched + IDLE || now >= transfer.started + TOTAL {
                return false;
            }
            let data = &transfer.selection.values[transfer.index].1;
            let end = (transfer.offset + CHUNK).min(data.len());
            if end == transfer.offset {
                return false;
            }
            let result = unsafe {
                libc::write(
                    transfer.fd.as_raw_fd(),
                    data[transfer.offset..end].as_ptr().cast(),
                    end - transfer.offset,
                )
            };
            if result > 0 {
                transfer.offset += result as usize;
                transfer.touched = Instant::now();
                transfer.offset < data.len()
            } else if result < 0 {
                matches!(
                    io::Error::last_os_error().kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                )
            } else {
                false
            }
        });
    }
}
impl Dispatch<wl_registry::WlRegistry, ()> for Events {
    fn event(
        state: &mut Self,
        _: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_registry::Event::Global {
                name,
                interface,
                version,
            } if [
                "wl_seat",
                "ext_data_control_manager_v1",
                "zwlr_data_control_manager_v1",
            ]
            .contains(&interface.as_str()) =>
            {
                if state.globals.len() >= 16 {
                    state.failed = true;
                } else {
                    state.globals.push((name, interface, version));
                    if !state.used_globals.is_empty()
                        && state.globals.iter().filter(|v| v.1 == "wl_seat").count() != 1
                    {
                        state.failed = true;
                    }
                }
            }
            wl_registry::Event::GlobalRemove { name } => {
                if state.used_globals.contains(&name) {
                    state.failed = true;
                }
                state.globals.retain(|v| v.0 != name);
            }
            _ => {}
        }
    }
}
impl Dispatch<wl_callback::WlCallback, u64> for Events {
    fn event(
        state: &mut Self,
        _: &wl_callback::WlCallback,
        _: wl_callback::Event,
        token: &u64,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        state.sync = *token;
    }
}
impl Dispatch<wl_seat::WlSeat, ()> for Events {
    fn event(
        _: &mut Self,
        _: &wl_seat::WlSeat,
        _: wl_seat::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
macro_rules! dispatch_protocol {
    ($manager:ident,$Manager:ident,$device:ident,$Device:ident,$offer:ident,$Offer:ident,$source:ident,$Source:ident,$variant:ident) => {
        impl Dispatch<$manager::$Manager, ()> for Events {
            fn event(_: &mut Self, _: &$manager::$Manager, _: $manager::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
        }
        impl Dispatch<$device::$Device, ()> for Events {
            fn event(state: &mut Self, _: &$device::$Device, event: $device::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
                match event {
                    $device::Event::DataOffer { id } => state.offer(Offer::$variant(id)),
                    $device::Event::Selection { id } => state.selection(id.map(|v| v.id())),
                    $device::Event::PrimarySelection { id } => { if let Some(id) = id { state.pending.remove(&id.id()); } },
                    $device::Event::Finished => state.failed = true,
                    _ => {}
                }
            }
            event_created_child!(Events, $device::$Device, [ $device::EVT_DATA_OFFER_OPCODE => ($offer::$Offer, ()) ]);
        }
        impl Dispatch<$offer::$Offer, ()> for Events {
            fn event(state: &mut Self, proxy: &$offer::$Offer, event: $offer::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
                if let $offer::Event::Offer { mime_type } = event { state.mime(proxy.id(), mime_type); }
            }
        }
        impl Dispatch<$source::$Source, ()> for Events {
            fn event(state: &mut Self, proxy: &$source::$Source, event: $source::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
                match event {
                    $source::Event::Send { mime_type, fd } => state.send(proxy.id(), mime_type, fd),
                    $source::Event::Cancelled => { state.sources.remove(&proxy.id()); },
                    _ => {}
                }
            }
        }
    }
}
dispatch_protocol!(
    ext_manager,
    ExtDataControlManagerV1,
    ext_device,
    ExtDataControlDeviceV1,
    ext_offer,
    ExtDataControlOfferV1,
    ext_source,
    ExtDataControlSourceV1,
    Ext
);
dispatch_protocol!(
    wlr_manager,
    ZwlrDataControlManagerV1,
    wlr_device,
    ZwlrDataControlDeviceV1,
    wlr_offer,
    ZwlrDataControlOfferV1,
    wlr_source,
    ZwlrDataControlSourceV1,
    Wlr
);

fn poll(fd: RawFd, events: i16, timeout: i32) -> io::Result<i16> {
    let mut value = libc::pollfd {
        fd,
        events,
        revents: 0,
    };
    let result = unsafe { libc::poll(&mut value, 1, timeout) };
    if result < 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            return Ok(0);
        }
        return Err(error);
    }
    Ok(value.revents)
}
fn connect() -> ResultType<Connection> {
    // connect_to_env consumes WAYLAND_SOCKET and mutates process-wide env. A
    // reader and writer need independent protocol connections; never adopt an
    // inherited connection or bypass its restriction via a second endpoint.
    if std::env::var_os("WAYLAND_SOCKET").is_some() {
        hbb_common::bail!("Wayland clipboard cannot consume an inherited connection");
    }
    let display = std::env::var_os("WAYLAND_DISPLAY")
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Wayland display is unavailable"))?;
    let mut path = std::path::PathBuf::from(display);
    if !path.is_absolute() {
        let directory = std::env::var_os("XDG_RUNTIME_DIR")
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Wayland runtime is unavailable"))?;
        let directory = std::path::PathBuf::from(directory);
        if !directory.is_absolute() {
            hbb_common::bail!("Wayland runtime must be absolute");
        }
        path = directory.join(path);
    }
    let bytes = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.is_empty() || bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        hbb_common::bail!("Invalid Wayland socket path");
    }
    address.sun_family = libc::AF_UNIX as _;
    for (to, from) in address.sun_path.iter_mut().zip(bytes) {
        *to = *from as _;
    }
    let fd = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error().into());
    }
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    let size = std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1;
    if unsafe {
        libc::connect(
            fd.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            size as _,
        )
    } < 0
    {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINPROGRESS) {
            return Err(error.into());
        }
        let ready = poll(fd.as_raw_fd(), libc::POLLOUT, IDLE.as_millis() as i32)?;
        if ready == 0 {
            hbb_common::bail!("Wayland connection timed out");
        }
        let mut error = 0i32;
        let mut size = std::mem::size_of_val(&error) as libc::socklen_t;
        if unsafe {
            libc::getsockopt(
                fd.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_ERROR,
                (&mut error as *mut i32).cast(),
                &mut size,
            )
        } < 0
        {
            return Err(io::Error::last_os_error().into());
        }
        if error != 0 {
            return Err(io::Error::from_raw_os_error(error).into());
        }
    }
    Ok(Connection::from_socket(UnixStream::from(fd))?)
}
struct Client {
    connection: Connection,
    queue: EventQueue<Events>,
    state: Events,
    _registry: wl_registry::WlRegistry,
    _seat: wl_seat::WlSeat,
    manager: Manager,
    device: Device,
}
impl Client {
    fn new(reading: bool) -> ResultType<Self> {
        let connection = connect()?;
        let mut queue = connection.new_event_queue();
        let qh = queue.handle();
        let registry = connection.display().get_registry(&qh, ());
        let mut state = Events {
            reading,
            ..Default::default()
        };
        Self::barrier_parts(&connection, &mut queue, &mut state, &|| true)?;
        #[cfg(test)]
        if let Ok(protocol) = std::env::var("FARPANE_PRIVATE_WAYLAND_PROTOCOL") {
            // Only the explicit private test binary can force the fallback;
            // production always negotiates the compositor's real capabilities.
            state.globals.retain(|v| match protocol.as_str() {
                "wlr" => v.1 != "ext_data_control_manager_v1",
                "ext" => v.1 != "zwlr_data_control_manager_v1",
                _ => true,
            });
        }
        if !state.globals.iter().any(|v| {
            matches!(
                v.1.as_str(),
                "ext_data_control_manager_v1" | "zwlr_data_control_manager_v1"
            )
        }) {
            hbb_common::bail!("Wayland compositor does not grant data-control");
        }
        let seats: Vec<_> = state.globals.iter().filter(|v| v.1 == "wl_seat").collect();
        // Do not silently share between seats when no seat was selected by the
        // product. Single-seat capability is explicit; no focus workaround.
        if seats.len() != 1 {
            hbb_common::bail!("Wayland clipboard requires one unambiguous seat");
        }
        let (seat_id, _, seat_version) = seats[0];
        let seat =
            registry.bind::<wl_seat::WlSeat, _, _>(*seat_id, (*seat_version).min(2), &qh, ());
        state.used_globals.push(*seat_id);
        let manager = if let Some((id, _, version)) = state
            .globals
            .iter()
            .find(|v| v.1 == "ext_data_control_manager_v1")
        {
            state.used_globals.push(*id);
            Manager::Ext(registry.bind(*id, (*version).min(1), &qh, ()))
        } else if let Some((id, _, version)) = state
            .globals
            .iter()
            .find(|v| v.1 == "zwlr_data_control_manager_v1")
        {
            state.used_globals.push(*id);
            Manager::Wlr(registry.bind(*id, (*version).min(2), &qh, ()))
        } else {
            hbb_common::bail!("Wayland compositor does not grant data-control");
        };
        let device = match &manager {
            Manager::Ext(v) => Device::Ext(v.get_data_device(&seat, &qh, ())),
            Manager::Wlr(v) => Device::Wlr(v.get_data_device(&seat, &qh, ())),
        };
        Self::barrier_parts(&connection, &mut queue, &mut state, &|| true)?;
        if !state.initial_selection {
            hbb_common::bail!("Wayland clipboard did not become ready");
        }
        Ok(Self {
            connection,
            queue,
            state,
            _registry: registry,
            _seat: seat,
            manager,
            device,
        })
    }
    fn fd(&self) -> RawFd {
        self.connection.as_fd().as_raw_fd()
    }
    fn dispatch_parts(
        connection: &Connection,
        queue: &mut EventQueue<Events>,
        state: &mut Events,
    ) -> ResultType<()> {
        queue.dispatch_pending(state)?;
        if let Some(guard) = queue.prepare_read() {
            let ready = poll(connection.as_fd().as_raw_fd(), libc::POLLIN, 0)?;
            if ready & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                hbb_common::bail!("Wayland connection closed");
            }
            if ready & libc::POLLIN != 0 {
                guard.read()?;
            }
        }
        queue.dispatch_pending(state)?;
        if state.failed {
            hbb_common::bail!("Wayland clipboard capability was withdrawn");
        }
        connection.flush()?;
        Ok(())
    }
    fn dispatch(&mut self) -> ResultType<()> {
        Self::dispatch_parts(&self.connection, &mut self.queue, &mut self.state)?;
        self.state.write_pipes();
        Ok(())
    }
    fn barrier_parts(
        connection: &Connection,
        queue: &mut EventQueue<Events>,
        state: &mut Events,
        valid: &impl Fn() -> bool,
    ) -> ResultType<()> {
        let serial = state
            .sync
            .checked_add(1)
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?;
        connection.display().sync(&queue.handle(), serial);
        let deadline = Instant::now() + IDLE;
        while state.sync != serial {
            if !valid() || Instant::now() >= deadline {
                hbb_common::bail!("Wayland clipboard roundtrip canceled or timed out");
            }
            Self::dispatch_parts(connection, queue, state)?;
            state.write_pipes();
            if state.sync != serial {
                poll(connection.as_fd().as_raw_fd(), libc::POLLIN, 5)?;
            }
        }
        Ok(())
    }
}

pub struct Reader(Client);
impl Reader {
    pub fn new() -> ResultType<Self> {
        Ok(Self(Client::new(true)?))
    }
    pub fn fd(&self) -> RawFd {
        self.0.fd()
    }
    pub fn more(&self) -> bool {
        self.0.state.changed
    }
    pub fn changed(&mut self) -> ResultType<bool> {
        self.0.dispatch()?;
        Ok(std::mem::take(&mut self.0.state.changed))
    }
    pub fn read(
        &mut self,
        policy: Policy,
        valid: impl Fn() -> bool,
        mut pump: impl FnMut(),
    ) -> ResultType<Vec<Part<Bytes>>> {
        if !policy.any(Direction::Send) || !valid() {
            return Ok(Vec::new());
        }
        let Some(offer) = self.0.state.current.as_ref() else {
            return Ok(Vec::new());
        };
        if offer.invalid
            || [
                OWNER,
                "dyn.com.rustdesk.owner",
                "text/uri-list",
                "x-special/gnome-copied-files",
            ]
            .iter()
            .any(|v| offer.mimes.iter().any(|m| m == v))
        {
            return Ok(Vec::new());
        }
        let available = |format| {
            FORMATS
                .iter()
                .find(|(f, mime)| *f == format && offer.mimes.iter().any(|v| v == mime))
                .map(|v| v.1)
        };
        let chosen = if policy.image.send && available(Format::Png).is_some() {
            vec![Format::Png]
        } else if policy.image.send && available(Format::Svg).is_some() {
            vec![Format::Svg]
        } else if policy.rich_text.send
            && [Format::Html, Format::Rtf]
                .iter()
                .any(|f| available(*f).is_some())
        {
            vec![Format::Html, Format::Rtf, Format::Text]
        } else if policy.text.send {
            vec![Format::Text]
        } else {
            Vec::new()
        };
        let chosen: Vec<_> = chosen
            .into_iter()
            .filter_map(|f| available(f).map(|mime| (f, mime)))
            .collect();
        let generation = self.0.state.generation;
        let deadline = Instant::now() + IDLE;
        let mut parts = Vec::new();
        for (format, mime) in chosen {
            if !valid() || self.0.state.generation != generation || Instant::now() >= deadline {
                hbb_common::bail!("Wayland clipboard read canceled");
            }
            let mut fds = [-1; 2];
            if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } < 0 {
                return Err(io::Error::last_os_error().into());
            }
            let read = unsafe { OwnedFd::from_raw_fd(fds[0]) };
            let write = unsafe { OwnedFd::from_raw_fd(fds[1]) };
            // The source receives a blocking writer, as normal Wayland clients
            // expect; only our independent read end is nonblocking.
            if unsafe { libc::fcntl(read.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
                return Err(io::Error::last_os_error().into());
            }
            self.0
                .state
                .current
                .as_ref()
                .unwrap()
                .object
                .receive(mime, &write);
            self.0.connection.flush()?;
            drop(write);
            let mut bytes = Vec::new();
            let mut chunk = [0u8; CHUNK];
            loop {
                pump();
                self.0.dispatch()?;
                if !valid() || self.0.state.generation != generation || Instant::now() >= deadline {
                    hbb_common::bail!("Wayland selection changed, canceled or timed out");
                }
                let limit = (format.limit().saturating_sub(bytes.len()) + 1).min(CHUNK);
                let count =
                    unsafe { libc::read(read.as_raw_fd(), chunk.as_mut_ptr().cast(), limit) };
                if count == 0 {
                    break;
                }
                if count > 0 {
                    if bytes.len() + count as usize > format.limit() {
                        hbb_common::bail!("Wayland clipboard format exceeds limit");
                    }
                    bytes.extend_from_slice(&chunk[..count as usize]);
                } else {
                    match io::Error::last_os_error().kind() {
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted => {
                            poll(read.as_raw_fd(), libc::POLLIN, 5)?;
                        }
                        _ => return Err(io::Error::last_os_error().into()),
                    }
                }
            }
            if !bytes.is_empty() {
                parts.push(Part {
                    format,
                    width: 0,
                    height: 0,
                    bytes: bytes.into(),
                });
            }
        }
        if !parts.is_empty() {
            clipboard::describe(
                Token {
                    serial: 1,
                    revision: 1,
                },
                &parts,
            )?;
        }
        Ok(parts)
    }
}
pub struct Writer(Client);
impl Writer {
    pub fn new() -> ResultType<Self> {
        Ok(Self(Client::new(false)?))
    }
    pub fn more(&self) -> bool {
        false
    }
    pub fn empty(&self) -> bool {
        self.0.state.sources.is_empty() && self.0.state.transfers.is_empty()
    }
    pub fn poll_fds(&self, fds: &mut Vec<libc::pollfd>) {
        fds.push(libc::pollfd {
            fd: self.0.fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        fds.extend(self.0.state.transfers.iter().map(|v| libc::pollfd {
            fd: v.fd.as_raw_fd(),
            events: libc::POLLOUT,
            revents: 0,
        }));
    }
    pub fn deadline(&self) -> Option<Instant> {
        self.0
            .state
            .transfers
            .iter()
            .map(|v| (v.touched + IDLE).min(v.started + TOTAL))
            .min()
    }
    pub fn dispatch(&mut self) -> ResultType<()> {
        self.0.dispatch()
    }
    pub fn set(&mut self, parts: Vec<Part<Bytes>>, valid: impl Fn() -> bool) -> ResultType<()> {
        clipboard::describe(
            Token {
                serial: 1,
                revision: 1,
            },
            &parts,
        )?;
        self.0.dispatch()?;
        let mut values = Vec::new();
        let mut bytes = 0;
        for part in parts {
            if !valid() {
                hbb_common::bail!("Wayland clipboard write canceled");
            }
            let (format, value) = if part.format == Format::Rgba {
                (
                    Format::Png,
                    super::clipboard_x11_writer::rgba_png(part, &valid)?,
                )
            } else {
                (part.format, part.bytes)
            };
            bytes += value.len();
            for (_, mime) in FORMATS.iter().filter(|(f, _)| *f == format) {
                values.push((*mime, value.clone()));
            }
        }
        if bytes + self.0.state.retained() > RETAINED_LIMIT || self.0.state.sources.len() >= 8 {
            hbb_common::bail!("Wayland clipboard retained data budget exceeded");
        }
        values.push((OWNER, Bytes::from_static(&[1])));
        let source = match &self.0.manager {
            Manager::Ext(v) => Source::Ext(v.create_data_source(&self.0.queue.handle(), ())),
            Manager::Wlr(v) => Source::Wlr(v.create_data_source(&self.0.queue.handle(), ())),
        };
        for (mime, _) in &values {
            source.offer(mime);
        }
        if !valid() {
            hbb_common::bail!("Wayland clipboard write canceled");
        }
        match (&self.0.device, &source) {
            (Device::Ext(d), Source::Ext(s)) => d.set_selection(Some(s)),
            (Device::Wlr(d), Source::Wlr(s)) => d.set_selection(Some(s)),
            _ => unreachable!(),
        }
        let id = source.id();
        self.0.state.sources.insert(
            id.clone(),
            Owned {
                _object: source,
                selection: Arc::new(Selection { values, bytes }),
            },
        );
        Client::barrier_parts(
            &self.0.connection,
            &mut self.0.queue,
            &mut self.0.state,
            &valid,
        )?;
        if !self.0.state.sources.contains_key(&id) {
            hbb_common::bail!("Wayland clipboard ownership was not retained");
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "clipboard_wayland_tests.rs"]
mod tests;
