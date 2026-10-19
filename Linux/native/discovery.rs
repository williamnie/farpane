//! Bounded logind observations and native desktop authorization, independent of
//! the legacy best-effort Desktop refresh and its shell/environment fallbacks.
use hbb_common::{anyhow::anyhow, bail, libc, log, tokio, ResultType};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{self, Read},
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        io::AsRawFd,
    },
    path::Path,
    process::{Command, Stdio},
    sync::Mutex,
    time::{Duration, Instant},
};

const QUERY_TIMEOUT: Duration = Duration::from_millis(600);
const AUTH_TTL: Duration = Duration::from_secs(2);
const OUTPUT_LIMIT: usize = 32 * 1024;
static ACTIVE: Mutex<Option<(Instant, Session)>> = Mutex::new(None);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Key {
    pub uid: u32,
    pub sid: String,
    leader: u32,
    start: u64,
    protocol: String,
}

#[derive(Clone, Debug)]
pub struct Session {
    pub key: Key,
    pub username: String,
    pub display: String,
}
pub type Environment = BTreeMap<String, String>;

pub fn publish(session: Option<&Session>) {
    *ACTIVE.lock().unwrap() = session.map(|s| (Instant::now(), s.clone()));
}

pub fn active() -> Option<Session> {
    ACTIVE
        .lock()
        .unwrap()
        .as_ref()
        .filter(|(when, _)| when.elapsed() < AUTH_TTL)
        .map(|(_, session)| session.clone())
}

pub fn protocol(session: &Session) -> &str {
    &session.key.protocol
}

fn read_limited(path: &Path, limit: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    File::open(path)?
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Session data exceeds limit",
        ));
    }
    Ok(bytes)
}

fn output(program: &Path, args: &[&str], deadline: Duration) -> ResultType<String> {
    let mut child = Command::new(program)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("LANG", "C.UTF-8")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()?;
    let result = (|| -> ResultType<String> {
        let mut stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("Missing loginctl output"))?;
        let fd = stdout.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error().into());
        }
        let started = Instant::now();
        let mut bytes = Vec::new();
        loop {
            let mut buffer = [0u8; 4096];
            loop {
                match stdout.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        bytes.extend_from_slice(&buffer[..count]);
                        if bytes.len() > OUTPUT_LIMIT {
                            bail!("loginctl output exceeds limit");
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => return Err(error.into()),
                }
            }
            if let Some(status) = child.try_wait()? {
                if !status.success() {
                    bail!("loginctl query failed: {status}");
                }
                // Drain bytes written between the last read and process exit.
                let remaining = OUTPUT_LIMIT.saturating_sub(bytes.len()) + 1;
                match stdout.take(remaining as u64).read_to_end(&mut bytes) {
                    Ok(_) => {}
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(error) => return Err(error.into()),
                }
                if bytes.len() > OUTPUT_LIMIT {
                    bail!("loginctl output exceeds limit");
                }
                return Ok(String::from_utf8(bytes)?);
            }
            if started.elapsed() >= deadline {
                bail!("loginctl query timed out");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    })();
    if result.is_err() {
        // This is our own unreaped child; no PID/name search or shell process.
        if let Err(error) = child.kill() {
            if error.kind() != io::ErrorKind::InvalidInput {
                log::trace!("Could not stop failed loginctl query: {error}");
            }
        }
        if let Err(error) = child.wait() {
            log::trace!("Could not reap loginctl query: {error}");
        }
    }
    result
}

fn properties(text: &str) -> ResultType<BTreeMap<&str, &str>> {
    let mut values = BTreeMap::new();
    for line in text.lines() {
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| anyhow!("Malformed session property"))?;
        if key.is_empty() || values.insert(key, value).is_some() {
            bail!("Duplicate or empty session property");
        }
    }
    Ok(values)
}

fn field<'a>(values: &BTreeMap<&str, &'a str>, key: &str) -> ResultType<&'a str> {
    values
        .get(key)
        .copied()
        .ok_or_else(|| anyhow!("Missing session property: {key}"))
}

