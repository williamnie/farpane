//! Native Host selection reader. Payload reads are admitted by policy first;
//! TARGETS, each property chunk, INCR length and the whole request are bounded.
//! This connection never opens a window on screen or changes desktop focus.
use bytes::Bytes;
use farpane_protocol::clipboard::{self, Direction, Format, Part, Policy, Token};
use hbb_common::ResultType;
use std::{
    cell::Cell,
    os::fd::{AsRawFd, RawFd},
    time::{Duration, Instant},
};
use x11rb::{
    connection::Connection,
    protocol::{xfixes, xproto::*, Event},
    reexports::x11rb_protocol::xauth::get_auth,
    rust_connection::{DefaultStream, RustConnection},
    CURRENT_TIME, NONE,
};

/// x11rb 0.12 cannot parse the `unix:/tmp/.X11-unix/X<n>` DISPLAY that Mutter
/// gives managed services, so connect to that socket directly. Only the
/// filesystem path is used: GNOME's abstract `@/tmp/.X11-unix/X<n>` listener
/// belongs to gnome-shell, never accepts, and would hang the X11 handshake.
pub(super) fn connect() -> ResultType<(RustConnection, usize)> {
    let display = std::env::var("DISPLAY").unwrap_or_default();
    let Some(socket) = display.strip_prefix("unix:").filter(|v| v.starts_with('/')) else {
        return Ok(RustConnection::connect(None)?);
    };
    let number: u16 = socket
        .rsplit_once("/X")
        .and_then(|(_, n)| n.parse().ok())
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Unsupported X11 display socket"))?;
    let stream = std::os::unix::net::UnixStream::connect(socket)?;
    let stream = DefaultStream::from_unix_stream(stream)?;
    let (family, address) = stream.peer_addr()?;
    let (name, data) = get_auth(family, &address, number)
        .unwrap_or(None)
        .unwrap_or_default();
    Ok((
        RustConnection::connect_to_stream_with_auth_info(stream, 0, name, data)?,
        0,
    ))
}

const CHUNK: usize = 64 * 1024;
const METADATA_LIMIT: usize = 4096;
const DEADLINE: Duration = Duration::from_secs(3);
const OWNER: &[u8] = b"application/x-farpane-clipboard";

pub struct Reader {
    connection: RustConnection,
    window: Window,
    selection: Atom,
    targets: Atom,
    incr: Atom,
    property: Atom,
    formats: Vec<(Format, Atom)>,
    excluded: Vec<Atom>,
    dirty: Cell<bool>,
}
impl Reader {
    pub fn new() -> ResultType<Self> {
        // Wayland sessions reach this only through clipboard_platform's
        // explicit Xwayland fallback when data-control is not granted.
        let (connection, screen) = connect()?;
        let window = connection.generate_id()?;
        connection
            .create_window(
                0,
                window,
                connection.setup().roots[screen].root,
                0,
                0,
                1,
                1,
                0,
                WindowClass::INPUT_ONLY,
                0,
                &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
            )?
            .check()?;
        let atom = |name: &[u8]| -> ResultType<Atom> {
            Ok(connection.intern_atom(false, name)?.reply()?.atom)
        };
        let selection = atom(b"CLIPBOARD")?;
        let targets = atom(b"TARGETS")?;
        let incr = atom(b"INCR")?;
        let property = atom(b"_FARPANE_NATIVE_SELECTION")?;
        let mut formats = Vec::new();
        for (format, name) in [
            (Format::Png, b"image/png".as_slice()),
            (Format::Svg, b"image/svg+xml"),
            (Format::Html, b"text/html"),
            (Format::Rtf, b"text/rtf"),
            (Format::Text, b"UTF8_STRING"),
            (Format::Text, b"text/plain;charset=utf-8"),
            (Format::Text, b"text/plain"),
        ] {
            formats.push((format, atom(name)?));
        }
        let excluded = [
            OWNER,
            b"dyn.com.rustdesk.owner",
            b"text/uri-list",
            b"x-special/gnome-copied-files",
        ]
        .into_iter()
        .map(atom)
        .collect::<ResultType<Vec<_>>>()?;
        xfixes::query_version(&connection, 5, 0)?.reply()?;
        xfixes::select_selection_input(
            &connection,
            window,
            selection,
            xfixes::SelectionEventMask::SET_SELECTION_OWNER
                | xfixes::SelectionEventMask::SELECTION_WINDOW_DESTROY
                | xfixes::SelectionEventMask::SELECTION_CLIENT_CLOSE,
        )?
        .check()?;
        connection.flush()?;
        Ok(Self {
            connection,
            window,
            selection,
            targets,
            incr,
            property,
            formats,
            excluded,
            dirty: Cell::new(false),
        })
    }

