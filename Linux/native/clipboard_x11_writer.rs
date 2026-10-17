//! X11 selection owner, driven by the existing Host worker. No GTK, arboard,
//! per-paste threads, or image-sized copy for PNG/SVG/text. INCR is demand driven.
use bytes::Bytes;
use farpane_protocol::clipboard::{self, Format, Part, Token};
use hbb_common::ResultType;
use std::{
    io::{self, Write},
    os::fd::{AsRawFd, RawFd},
    sync::Arc,
    time::{Duration, Instant},
};
use x11rb::{
    connection::Connection,
    protocol::{xproto::*, Event},
    rust_connection::RustConnection,
    wrapper::ConnectionExt as _,
    CURRENT_TIME, NONE,
};

const CHUNK: usize = 64 * 1024;
const MAX_TRANSFERS: usize = 4;
const RETAINED_LIMIT: usize = 2 * clipboard::IMAGE_LIMIT;
const IDLE: Duration = Duration::from_secs(3);
const TOTAL: Duration = Duration::from_secs(30);

struct Selection {
    values: Vec<(Atom, Bytes)>,
    bytes: usize,
    timestamp: u32,
}
struct Transfer {
    window: Window,
    property: Atom,
    target: Atom,
    selection: Arc<Selection>,
    index: usize,
    offset: usize,
    started: Instant,
    touched: Instant,
}
pub struct Writer {
    connection: RustConnection,
    window: Window,
    selection: Atom,
    targets: Atom,
    timestamp: Atom,
    multiple: Atom,
    atom_pair: Atom,
    incr: Atom,
    clock: Atom,
    owner: Atom,
    text: Vec<Atom>,
    formats: Vec<(Format, Atom)>,
    current: Option<Arc<Selection>>,
    transfers: Vec<Transfer>,
    more: bool,
}
impl Writer {
    pub fn new() -> ResultType<Self> {
        let (connection, screen) = RustConnection::connect(None)?;
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
        let timestamp = atom(b"TIMESTAMP")?;
        let multiple = atom(b"MULTIPLE")?;
        let atom_pair = atom(b"ATOM_PAIR")?;
        let incr = atom(b"INCR")?;
        let clock = atom(b"_FARPANE_SELECTION_CLOCK")?;
        let owner = atom(b"application/x-farpane-clipboard")?;
        let text = [
            b"UTF8_STRING".as_slice(),
            b"text/plain;charset=utf-8",
            b"text/plain",
        ]
        .into_iter()
        .map(atom)
        .collect::<ResultType<Vec<_>>>()?;
        let formats = [
            (Format::Html, b"text/html".as_slice()),
            (Format::Rtf, b"text/rtf"),
            (Format::Png, b"image/png"),
            (Format::Svg, b"image/svg+xml"),
        ]
        .into_iter()
        .map(|(f, n)| Ok((f, atom(n)?)))
        .collect::<ResultType<Vec<_>>>()?;
        connection.flush()?;
        Ok(Self {
            connection,
            window,
            selection,
            targets,
            timestamp,
            multiple,
            atom_pair,
            incr,
            clock,
            owner,
            text,
            formats,
            current: None,
            transfers: Vec::new(),
            more: false,
        })
    }
    pub fn fd(&self) -> RawFd {
        self.connection.stream().as_raw_fd()
    }
    pub fn more(&self) -> bool {
        self.more
    }
    pub fn empty(&self) -> bool {
        self.current.is_none() && self.transfers.is_empty()
    }
    pub fn deadline(&self) -> Option<Instant> {
        self.transfers
            .iter()
            .map(|t| (t.touched + IDLE).min(t.started + TOTAL))
            .min()
    }
    #[cfg(test)]
    pub fn retained_bytes(&self) -> usize {
        let mut selections: Vec<&Arc<Selection>> = Vec::with_capacity(MAX_TRANSFERS + 1);
        if let Some(s) = self.current.as_ref() {
            selections.push(s);
        }
        for t in &self.transfers {
            if !selections.iter().any(|s| Arc::ptr_eq(s, &t.selection)) {
                selections.push(&t.selection);
            }
        }
        selections.iter().map(|s| s.bytes).sum()
    }
    fn can_replace(&self, bytes: usize) -> bool {
        let mut retained: Vec<&Arc<Selection>> = Vec::with_capacity(MAX_TRANSFERS);
        for t in &self.transfers {
            if !retained.iter().any(|s| Arc::ptr_eq(s, &t.selection)) {
                retained.push(&t.selection);
            }
        }
        bytes + retained.iter().map(|s| s.bytes).sum::<usize>() <= RETAINED_LIMIT
    }
    pub fn set(&mut self, parts: Vec<Part<Bytes>>, valid: impl Fn() -> bool) -> ResultType<()> {
        clipboard::describe(
            Token {
                serial: 1,
                revision: 1,
            },
            &parts,
        )?;
        let mut values = Vec::with_capacity(6);
        let mut size = 0;
        for p in parts {
            if !valid() {
                hbb_common::bail!("Clipboard write canceled");
            }
            let (format, bytes) = if p.format == Format::Rgba {
                (Format::Png, rgba_png(p, &valid)?)
            } else {
                (p.format, p.bytes)
            };
            size += bytes.len();
            if format == Format::Text {
                for atom in &self.text {
                    values.push((*atom, bytes.clone()));
                }
            } else {
                let atom = self
                    .formats
                    .iter()
                    .find(|(f, _)| *f == format)
                    .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?
                    .1;
                values.push((atom, bytes));
            }
        }
        if !self.can_replace(size) {
            hbb_common::bail!("Clipboard readers are retaining the allowed data budget");
        }
        // Obtain a real X timestamp. While waiting, finish older paste requests.
        self.connection.change_property8(
            PropMode::REPLACE,
            self.window,
            self.clock,
            AtomEnum::INTEGER,
            &[1],
        )?;
        self.connection.flush()?;
        let deadline = Instant::now() + IDLE;
        let time = loop {
            if !valid() || Instant::now() >= deadline {
                hbb_common::bail!("Clipboard clock canceled or timed out");
            }
            match self.connection.poll_for_event()? {
                Some(Event::PropertyNotify(e))
                    if e.window == self.window && e.atom == self.clock =>
                {
                    break e.time
                }
                Some(event) => self.event(event),
                None => std::thread::sleep(Duration::from_millis(1)),
            }
        };
        if !valid() {
            hbb_common::bail!("Clipboard write canceled");
        }
        self.connection
            .set_selection_owner(self.window, self.selection, time)?
            .check()?;
        if self
            .connection
            .get_selection_owner(self.selection)?
            .reply()?
            .owner
            != self.window
        {
            hbb_common::bail!("Clipboard selection changed before write");
        }
        values.push((self.owner, Bytes::from_static(&[1])));
        self.current = Some(Arc::new(Selection {
            values,
            bytes: size,
            timestamp: time,
        }));
        self.more = true;
        Ok(())
    }
    /// Return promptly even if a local application floods selection requests.
    pub fn dispatch(&mut self) -> ResultType<()> {
        self.more = false;
        for _ in 0..256 {
            match self.connection.poll_for_event()? {
                Some(event) => self.event(event),
                None => break,
            }
            self.more = true;
        }
        let now = Instant::now();
        let mut expired = Vec::new();
        self.transfers.retain(|t| {
            let keep = now < t.touched + IDLE && now < t.started + TOTAL;
            if !keep {
                expired.push(t.window);
            }
            keep
        });
        for window in expired {
            self.unwatch(window);
        }
        self.connection.flush()?;
        Ok(())
    }
    fn event(&mut self, event: Event) {
        match event {
            Event::SelectionRequest(e) => {
                let property = if e.property == NONE {
                    e.target
                } else {
                    e.property
                };
                let valid = self.current.as_ref().is_some_and(|s| {
                    e.time == CURRENT_TIME || (e.time.wrapping_sub(s.timestamp) as i32) >= 0
                }) && e.owner == self.window
                    && e.selection == self.selection;
                let okay = valid
                    && if e.target == self.multiple {
                        e.property != NONE && self.multi(e.requestor, e.property).is_ok()
                    } else {
                        self.deliver(e.requestor, property, e.target).is_ok()
                    };
                let response = SelectionNotifyEvent {
                    response_type: SELECTION_NOTIFY_EVENT,
                    sequence: 0,
                    time: e.time,
                    requestor: e.requestor,
                    selection: e.selection,
                    target: e.target,
                    property: if okay { property } else { NONE },
                };
                // A vanished/malformed requestor must not kill the Host provider.
                let _ =
                    self.connection
                        .send_event(false, e.requestor, EventMask::NO_EVENT, response);
            }
            Event::SelectionClear(e) if e.selection == self.selection => {
                if self
                    .current
                    .as_ref()
                    .is_some_and(|s| (e.time.wrapping_sub(s.timestamp) as i32) >= 0)
                {
                    self.current = None;
                }
            }
            Event::DestroyNotify(e) => {
                self.transfers.retain(|t| t.window != e.window);
            }
            Event::PropertyNotify(e) if e.state == Property::DELETE => {
                if let Some(index) = self
                    .transfers
                    .iter()
                    .position(|t| t.window == e.window && t.property == e.atom)
                {
                    let transfer = &mut self.transfers[index];
                    let bytes = &transfer.selection.values[transfer.index].1;
                    let end = (transfer.offset + CHUNK).min(bytes.len());
                    let final_chunk = end == transfer.offset;
                    let result = self
                        .connection
                        .change_property8(
                            PropMode::REPLACE,
                            transfer.window,
                            transfer.property,
                            transfer.target,
                            &bytes[transfer.offset..end],
                        )
                        .map(|cookie| cookie.check());
                    let okay = matches!(result, Ok(Ok(())));
                    transfer.offset = end;
                    transfer.touched = Instant::now();
                    if !okay || final_chunk {
                        let window = self.transfers.swap_remove(index).window;
                        self.unwatch(window);
                    }
                }
            }
            _ => {}
        }
    }
    fn unwatch(&self, window: Window) {
        if !self.transfers.iter().any(|t| t.window == window) {
            let _ = self.connection.change_window_attributes(
                window,
                &ChangeWindowAttributesAux::new().event_mask(EventMask::NO_EVENT),
            );
        }
    }
    fn deliver(&mut self, window: Window, property: Atom, target: Atom) -> ResultType<()> {
        if window == NONE || window == self.window || property == NONE {
            hbb_common::bail!("Invalid clipboard requestor");
        }
        let selection = self
            .current
            .as_ref()
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
        if self
            .transfers
            .iter()
            .any(|t| t.window == window && t.property == property)
        {
            hbb_common::bail!("Clipboard request already active");
        }
        if target == self.targets {
            let mut atoms = vec![self.targets, self.timestamp, self.multiple];
            atoms.extend(selection.values.iter().map(|(atom, _)| *atom));
            self.connection
                .change_property32(PropMode::REPLACE, window, property, AtomEnum::ATOM, &atoms)?
                .check()?;
        } else if target == self.timestamp {
            self.connection
                .change_property32(
                    PropMode::REPLACE,
                    window,
                    property,
                    AtomEnum::INTEGER,
                    &[selection.timestamp],
                )?
                .check()?;
        } else {
            let index = selection
                .values
                .iter()
                .position(|(atom, _)| *atom == target)
                .ok_or_else(|| io::Error::from(io::ErrorKind::Unsupported))?;
            let bytes = &selection.values[index].1;
            if bytes.len() <= CHUNK {
                self.connection
                    .change_property8(PropMode::REPLACE, window, property, target, bytes)?
                    .check()?;
            } else {
                if self.transfers.len() >= MAX_TRANSFERS {
                    hbb_common::bail!("Clipboard request limit reached");
                }
                self.connection
                    .change_window_attributes(
                        window,
                        &ChangeWindowAttributesAux::new()
                            .event_mask(EventMask::PROPERTY_CHANGE | EventMask::STRUCTURE_NOTIFY),
                    )?
                    .check()?;
                if let Err(error) = self
                    .connection
                    .change_property32(
                        PropMode::REPLACE,
                        window,
                        property,
                        self.incr,
                        &[bytes.len() as u32],
                    )?
                    .check()
                {
                    self.unwatch(window);
                    return Err(error.into());
                }
                self.transfers.push(Transfer {
                    window,
                    property,
                    target,
                    selection: selection.clone(),
                    index,
                    offset: 0,
                    started: Instant::now(),
                    touched: Instant::now(),
                });
            }
        }
        Ok(())
    }
    fn multi(&mut self, window: Window, property: Atom) -> ResultType<()> {
        let reply = self
            .connection
            .get_property(false, window, property, AtomEnum::ANY, 0, 32)?
            .reply()?;
        if ![self.atom_pair, AtomEnum::ATOM.into()].contains(&reply.type_)
            || reply.format != 32
            || reply.bytes_after != 0
            || reply.value.len() % 8 != 0
            || reply.value.is_empty()
        {
            hbb_common::bail!("Invalid multiple clipboard request");
        }
        let mut pairs = reply.value32().unwrap().collect::<Vec<_>>();
        let mut used = vec![property];
        for pair in pairs.chunks_exact_mut(2) {
            if pair[0] == self.multiple
                || used.contains(&pair[1])
                || self.deliver(window, pair[1], pair[0]).is_err()
            {
                pair[1] = NONE;
            } else {
                used.push(pair[1]);
            }
        }
        self.connection
            .change_property32(PropMode::REPLACE, window, property, self.atom_pair, &pairs)?
            .check()?;
        Ok(())
    }
}
impl Drop for Writer {
    fn drop(&mut self) {
        let _ = self.connection.destroy_window(self.window);
        let _ = self.connection.flush();
    }
}