fn parse_session(sid: &str, text: &str) -> ResultType<Option<Session>> {
    let values = properties(text)?;
    if field(&values, "Id")? != sid
        || field(&values, "Seat")? != "seat0"
        || field(&values, "Active")? != "yes"
        || field(&values, "State")? != "active"
    {
        bail!("Active session changed during observation");
    }
    let uid = field(&values, "User")?.parse::<u32>()?;
    let class = field(&values, "Class")?;
    let protocol = field(&values, "Type")?;
    let remote = field(&values, "Remote")?;
    if !matches!(remote, "yes" | "no") {
        bail!("Invalid session locality");
    }
    if uid == 0
        || remote == "yes"
        || !matches!(class, "user" | "user-early" | "user-light")
        || !matches!(protocol, "x11" | "wayland")
    {
        return Ok(None);
    }
    let username = field(&values, "Name")?;
    if username.is_empty() {
        bail!("Empty desktop username");
    }
    let leader = field(&values, "Leader")?.parse::<u32>()?;
    if leader == 0 {
        bail!("Missing desktop leader");
    }
    let start = super::process::start_ticks(leader)?;
    Ok(Some(Session {
        key: Key {
            uid,
            sid: sid.to_owned(),
            leader,
            start,
            protocol: protocol.to_owned(),
        },
        username: username.to_owned(),
        display: field(&values, "Display")?.to_owned(),
    }))
}

pub fn query() -> ResultType<Option<Session>> {
    let program = Path::new("/usr/bin/loginctl");
    let seat = output(
        program,
        &[
            "show-seat",
            "seat0",
            "--property=ActiveSession",
            "--no-pager",
        ],
        QUERY_TIMEOUT,
    )?;
    let values = properties(&seat)?;
    let sid = field(&values, "ActiveSession")?;
    if sid.is_empty() {
        return Ok(None);
    }
    if sid.len() > 128
        || !sid
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        bail!("Invalid login session identifier");
    }
    let data = output(
        program,
        &["show-session", sid, "--all", "--no-pager"],
        QUERY_TIMEOUT,
    )?;
    parse_session(sid, &data)
}

fn local_display(value: &str) -> Option<String> {
    // Mutter also gives managed services a private Xwayland listener in this
    // Unix-socket form. Preserve it as a local display instead of silently
    // removing DISPLAY from the desktop Host's environment.
    if let Some(number) = value.strip_prefix("unix:/tmp/.X11-unix/X") {
        return (!number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()))
            .then(|| value.to_owned());
    }
    let hostname = hbb_common::whoami::hostname();
    let value = value.strip_prefix(&hostname).unwrap_or(value);
    let number = value.strip_prefix(':')?;
    let mut parts = number.split('.');
    let valid = |part: &str| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit());
    if !valid(parts.next()?) || !parts.next().map_or(true, valid) || parts.next().is_some() {
        return None;
    }
    Some(value.to_owned())
}

const ENV_KEYS: &[&str] = &[
    "DISPLAY",
    "XAUTHORITY",
    "WAYLAND_DISPLAY",
    "DBUS_SESSION_BUS_ADDRESS",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_STATE_HOME",
    "XDG_CURRENT_DESKTOP",
    "DESKTOP_SESSION",
];