    /// Coalesce notifications; a busy X client cannot keep this call running forever.
    pub fn fd(&self) -> RawFd {
        self.connection.stream().as_raw_fd()
    }
    pub fn more(&self) -> bool {
        self.dirty.get()
    }
    pub fn changed(&self) -> ResultType<bool> {
        let mut changed = self.dirty.replace(false);
        for _ in 0..256 {
            match self.connection.poll_for_event()? {
                Some(Event::XfixesSelectionNotify(e)) if e.selection == self.selection => {
                    changed = true
                }
                Some(_) => {}
                None => return Ok(changed),
            }
        }
        self.dirty.set(true);
        Ok(changed)
    }

    pub fn read(
        &self,
        policy: Policy,
        valid: impl Fn() -> bool,
        mut pump: impl FnMut(),
    ) -> ResultType<Vec<Part<Bytes>>> {
        if !policy.any(Direction::Send) || !valid() {
            return Ok(Vec::new());
        }
        let deadline = Instant::now() + DEADLINE;
        let owner = self
            .connection
            .get_selection_owner(self.selection)?
            .reply()?
            .owner;
        if owner == NONE {
            return Ok(Vec::new());
        }
        let targets = self.convert(self.targets, METADATA_LIMIT, deadline, &valid, &mut pump)?;
        if targets.len() % 4 != 0 {
            hbb_common::bail!("Invalid selection targets");
        }
        let targets: Vec<u32> = targets
            .chunks_exact(4)
            .map(|v| u32::from_ne_bytes(v.try_into().unwrap()))
            .collect();
        // Never request a file URI or our own selection's content as plain text.
        if self.excluded.iter().any(|a| targets.contains(a)) {
            return Ok(Vec::new());
        }
        let available = |format| {
            self.formats
                .iter()
                .find(|(f, atom)| *f == format && targets.contains(atom))
                .map(|(_, a)| *a)
        };
        let chosen = if policy.image.send && available(Format::Png).is_some() {
            vec![Format::Png]
        } else if policy.image.send && available(Format::Svg).is_some() {
            vec![Format::Svg]
        } else if policy.rich_text.send
            && [Format::Html, Format::Rtf]
                .into_iter()
                .any(|f| available(f).is_some())
        {
            vec![Format::Html, Format::Rtf, Format::Text]
        } else if policy.text.send {
            vec![Format::Text]
        } else {
            Vec::new()
        };
        let mut parts = Vec::new();
        for format in chosen {
            if let Some(atom) = available(format) {
                let bytes = self.convert(atom, format.limit(), deadline, &valid, &mut pump)?;
                if !bytes.is_empty() {
                    parts.push(Part {
                        format,
                        width: 0,
                        height: 0,
                        bytes: bytes.into(),
                    });
                }
            }
        }
        if !valid()
            || self.dirty.get()
            || self
                .connection
                .get_selection_owner(self.selection)?
                .reply()?
                .owner
                != owner
        {
            hbb_common::bail!("Selection changed during read");
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

    fn convert(
        &self,
        target: Atom,
        limit: usize,
        deadline: Instant,
        valid: &impl Fn() -> bool,
        pump: &mut impl FnMut(),
    ) -> ResultType<Vec<u8>> {
        // A separate unmapped requestor makes late INCR events from abandoned
        // transfers harmless. It is destroyed on every return, including timeout.
        let window = self.connection.generate_id()?;
        self.connection
            .create_window(
                0,
                window,
                self.window,
                0,
                0,
                1,
                1,
                0,
                WindowClass::INPUT_ONLY,
                0,
                &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
            )?
            .check()?;
        let result = (|| {
            self.connection.convert_selection(
                window,
                self.selection,
                target,
                self.property,
                CURRENT_TIME,
            )?;
            self.connection.flush()?;
            let mut incr = false;
            let mut bytes = Vec::new();
            loop {
                pump();
                if !valid() {
                    hbb_common::bail!("Selection read canceled");
                }
                if Instant::now() >= deadline {
                    hbb_common::bail!("Selection read timed out");
                }
                let event = match self.connection.poll_for_event()? {
                    Some(event) => event,
                    None => {
                        // INCR may contain thousands of chunks. Sleeping after
                        // each delete adds an artificial per-chunk delay that
                        // exhausts the unchanged overall deadline. Wake on X11
                        // input, while still servicing cancellation/the writer
                        // within five milliseconds when the source is idle.
                        use hbb_common::libc;
                        let mut fd = libc::pollfd {
                            fd: self.fd(),
                            events: libc::POLLIN,
                            revents: 0,
                        };
                        if unsafe { libc::poll(&mut fd, 1, 5) } < 0 {
                            let error = std::io::Error::last_os_error();
                            if error.kind() != std::io::ErrorKind::Interrupted {
                                return Err(error.into());
                            }
                        } else if fd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0
                        {
                            hbb_common::bail!("Selection connection closed");
                        }
                        continue;
                    }
                };
                if matches!(&event, Event::XfixesSelectionNotify(e) if e.selection == self.selection)
                {
                    self.dirty.set(true);
                }
                let initial = matches!(&event, Event::SelectionNotify(e)
                    if e.requestor == window && e.selection == self.selection && e.target == target);
                if let Event::SelectionNotify(e) = &event {
                    if initial && e.property != self.property {
                        hbb_common::bail!("Selection format unavailable");
                    }
                }
                let chunk = matches!(&event, Event::PropertyNotify(e)
                    if incr && e.window == window && e.atom == self.property && e.state == Property::NEW_VALUE);
                if !initial && !chunk {
                    continue;
                }
                let expected_type = if target == self.targets {
                    AtomEnum::ATOM.into()
                } else {
                    target
                };
                let expected_format = if target == self.targets { 32 } else { 8 };
                let mut offset = 0;
                let mut chunk_bytes = 0;
                loop {
                    if !valid() || Instant::now() >= deadline {
                        hbb_common::bail!("Selection read canceled or timed out");
                    }
                    let reply = self
                        .connection
                        .get_property(
                            false,
                            window,
                            self.property,
                            AtomEnum::ANY,
                            offset,
                            ((CHUNK.min(limit.saturating_sub(bytes.len())).max(1) + 3) / 4) as u32,
                        )?
                        .reply()?;
                    if initial && reply.type_ == self.incr {
                        if incr
                            || reply.format != 32
                            || reply.value.len() != 4
                            || reply.bytes_after != 0
                        {
                            hbb_common::bail!("Invalid incremental selection");
                        }
                        let size =
                            u32::from_ne_bytes(reply.value[..4].try_into().unwrap()) as usize;
                        if size > limit {
                            hbb_common::bail!("Selection exceeds format limit");
                        }
                        incr = true;
                        break;
                    }
                    if reply.type_ != expected_type || reply.format != expected_format {
                        hbb_common::bail!("Invalid selection property type");
                    }
                    let length = bytes
                        .len()
                        .checked_add(reply.value.len())
                        .and_then(|n| n.checked_add(reply.bytes_after as usize));
                    if length.is_none_or(|n| n > limit) {
                        hbb_common::bail!("Selection exceeds format limit");
                    }
                    if bytes.capacity() < bytes.len() + reply.value.len() {
                        let target = bytes
                            .capacity()
                            .saturating_mul(2)
                            .max(bytes.len() + reply.value.len())
                            .min(limit);
                        bytes.reserve_exact(target - bytes.len());
                    }
                    chunk_bytes += reply.value.len();
                    bytes.extend_from_slice(&reply.value);
                    if reply.bytes_after == 0 {
                        break;
                    }
                    if reply.value.is_empty() || reply.value.len() % 4 != 0 {
                        hbb_common::bail!("Invalid selection property offset");
                    }
                    offset += (reply.value.len() / 4) as u32;
                }
                self.connection.delete_property(window, self.property)?;
                self.connection.flush()?;
                if !incr || (!initial && chunk_bytes == 0) {
                    return Ok(bytes);
                }
            }
        })();
        let _ = self.connection.destroy_window(window);
        let _ = self.connection.flush();
        result
    }
}
impl Drop for Reader {
    fn drop(&mut self) {
        let _ = self.connection.destroy_window(self.window);
        let _ = self.connection.flush();
    }
}

pub use super::clipboard_x11_writer::Writer;
