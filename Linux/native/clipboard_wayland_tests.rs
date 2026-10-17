use super::*;
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
};

struct CopySource(Child);
impl Drop for CopySource {
    fn drop(&mut self) {
        if self.0.try_wait().unwrap().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}
fn copy(root: &Path, path: &Path, mime: &str, tag: &str) -> CopySource {
    let log = fs::File::create(root.join(format!("{tag}-source.log"))).unwrap();
    CopySource(
        Command::new("wl-copy")
            .args(["--foreground", "--type", mime])
            .stdin(fs::File::open(path).unwrap())
            .stdout(Stdio::null())
            .stderr(log)
            .spawn()
            .unwrap(),
    )
}
fn pump(writer: &mut Writer) {
    writer.dispatch().unwrap();
    let mut fds = Vec::new();
    writer.poll_fds(&mut fds);
    unsafe {
        libc::poll(fds.as_mut_ptr(), fds.len() as _, 5);
    }
}
fn fetch(writer: &mut Writer, root: &Path, mime: &str, name: &str) {
    let mut child = Command::new("wl-paste")
        .args(["--no-newline", "--type", mime])
        .stdout(fs::File::create(root.join(name)).unwrap())
        .stderr(fs::File::create(root.join(format!("{name}.log"))).unwrap())
        .spawn()
        .unwrap();
    let until = Instant::now() + Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() {
        if Instant::now() >= until {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("Wayland output timed out");
        }
        pump(writer);
    }
    assert!(child.wait().unwrap().success());
}
fn receive(reader: &mut Reader, policy: Policy) -> Vec<Part<Bytes>> {
    let until = Instant::now() + Duration::from_secs(5);
    loop {
        assert!(Instant::now() < until, "Wayland input did not arrive");
        if reader.changed().unwrap() {
            let parts = reader.read(policy, || true, || {}).unwrap();
            if !parts.is_empty() {
                return parts;
            }
        }
        poll(reader.fd(), libc::POLLIN, 5).unwrap();
    }
}
fn request(reader: &mut Reader, mime: &str) -> OwnedFd {
    let mut pipe = [-1; 2];
    assert_eq!(
        unsafe { libc::pipe2(pipe.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) },
        0
    );
    let read = unsafe { OwnedFd::from_raw_fd(pipe[0]) };
    let write = unsafe { OwnedFd::from_raw_fd(pipe[1]) };
    reader
        .0
        .state
        .current
        .as_ref()
        .unwrap()
        .object
        .receive(mime, &write);
    reader.0.connection.flush().unwrap();
    drop(write);
    read
}
fn png(root: &Path) -> Part<Bytes> {
    Part {
        format: Format::Png,
        width: 0,
        height: 0,
        bytes: fs::read(root.join("max.png")).unwrap().into(),
    }
}

#[test]
#[ignore = "requires an owned headless compositor inside the private test container"]
fn private_wayland_clipboard_lifecycle() {
    assert!(Path::new("/.dockerenv").is_file());
    assert!(std::env::var_os("DISPLAY").is_none());
    let root = PathBuf::from(std::env::var_os("FARPANE_PRIVATE_WAYLAND_CLIPBOARD_TEST").unwrap());
    assert!(root.starts_with("/workspace/Build/Linux/wayland-clipboard-smoke"));
    let socket = std::env::var("WAYLAND_DISPLAY").unwrap();
    assert!(!socket.contains('/'));
    let threads = fs::read_dir("/proc/self/task").unwrap().count();
    let protocol = std::env::var("FARPANE_PRIVATE_WAYLAND_PROTOCOL").unwrap();
    if protocol == "unavailable" {
        let began = Instant::now();
        let read_error = super::super::clipboard_platform::Reader::new()
            .err()
            .unwrap()
            .to_string();
        let write_error = super::super::clipboard_platform::Writer::new()
            .err()
            .unwrap()
            .to_string();
        assert!(read_error.contains("Wayland") && write_error.contains("Wayland"));
        assert!(began.elapsed() < Duration::from_secs(7));
        fs::write(root.join("unavailable-result.json"),serde_json::json!({"result":"pass","no_xwayland_fallback":true,"milliseconds":began.elapsed().as_millis(),"read_error":read_error,"write_error":write_error}).to_string()).unwrap();
        return;
    }
    let mut reader = Reader::new().unwrap();
    let mut writer = Writer::new().unwrap();
    assert!(matches!(
        (&writer.0.manager, protocol.as_str()),
        (Manager::Ext(_), "ext") | (Manager::Wlr(_), "wlr")
    ));
    let directions = clipboard::Directions {
        send: true,
        receive: true,
    };
    let policy = Policy {
        text: directions,
        rich_text: directions,
        image: directions,
    };
    fs::write(root.join("text.txt"), "Wayland 中文 clipboard").unwrap();
    let text = copy(
        &root,
        &root.join("text.txt"),
        "text/plain;charset=utf-8",
        &format!("{protocol}-text"),
    );
    let parts = receive(&mut reader, policy);
    assert_eq!(parts.len(), 1);
    assert_eq!(parts[0].bytes.as_ref(), "Wayland 中文 clipboard".as_bytes());
    drop(text);
    let source = copy(
        &root,
        &root.join("max.png"),
        "image/png",
        &format!("{protocol}-png"),
    );
    let began = Instant::now();
    let parts = receive(&mut reader, policy);
    assert_eq!(parts[0].format, Format::Png);
    assert_eq!(parts[0].bytes.len(), clipboard::IMAGE_LIMIT);
    assert_eq!(
        parts[0].bytes.as_ref(),
        fs::read(root.join("max.png")).unwrap()
    );
    let read_ms = began.elapsed().as_millis();
    drop(parts);
    drop(source);
    for (format, mime, value) in [
        (
            Format::Html,
            "text/html",
            b"<b>Wayland input</b>".as_slice(),
        ),
        (Format::Rtf, "text/rtf", b"{\\rtf1 Wayland input}"),
        (
            Format::Svg,
            "image/svg+xml",
            b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"1\"></svg>",
        ),
    ] {
        let path = root.join("formatted-input.txt");
        fs::write(&path, value).unwrap();
        let source = copy(&root, &path, mime, &format!("{protocol}-{format:?}"));
        let parts = receive(&mut reader, policy);
        // wl-copy also advertises plain-text aliases for its text/* sources.
        // Those are an allowed fallback of the same rich bundle.
        assert!(parts.len() <= 2);
        assert_eq!(parts[0].format, format);
        assert_eq!(parts[0].bytes.as_ref(), value);
        for fallback in &parts[1..] {
            assert!(matches!(format, Format::Html | Format::Rtf));
            assert_eq!(fallback.format, Format::Text);
            assert_eq!(fallback.bytes.as_ref(), value);
        }
        drop(source);
    }
    let one = |format, bytes: &'static [u8]| Part {
        format,
        width: 0,
        height: 0,
        bytes: Bytes::from_static(bytes),
    };
    writer
        .set(vec![one(Format::Text, b"from-native-wayland")], || true)
        .unwrap();
    fetch(
        &mut writer,
        &root,
        "text/plain;charset=utf-8",
        &format!("{protocol}-text-result.txt"),
    );
    assert_eq!(
        fs::read(root.join(format!("{protocol}-text-result.txt"))).unwrap(),
        b"from-native-wayland"
    );
    assert!(writer
        .set(vec![one(Format::Text, b"not-authorized")], || false)
        .is_err());
    fetch(
        &mut writer,
        &root,
        "text/plain",
        &format!("{protocol}-canceled-result.txt"),
    );
    assert_eq!(
        fs::read(root.join(format!("{protocol}-canceled-result.txt"))).unwrap(),
        b"from-native-wayland"
    );
    reader.changed().unwrap();
    assert!(reader
        .read(policy, || true, || writer.dispatch().unwrap())
        .unwrap()
        .is_empty());
    writer
        .set(
            vec![
                one(Format::Html, b"<b>Wayland</b>"),
                one(Format::Rtf, b"{\\rtf1 Wayland}"),
                one(Format::Text, b"Wayland"),
            ],
            || true,
        )
        .unwrap();
    for (mime, name, expected) in [
        ("text/html", "html", b"<b>Wayland</b>".as_slice()),
        ("application/rtf", "rtf", b"{\\rtf1 Wayland}"),
        ("text/plain", "fallback", b"Wayland"),
    ] {
        let name = format!("{protocol}-{name}.txt");
        fetch(&mut writer, &root, mime, &name);
        assert_eq!(fs::read(root.join(name)).unwrap(), expected);
    }
    let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"1\"></svg>";
    writer.set(vec![one(Format::Svg, svg)], || true).unwrap();
    fetch(
        &mut writer,
        &root,
        "image/svg+xml",
        &format!("{protocol}-svg-result.txt"),
    );
    assert_eq!(
        fs::read(root.join(format!("{protocol}-svg-result.txt"))).unwrap(),
        svg
    );
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
    fetch(
        &mut writer,
        &root,
        "image/png",
        &format!("{protocol}-rgba-result.png"),
    );
    writer.set(vec![png(&root)], || true).unwrap();
    fetch(
        &mut writer,
        &root,
        "image/png",
        &format!("{protocol}-max-result.png"),
    );
    assert_eq!(
        fs::metadata(root.join(format!("{protocol}-max-result.png")))
            .unwrap()
            .len(),
        clipboard::IMAGE_LIMIT as u64
    );
    reader.changed().unwrap();
    let mut stalled = Vec::new();
    for _ in 0..MAX_TRANSFERS {
        stalled.push(request(&mut reader, "image/png"));
    }
    let until = Instant::now() + Duration::from_secs(1);
    while writer.0.state.transfers.len() != MAX_TRANSFERS {
        assert!(Instant::now() < until);
        pump(&mut writer);
    }
    let fifth = request(&mut reader, "image/png");
    for _ in 0..5 {
        pump(&mut writer);
    }
    let mut byte = 0u8;
    assert_eq!(
        unsafe { libc::read(fifth.as_raw_fd(), (&mut byte as *mut u8).cast(), 1) },
        0
    );
    assert_eq!(writer.0.state.transfers.len(), MAX_TRANSFERS);
    writer.set(vec![png(&root)], || true).unwrap();
    assert_eq!(writer.0.state.retained(), RETAINED_LIMIT);
    assert!(writer.set(vec![png(&root)], || true).is_err());
    // Finish one already accepted transfer after its source was cancelled by
    // replacement; the old Bytes must remain intact until the final EOF.
    let old = stalled.pop().unwrap();
    let mut result = Vec::new();
    let mut buffer = [0u8; CHUNK];
    let until = Instant::now() + Duration::from_secs(3);
    loop {
        assert!(Instant::now() < until);
        writer.dispatch().unwrap();
        let size = unsafe { libc::read(old.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
        if size == 0 {
            break;
        }
        if size > 0 {
            result.extend_from_slice(&buffer[..size as usize]);
        } else {
            assert_eq!(io::Error::last_os_error().kind(), io::ErrorKind::WouldBlock);
            pump(&mut writer);
        }
    }
    assert_eq!(result, fs::read(root.join("max.png")).unwrap());
    fs::write(root.join(format!("{protocol}-old-result.png")), result).unwrap();
    drop(old);
    assert_eq!(writer.0.state.transfers.len(), MAX_TRANSFERS - 1);
    drop(stalled.pop());
    for _ in 0..5 {
        pump(&mut writer);
    }
    assert_eq!(writer.0.state.transfers.len(), MAX_TRANSFERS - 2);
    let until = Instant::now() + Duration::from_secs(4);
    while !writer.0.state.transfers.is_empty() {
        assert!(Instant::now() < until);
        pump(&mut writer);
    }
    assert_eq!(writer.0.state.retained(), clipboard::IMAGE_LIMIT);
    drop(stalled);
    writer
        .set(vec![one(Format::Text, b"after-stall")], || true)
        .unwrap();
    fetch(
        &mut writer,
        &root,
        "text/plain",
        &format!("{protocol}-after-stall.txt"),
    );
    assert_eq!(
        fs::read(root.join(format!("{protocol}-after-stall.txt"))).unwrap(),
        b"after-stall"
    );
    let local = copy(
        &root,
        &root.join("text.txt"),
        "text/plain;charset=utf-8",
        &format!("{protocol}-local"),
    );
    let until = Instant::now() + Duration::from_secs(2);
    while !writer.empty() {
        assert!(Instant::now() < until);
        pump(&mut writer);
    }
    assert_eq!(writer.0.state.retained(), 0);
    drop(local);
    let (inherited, _other) = std::os::unix::net::UnixStream::pair().unwrap();
    let inherited_value = inherited.as_raw_fd().to_string();
    std::env::set_var("WAYLAND_SOCKET", &inherited_value);
    let issue = super::super::clipboard_platform::Reader::new()
        .err()
        .unwrap()
        .to_string();
    assert!(issue.contains("inherited"));
    assert_eq!(std::env::var("WAYLAND_SOCKET").unwrap(), inherited_value);
    assert!(unsafe { libc::fcntl(inherited.as_raw_fd(), libc::F_GETFD) } >= 0);
    std::env::remove_var("WAYLAND_SOCKET");
    let runtime = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
    let silent_name = format!("silent-{protocol}");
    let _silent = std::os::unix::net::UnixListener::bind(runtime.join(&silent_name)).unwrap();
    std::env::set_var("WAYLAND_DISPLAY", &silent_name);
    let began = Instant::now();
    let issue = Reader::new().err().unwrap().to_string();
    assert!(issue.contains("timed out"));
    assert!(began.elapsed() >= IDLE && began.elapsed() < Duration::from_secs(4));
    let silent_ms = began.elapsed().as_millis();
    std::env::set_var("WAYLAND_DISPLAY", socket);
    assert_eq!(fs::read_dir("/proc/self/task").unwrap().count(), threads);
    fs::write(root.join(format!("{protocol}-result.json")),serde_json::json!({"result":"pass","protocol":protocol,
        "maximum_bytes":clipboard::IMAGE_LIMIT,"read_milliseconds":read_ms,"silent_compositor_milliseconds":silent_ms,"checks":["native_protocol_negotiation","utf8_receive","max_png_receive","rich_receive","svg_receive","text_output_aliases","cancel_before_side_effect","own_marker_no_echo","rich_bundle_output","svg_output","rgba_png_output","max_png_output","four_transfer_limit","fifth_transfer_closed","old_source_retained_during_replacement","old_transfer_completes_after_source_cancelled","retained_budget","closed_reader_released","stalled_transfer_timeout","recovery_after_timeout","local_source_releases_storage","inherited_fd_and_environment_preserved","silent_compositor_bounded_initialization","no_extra_threads"]}).to_string()).unwrap();
}