fn single_graphical_session(session: &Session) -> ResultType<bool> {
    let program = Path::new("/usr/bin/loginctl");
    let started = Instant::now();
    let text = output(
        program,
        &[
            "show-user",
            &session.key.uid.to_string(),
            "--property=Sessions",
            "--no-pager",
        ],
        QUERY_TIMEOUT,
    )?;
    let properties = properties(&text)?;
    let sessions: Vec<&str> = field(&properties, "Sessions")?.split_whitespace().collect();
    if sessions.len() > 32 {
        bail!("Too many login sessions to disambiguate desktop environment");
    }
    let mut found = false;
    for sid in sessions {
        if sid.len() > 128
            || !sid
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            bail!("Invalid user session identifier");
        }
        let remaining = Duration::from_secs(2)
            .checked_sub(started.elapsed())
            .ok_or_else(|| anyhow!("User session enumeration timed out"))?;
        let text = output(
            program,
            &["show-session", sid, "--all", "--no-pager"],
            remaining.min(QUERY_TIMEOUT),
        )?;
        let values = self::properties(&text)?;
        if field(&values, "Id")? != sid
            || field(&values, "User")?.parse::<u32>()? != session.key.uid
        {
            bail!("User session changed during enumeration");
        }
        if matches!(
            field(&values, "Class")?,
            "user" | "user-early" | "user-light"
        ) && matches!(field(&values, "Type")?, "x11" | "wayland")
        {
            if sid != session.key.sid || found {
                return Ok(false);
            }
            let current = parse_session(sid, &text)?
                .ok_or_else(|| anyhow!("Desktop disappeared during enumeration"))?;
            if current.key != session.key {
                bail!("Desktop leader changed during enumeration");
            }
            found = true;
        }
    }
    Ok(found)
}

fn desktop_component(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|v| v.to_str()) else {
        return false;
    };
    matches!(
        name,
        "gnome-shell"
            | "gnome-shell-calendar-server"
            | "plasmashell"
            | "kwin_wayland"
            | "kded5"
            | "kded6"
            | "xfce4-panel"
            | "xfce4-session"
            | "mate-session"
            | "cinnamon"
            | "sway"
            | "Hyprland"
            | "lxqt-session"
    ) || name.starts_with("xdg-desktop-portal")
        || name.starts_with("ibus-")
}

fn display_target<'a>(session: &Session, env: &'a Environment) -> Option<&'a str> {
    env.get(if session.key.protocol == "wayland" {
        "WAYLAND_DISPLAY"
    } else {
        "DISPLAY"
    })
    .map(String::as_str)
}