pub(super) fn rgba_png(part: Part<Bytes>, valid: &impl Fn() -> bool) -> io::Result<Bytes> {
    struct Bounded<'a, F> {
        bytes: Vec<u8>,
        valid: &'a F,
    }
    impl<F: Fn() -> bool> Write for Bounded<'_, F> {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            if !(self.valid)() {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            let size = self
                .bytes
                .len()
                .checked_add(data.len())
                .ok_or(io::ErrorKind::InvalidData)?;
            if size > clipboard::IMAGE_LIMIT {
                return Err(io::ErrorKind::InvalidData.into());
            }
            if size > self.bytes.capacity() {
                let cap = self
                    .bytes
                    .capacity()
                    .saturating_mul(2)
                    .max(size)
                    .min(clipboard::IMAGE_LIMIT);
                self.bytes.reserve_exact(cap - self.bytes.len());
            }
            self.bytes.extend_from_slice(data);
            Ok(data.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let mut sink = Bounded {
        bytes: Vec::new(),
        valid,
    };
    {
        let mut encoder = repng::Options::fastest(part.width, part.height).build(&mut sink)?;
        for row in part.bytes.chunks_exact(part.width as usize * 4) {
            if !valid() {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            encoder.write(row)?;
        }
        encoder.finish()?;
    }
    Ok(sink.bytes.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        io::{BufRead, BufReader},
        path::{Path, PathBuf},
        process::{Child, Command, Stdio},
    };

    #[test]
    fn rgba_encoding_is_bounded_and_cancelable_before_any_platform_side_effect() {
        let part = || Part {
            format: Format::Rgba,
            width: 2,
            height: 1,
            bytes: Bytes::from_static(&[1, 2, 3, 0, 9, 8, 7, 255]),
        };
        assert_eq!(
            rgba_png(part(), &|| false).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
        let result = rgba_png(part(), &|| true).unwrap();
        assert_eq!(clipboard::png_dimensions(&result).unwrap(), (2, 1));
        assert!(result.len() < 256);
    }
    fn pump(writer: &mut Writer, child: &mut Child) {
        let until = Instant::now() + Duration::from_secs(12);
        loop {
            writer.dispatch().unwrap();
            if let Some(exit) = child.try_wait().unwrap() {
                assert!(exit.success(), "requestor failed: {exit}");
                break;
            }
            assert!(Instant::now() < until, "requestor timed out");
            if !writer.more() {
                let mut fd = hbb_common::libc::pollfd {
                    fd: writer.fd(),
                    events: hbb_common::libc::POLLIN,
                    revents: 0,
                };
                unsafe {
                    hbb_common::libc::poll(&mut fd, 1, 10);
                }
            }
        }
        writer.dispatch().unwrap();
    }
    fn fetch(writer: &mut Writer, root: &Path, mime: &str, name: &str) {
        let mut child = Command::new(root.join("clipboard-fixture"))
            .args(["get-data", ":91", mime])
            .arg(root.join(name))
            .stdout(Stdio::null())
            .stderr(fs::File::create(root.join(format!("{name}.log"))).unwrap())
            .spawn()
            .unwrap();
        pump(writer, &mut child);
    }
    fn png(path: &Path) -> Part<Bytes> {
        Part {
            format: Format::Png,
            width: 0,
            height: 0,
            bytes: fs::read(path).unwrap().into(),
        }
    }
    fn settle(writer: &mut Writer, millis: u64) {
        let until = Instant::now() + Duration::from_millis(millis);
        while Instant::now() < until {
            writer.dispatch().unwrap();
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    struct Requestor {
        connection: RustConnection,
        root: Window,
        selection: Atom,
        property: Atom,
        target: Atom,
    }
    impl Requestor {
        fn window(&self) -> Window {
            let window = self.connection.generate_id().unwrap();
            self.connection
                .create_window(
                    0,
                    window,
                    self.root,
                    0,
                    0,
                    1,
                    1,
                    0,
                    WindowClass::INPUT_ONLY,
                    0,
                    &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
                )
                .unwrap()
                .check()
                .unwrap();
            window
        }
        fn convert(
            &self,
            writer: &mut Writer,
            window: Window,
            target: Atom,
            property: Atom,
        ) -> SelectionNotifyEvent {
            self.connection
                .convert_selection(window, self.selection, target, property, CURRENT_TIME)
                .unwrap();
            self.connection.flush().unwrap();
            let until = Instant::now() + Duration::from_secs(1);
            loop {
                writer.dispatch().unwrap();
                if let Some(Event::SelectionNotify(e)) = self.connection.poll_for_event().unwrap() {
                    if e.requestor == window {
                        return e;
                    }
                }
                assert!(Instant::now() < until);
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        fn metadata(&self, writer: &mut Writer) {
            let window = self.window();
            let atom = |s: &[u8]| {
                self.connection
                    .intern_atom(false, s)
                    .unwrap()
                    .reply()
                    .unwrap()
                    .atom
            };
            let targets = atom(b"_TEST_TARGETS");
            let stamp = atom(b"_TEST_TIMESTAMP");
            let missing = atom(b"_TEST_MISSING");
            let unsupported = atom(b"application/x-farpane-unsupported-test");
            let values = [
                writer.targets,
                targets,
                writer.timestamp,
                stamp,
                unsupported,
                missing,
                writer.multiple,
                missing,
                writer.targets,
                targets,
            ];
            self.connection
                .change_property32(
                    PropMode::REPLACE,
                    window,
                    self.property,
                    writer.atom_pair,
                    &values,
                )
                .unwrap()
                .check()
                .unwrap();
            assert_eq!(
                self.convert(writer, window, writer.multiple, self.property)
                    .property,
                self.property
            );
            let read = |property: Atom| {
                self.connection
                    .get_property(false, window, property, AtomEnum::ANY, 0, 64)
                    .unwrap()
                    .reply()
                    .unwrap()
            };
            let pairs = read(self.property).value32().unwrap().collect::<Vec<_>>();
            assert_eq!(&pairs[..4], &values[..4]);
            assert_eq!(pairs[5], NONE);
            assert_eq!(pairs[7], NONE);
            assert_eq!(pairs[9], NONE);
            let metadata = read(targets).value32().unwrap().collect::<Vec<_>>();
            assert!(
                metadata.contains(&writer.targets)
                    && metadata.contains(&writer.timestamp)
                    && metadata.contains(&writer.multiple)
            );
            let timestamp = read(stamp);
            assert_eq!(timestamp.type_, u32::from(AtomEnum::INTEGER));
            assert_eq!(
                timestamp.value32().unwrap().next().unwrap(),
                writer.current.as_ref().unwrap().timestamp
            );
            assert_eq!(read(missing).type_, NONE);
            assert_eq!(
                self.convert(writer, window, writer.multiple, NONE).property,
                NONE
            );
            self.connection
                .change_property32(
                    PropMode::REPLACE,
                    window,
                    self.property,
                    writer.atom_pair,
                    &[unsupported; 34],
                )
                .unwrap()
                .check()
                .unwrap();
            assert_eq!(
                self.convert(writer, window, writer.multiple, self.property)
                    .property,
                NONE
            );
            self.connection.destroy_window(window).unwrap();
            self.connection.flush().unwrap();
        }
        fn new() -> Self {
            let (connection, screen) = RustConnection::connect(None).unwrap();
            let root = connection.setup().roots[screen].root;
            let atom = |s: &[u8]| {
                connection
                    .intern_atom(false, s)
                    .unwrap()
                    .reply()
                    .unwrap()
                    .atom
            };
            let selection = atom(b"CLIPBOARD");
            let property = atom(b"_TEST_CLIPBOARD");
            let target = atom(b"image/png");
            Self {
                connection,
                root,
                selection,
                property,
                target,
            }
        }
        fn request(&self, writer: &mut Writer, allowed: bool) -> Window {
            let window = self.connection.generate_id().unwrap();
            self.connection
                .create_window(
                    0,
                    window,
                    self.root,
                    0,
                    0,
                    1,
                    1,
                    0,
                    WindowClass::INPUT_ONLY,
                    0,
                    &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
                )
                .unwrap()
                .check()
                .unwrap();
            self.connection
                .convert_selection(
                    window,
                    self.selection,
                    self.target,
                    self.property,
                    CURRENT_TIME,
                )
                .unwrap();
            self.connection.flush().unwrap();
            let until = Instant::now() + Duration::from_secs(1);
            loop {
                writer.dispatch().unwrap();
                if let Some(Event::SelectionNotify(e)) = self.connection.poll_for_event().unwrap() {
                    if e.requestor == window {
                        assert_eq!(e.property != NONE, allowed);
                        return window;
                    }
                }
                assert!(Instant::now() < until);
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    }
    #[test]
    #[ignore = "requires the private Xvfb and synthetic files created by native_clipboard_writer_smoke.py"]
    fn private_x11_large_selection_lifecycle() {
        assert!(Path::new("/.dockerenv").is_file());
        assert_eq!(std::env::var("DISPLAY").unwrap(), ":91");
        let root = PathBuf::from(std::env::var("FARPANE_PRIVATE_CLIPBOARD_WRITER_TEST").unwrap());
        assert!(root.starts_with("/workspace/Build/Linux/clipboard-writer-smoke"));
        let before_threads = fs::read_dir("/proc/self/task").unwrap().count();
        let mut writer = Writer::new().unwrap();
        fs::write(
            root.join("before-smaps.txt"),
            fs::read("/proc/self/smaps_rollup").unwrap(),
        )
        .unwrap();
        writer
            .set(
                vec![Part {
                    format: Format::Rgba,
                    width: 2,
                    height: 1,
                    bytes: Bytes::from_static(&[1, 2, 3, 0, 9, 8, 7, 255]),
                }],
                || true,
            )
            .unwrap();
        fetch(&mut writer, &root, "image/png", "rgba-result.png");
        let part = png(&root.join("max.png"));
        let ptr = part.bytes.as_ptr();
        assert_eq!(part.bytes.len(), clipboard::IMAGE_LIMIT);
        writer.set(vec![part], || true).unwrap();
        let current = writer.current.as_ref().unwrap();
        assert_eq!(
            current.values[0].1.as_ptr(),
            ptr,
            "PNG was copied into the provider"
        );
        assert_eq!(writer.retained_bytes(), clipboard::IMAGE_LIMIT);
        fs::write(
            root.join("retained-smaps.txt"),
            fs::read("/proc/self/smaps_rollup").unwrap(),
        )
        .unwrap();
        fetch(&mut writer, &root, "image/png", "max-result.png");
        assert_eq!(writer.transfers.len(), 0);
        fs::write(
            root.join("after-transfer-smaps.txt"),
            fs::read("/proc/self/smaps_rollup").unwrap(),
        )
        .unwrap();
        // A canceled replacement leaves the existing selection unchanged.
        assert!(writer
            .set(vec![png(&root.join("small.png"))], || false)
            .is_err());
        assert_eq!(writer.current.as_ref().unwrap().values[0].1.as_ptr(), ptr);
        let requestor = Requestor::new();
        requestor.metadata(&mut writer);
        let windows: Vec<_> = (0..MAX_TRANSFERS)
            .map(|_| requestor.request(&mut writer, true))
            .collect();
        requestor.request(&mut writer, false);
        assert_eq!(writer.transfers.len(), MAX_TRANSFERS);
        assert_eq!(writer.retained_bytes(), clipboard::IMAGE_LIMIT);
        // Replacing the selection preserves existing INCR sources without
        // copying them. A dead requestor releases its transfer slot.
        writer
            .set(vec![png(&root.join("medium.png"))], || true)
            .unwrap();
        requestor.connection.destroy_window(windows[0]).unwrap();
        requestor.connection.flush().unwrap();
        settle(&mut writer, 30);
        assert_eq!(writer.transfers.len(), MAX_TRANSFERS - 1);
        requestor.request(&mut writer, true);
        assert_eq!(
            writer.retained_bytes(),
            clipboard::IMAGE_LIMIT + 2 * 1024 * 1024
        );
        assert!(writer
            .set(vec![png(&root.join("max.png"))], || true)
            .is_err());
        assert_eq!(writer.current.as_ref().unwrap().bytes, 2 * 1024 * 1024);
        settle(&mut writer, 3100);
        assert_eq!(writer.transfers.len(), 0);
        assert_eq!(writer.retained_bytes(), 2 * 1024 * 1024);
        let mut old = Command::new(root.join("clipboard-fixture"))
            .args(["get-data", ":91", "image/png"])
            .arg(root.join("lost-owner-result.png"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let until = Instant::now() + Duration::from_secs(1);
        while writer.transfers.is_empty() {
            writer.dispatch().unwrap();
            assert!(Instant::now() < until);
        }
        let local_window = requestor.window();
        requestor
            .connection
            .set_selection_owner(local_window, requestor.selection, CURRENT_TIME)
            .unwrap()
            .check()
            .unwrap();
        pump(&mut writer, &mut old);
        assert_eq!(writer.retained_bytes(), 0);
        writer
            .set(vec![png(&root.join("small.png"))], || true)
            .unwrap();
        fetch(&mut writer, &root, "image/png", "after-timeout.png");
        // A new local owner releases the provider's current bytes.
        let mut local = Command::new(root.join("clipboard-fixture"))
            .args(["set", ":91", "synthetic-local-copy"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(local.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        assert_eq!(line.trim(), "READY");
        settle(&mut writer, 20);
        assert_eq!(writer.retained_bytes(), 0);
        local.kill().unwrap();
        local.wait().unwrap();
        let reader = super::super::clipboard_x11::Reader::new().unwrap();
        let mut source = Command::new(root.join("clipboard-fixture"))
            .args(["set-data", ":91", "image/png"])
            .arg(root.join("max.png"))
            .stdout(Stdio::piped())
            .stderr(fs::File::create(root.join("reader-source.log")).unwrap())
            .spawn()
            .unwrap();
        let mut ready = String::new();
        BufReader::new(source.stdout.take().unwrap())
            .read_line(&mut ready)
            .unwrap();
        assert_eq!(ready.trim(), "READY");
        reader.changed().unwrap();
        let policy = clipboard::Policy {
            image: clipboard::Directions {
                send: true,
                receive: false,
            },
            ..Default::default()
        };
        let began = Instant::now();
        let received = reader
            .read(policy, || true, || writer.dispatch().unwrap())
            .expect("bounded Host reader did not receive maximum PNG");
        assert_eq!(received.len(), 1);
        assert_eq!(received[0].bytes.len(), clipboard::IMAGE_LIMIT);
        fs::write(root.join("reader-result.json"),serde_json::json!({"bytes":received[0].bytes.len(),"milliseconds":began.elapsed().as_millis()}).to_string()).unwrap();
        source.kill().unwrap();
        source.wait().unwrap();
        assert_eq!(
            fs::read_dir("/proc/self/task").unwrap().count(),
            before_threads
        );
        fs::write(root.join("writer-result.json"),serde_json::json!({"result":"pass",
            "checks":["rgba_png","png_128m_incr","png_buffer_not_copied","canceled_update_keeps_selection",
                "four_request_limit","incr_old_selection_retained","dead_requestor_releases_slot",
                "retained_payload_budget","stalled_reader_expiry","recovery_after_expiry","local_owner_releases_content","no_extra_threads","targets_and_timestamp","multiple_partial_failure_and_bounds","incr_completes_after_ownership_lost"],
            "maximum_payload":clipboard::IMAGE_LIMIT,"retained_budget":RETAINED_LIMIT}).to_string()).unwrap();
    }
}