pub fn environment(session: &Session) -> ResultType<Environment> {
    let started = Instant::now();
    let own_exe = fs::canonicalize(std::env::current_exe()?)?;
    let mut newest: Option<(u64, Environment)> = None;
    let mut managed = Vec::new();
    for (index, entry) in fs::read_dir("/proc")?.enumerate() {
        if index > 16384 || started.elapsed() > Duration::from_millis(500) {
            bail!("Desktop environment discovery exceeded its bound");
        }
        let entry = entry?;
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<u32>().ok())
        else {
            continue;
        };
        let path = entry.path();
        if !fs::metadata(&path).is_ok_and(|m| m.uid() == session.key.uid) {
            continue;
        }
        // Never rediscover our own previously inherited environment as proof
        // that a desktop compositor has supplied the new session's settings.
        let Ok(executable) = fs::read_link(path.join("exe")) else {
            continue;
        };
        if executable == own_exe {
            continue;
        }
        let Ok(before) = super::process::start_ticks(pid) else {
            continue;
        };
        let Ok(bytes) = read_limited(&path.join("environ"), 64 * 1024) else {
            continue;
        };
        let values: BTreeMap<&str, &str> = bytes
            .split(|b| *b == 0)
            .filter_map(|part| std::str::from_utf8(part).ok()?.split_once('='))
            .collect();
        let tagged = values.get("XDG_SESSION_ID") == Some(&session.key.sid.as_str());
        let scope = format!("session-{}.scope", session.key.sid);
        let scoped = read_limited(&path.join("cgroup"), 8192)
            .ok()
            .is_some_and(|b| {
                String::from_utf8_lossy(&b)
                    .lines()
                    .any(|line| line.split('/').any(|v| v == scope))
            });
        let tied = tagged || scoped || pid == session.key.leader;
        if !tied && (before < session.key.start || !desktop_component(&executable)) {
            continue;
        }
        let mut env: Environment = ENV_KEYS
            .iter()
            .filter_map(|key| {
                values
                    .get(key)
                    .filter(|v| !v.is_empty())
                    .map(|v| ((*key).to_owned(), (*v).to_owned()))
            })
            .collect();
        if let Some(display) = env.get("DISPLAY").cloned() {
            if let Some(local) = local_display(&display) {
                env.insert("DISPLAY".into(), local);
            } else {
                env.remove("DISPLAY");
            }
        }
        if session.key.protocol == "x11" {
            let Some(display) = env.get("DISPLAY") else {
                continue;
            };
            if !session.display.is_empty()
                && local_display(&session.display).as_ref() != Some(display)
            {
                continue;
            }
        } else {
            let Some(display) = env.get("WAYLAND_DISPLAY") else {
                continue;
            };
            let runtime = std::path::PathBuf::from(format!("/run/user/{}", session.key.uid));
            let socket = runtime.join(display);
            if socket
                .components()
                .any(|p| matches!(p, std::path::Component::ParentDir))
                || !socket.starts_with(&runtime)
                || !fs::symlink_metadata(socket)
                    .is_ok_and(|m| m.file_type().is_socket() && m.uid() == session.key.uid)
            {
                continue;
            }
        }
        if env.iter().any(|(k, v)| {
            (k == "XAUTHORITY" || k.starts_with("XDG_") && k.ends_with("_HOME"))
                && !Path::new(v).is_absolute()
        }) {
            continue;
        }
        if super::process::start_ticks(pid).ok() != Some(before)
            || !fs::metadata(&path).is_ok_and(|m| m.uid() == session.key.uid)
        {
            continue;
        }
        if !tied {
            managed.push((before, env));
        } else {
            if newest.as_ref().is_some_and(|(_, current)| {
                display_target(session, current) != display_target(session, &env)
            }) {
                bail!("Ambiguous display targets inside the login session");
            }
            if newest.as_ref().map_or(true, |(time, _)| before > *time) {
                newest = Some((before, env));
            }
        }
    }
    if newest.is_none() && !managed.is_empty() && single_graphical_session(session)? {
        let target = display_target(session, &managed[0].1);
        if managed
            .iter()
            .any(|(_, env)| display_target(session, env) != target)
        {
            bail!("Ambiguous display targets in user-managed desktop services");
        }
        // Modern GNOME/KDE components often live under user@UID.service and
        // have no session tag. Only a single confirmed graphical login plus
        // one consistent display target permits this bounded fallback.
        newest = managed.into_iter().max_by_key(|(start, _)| *start);
    }
    let mut env = newest
        .ok_or_else(|| anyhow!("Desktop environment is not ready for this login session"))?
        .1;
    env.insert("XDG_SESSION_ID".into(), session.key.sid.clone());
    env.insert("XDG_SESSION_TYPE".into(), session.key.protocol.clone());
    Ok(env)
}

pub fn process_session(pid: u32) -> ResultType<Option<String>> {
    let bytes = read_limited(Path::new(&format!("/proc/{pid}/environ")), 64 * 1024)?;
    Ok(bytes.split(|b| *b == 0).find_map(|v| {
        std::str::from_utf8(v)
            .ok()?
            .strip_prefix("XDG_SESSION_ID=")
            .map(str::to_owned)
    }))
}

pub fn matches_process(session: &Session, process: &super::process::Process) -> ResultType<bool> {
    Ok(
        fs::metadata(format!("/proc/{}", process.pid))?.uid() == session.key.uid
            && process.start >= session.key.start
            && process_session(process.pid)?.as_deref() == Some(session.key.sid.as_str()),
    )
}

pub fn authorize_root_peer(fd: std::os::fd::RawFd, uid: u32) -> ResultType<()> {
    if uid == 0 {
        return Ok(());
    }
    let session = active().ok_or_else(|| anyhow!("Desktop authorization is unknown"))?;
    if uid != session.key.uid {
        bail!("Desktop UID changed");
    }
    let peer = farpane_protocol::transport::Peer::from_fd_for_uid(fd, uid)?;
    let executable = fs::canonicalize(std::env::current_exe()?)?;
    peer.verify_executable(&executable)?;
    let process = super::process::Process::exact(peer.pid, &executable, Some(uid), "--server")?;
    if !matches_process(&session, &process)? {
        bail!("Core belongs to a different login session");
    }
    peer.ensure_alive()?;
    if active().map(|s| s.key) != Some(session.key) {
        bail!("Desktop changed during peer authorization");
    }
    Ok(())
}

pub async fn guarded_input<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
    stream: &mut crate::ipc::ConnectionTmpl<T>,
    key: &Option<Key>,
) -> ResultType<Option<crate::ipc::Data>> {
    loop {
        if key.is_none() || active().map(|s| s.key).as_ref() != key.as_ref() {
            bail!("Desktop authorization changed or is unknown");
        }
        match tokio::time::timeout(Duration::from_millis(100), stream.next()).await {
            Ok(result) => {
                if active().map(|s| s.key).as_ref() != key.as_ref() {
                    bail!("Desktop authorization changed while receiving input");
                }
                return result;
            }
            Err(_) => continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn query_failures_are_bounded_and_not_empty_success() {
        assert!(output(Path::new("/bin/sh"), &["-c", "exit 1"], QUERY_TIMEOUT).is_err());
        let start = Instant::now();
        assert!(output(Path::new("/bin/sleep"), &["5"], Duration::from_millis(100)).is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(output(
            Path::new("/usr/bin/head"),
            &["-c", "65536", "/dev/zero"],
            QUERY_TIMEOUT
        )
        .is_err());
    }
    #[test]
    fn session_properties_distinguish_transitions_and_non_user_desktops() {
        let text = format!("Id=c1\nSeat=seat0\nActive=yes\nState=active\nUser=1000\nClass=user\nType=x11\nRemote=no\nName=desktop\nLeader={}\nDisplay=:0\n", std::process::id());
        let session = parse_session("c1", &text).unwrap().unwrap();
        assert_eq!(session.key.uid, 1000);
        assert!(parse_session("c2", &text).is_err());
        assert!(
            parse_session("c1", &text.replace("Class=user", "Class=greeter"))
                .unwrap()
                .is_none()
        );
        assert!(parse_session("c1", &text.replace("Active=yes", "Active=no")).is_err());
        assert!(parse_session("c1", &text.replace("User=1000\n", "")).is_err());
        assert!(properties("ActiveSession=c1\nActiveSession=c2\n").is_err());
        assert_eq!(local_display(":12.0"), Some(":12.0".into()));
        assert_eq!(local_display("localhost:10.0"), None);
    }
    #[test]
    fn mutter_managed_xwayland_socket_remains_a_local_display() {
        for display in ["unix:/tmp/.X11-unix/X1", "unix:/tmp/.X11-unix/X12"] {
            assert_eq!(local_display(display), Some(display.into()));
        }
        for invalid in [
            "unix:/tmp/.X11-unix/X", "unix:/tmp/.X11-unix/X1/../../other",
            "unix:/tmp/.X11-unix/X1.0", "unix:/elsewhere/X1",
            "remote:1", "tcp/localhost:1", "unix:/tmp/.X11-unix/X-1",
        ] {
            assert_eq!(local_display(invalid), None, "{invalid}");
        }
    }
    #[test]
    #[ignore = "requires test-native-gnome-input.sh's private Mutter and focused entry"]
    fn private_mutter_xwayland_chinese_paste() {
        use dbus::blocking::Connection;
        assert!(Path::new("/.dockerenv").is_file());
        assert_ne!(unsafe { libc::geteuid() }, 0);
        assert!(!Path::new("/dev/uinput").exists());
        let directory = std::path::PathBuf::from(
            std::env::var_os("FARPANE_GNOME_INPUT_TEST_DIR").unwrap(),
        );
        assert!(directory.starts_with("/workspace/Build/Linux/native-gnome-input-smoke"));
        let raw = std::env::var("FARPANE_GNOME_MANAGED_DISPLAY").unwrap();
        assert!(raw.starts_with("unix:/tmp/.X11-unix/X"));
        eprintln!("private paste: checking missing display");
        std::env::remove_var("DISPLAY");
        assert!(arboard::Clipboard::new().is_err(), "Missing DISPLAY must reproduce the failure");
        eprintln!("private paste: preserving managed display");
        std::env::set_var("DISPLAY", local_display(&raw).unwrap());
        let read = || -> serde_json::Value {
            serde_json::from_slice(&fs::read(directory.join("entry.json")).unwrap()).unwrap()
        };
        assert_eq!(read()["text"], "");
        let bus = Connection::new_session().unwrap();
        let service = "org.gnome.Mutter.RemoteDesktop";
        let interface = "org.gnome.Mutter.RemoteDesktop.Session";
        let (path,): (dbus::Path<'static>,) = bus
            .with_proxy(service, "/org/gnome/Mutter/RemoteDesktop", Duration::from_secs(1))
            .method_call(service, "CreateSession", ()).unwrap();
        let session = bus.with_proxy(service, path, Duration::from_secs(1));
        session.method_call::<(), _, _, _>(interface, "Start", ()).unwrap();
        let mut expected = String::new();
        for text in ["中文测试", "混合A1，🙂", "é"] {
            eprintln!("private paste: writing clipboard");
            crate::clipboard::set_text_clipboard_with_owner_sync(
                text, crate::clipboard::ClipboardSide::Host,
            ).unwrap();
            eprintln!("private paste: clipboard write returned");
            std::thread::sleep(Duration::from_millis(200));
            // Private compositor keyboard substitutes for host /dev/uinput:
            // the production path uses the same Shift+Insert key sequence.
            for (code, down) in [(42u32, true), (110, true), (110, false), (42, false)] {
                session.method_call::<(), _, _, _>(interface, "NotifyKeyboardKeycode", (code, down)).unwrap();
                std::thread::sleep(Duration::from_millis(30));
            }
            expected.push_str(text);
            let deadline = Instant::now() + Duration::from_secs(3);
            while read()["text"] != expected {
                assert!(Instant::now() < deadline, "Focused target did not receive exact Chinese paste");
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        session.method_call::<(), _, _, _>(interface, "Stop", ()).unwrap();
        fs::write(directory.join("gnome-input-result.json"), serde_json::to_vec_pretty(
            &serde_json::json!({"result":"pass", "checks":["missing-display-reproduced",
                "managed-socket-preserved", "chinese-paste", "mixed-ascii-cjk-emoji", "no-duplicates"],
                "actual_mutter_wayland":true, "host_input_exercised":false,
                "network_input_exercised":false}),
        ).unwrap()).unwrap();
    }
    #[test]
    fn input_lease_expires_on_unknown_or_a_new_login_for_the_same_uid() {
        let text = format!("Id=c1\nSeat=seat0\nActive=yes\nState=active\nUser=1000\nClass=user\nType=x11\nRemote=no\nName=desktop\nLeader={}\nDisplay=:0\n", std::process::id());
        let session = parse_session("c1", &text).unwrap().unwrap();
        let key = Some(session.key.clone());
        publish(Some(&session));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let (reader, writer) = tokio::io::duplex(1024);
            let mut reader = crate::ipc::ConnectionTmpl::new(reader);
            let mut writer = crate::ipc::ConnectionTmpl::new(writer);
            writer.send(&crate::ipc::Data::Empty).await.unwrap();
            assert!(matches!(
                guarded_input(&mut reader, &key).await.unwrap(),
                Some(crate::ipc::Data::Empty)
            ));
            let clear = async {
                tokio::time::sleep(Duration::from_millis(30)).await;
                publish(None);
            };
            let started = Instant::now();
            let (result, _) = tokio::join!(guarded_input(&mut reader, &key), clear);
            assert!(result.is_err() && started.elapsed() < Duration::from_secs(1));
            let mut other = session.clone();
            other.key.sid = "c2".into();
            publish(Some(&other));
            writer.send(&crate::ipc::Data::Empty).await.unwrap();
            assert!(guarded_input(&mut reader, &key).await.is_err());
        });
        *ACTIVE.lock().unwrap() = Some((Instant::now() - AUTH_TTL, session));
        assert!(active().is_none());
        publish(None);
    }
}
