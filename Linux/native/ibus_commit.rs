//! Commit text to the focused IBus client the way IBus's own emoji panel does:
//! no clipboard and no key chord. Runs in the user's --server process, because
//! the IBus bus only accepts connections from its own user.
//!
//! The panel-extension name is taken for a typing run and released after a
//! quiet period. ibus-extension-gtk3 owns it with ALLOW_REPLACEMENT and stays
//! queued, so the daemon hands the name back when this connection releases or
//! closes. Never logs text.
use dbus::{
    arg::{PropMap, Variant},
    blocking::{stdintf::org_freedesktop_dbus::Properties, Connection},
    channel::Channel,
    Message, Path as ObjectPath,
};
use hbb_common::{bail, log, ResultType};
use std::{
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
    time::Duration,
};

const NAME: &str = "org.freedesktop.IBus.Panel.Extension.Emoji";
const PANEL_PATH: &str = "/org/freedesktop/IBus/Panel/Extension/Emoji";
const PANEL_INTERFACE: &str = "org.freedesktop.IBus.Panel";
const REPLACE_EXISTING: u32 = 2;
const PRIMARY_OWNER: u32 = 1;
const TIMEOUT: Duration = Duration::from_millis(250);
// Longer than a pause between words, so a typing run keeps one owner and a
// commit is long processed by the daemon before the name is released.
const HOLD: Duration = Duration::from_millis(1500);

static SESSION: Mutex<Option<Connection>> = Mutex::new(None);
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// The daemon creates its focus-less "fake" context before any client exists,
/// so it is always the first context. Focus resting there means no IBus client
/// (for example Warp, or an X11 app without XIM) would receive a commit.
fn is_fake_context(path: &str) -> bool {
    path == "/org/freedesktop/IBus/InputContext_1"
}

/// Same lookup as libibus `ibus_get_address()`.
fn address() -> ResultType<String> {
    if let Ok(address) = std::env::var("IBUS_ADDRESS") {
        return Ok(address);
    }
    let file = match std::env::var_os("IBUS_ADDRESS_FILE") {
        Some(file) => std::path::PathBuf::from(file),
        None => {
            let (host, display) = match std::env::var("WAYLAND_DISPLAY") {
                Ok(display) => ("unix".to_owned(), display),
                Err(_) => display_parts(&std::env::var("DISPLAY").unwrap_or_default()),
            };
            let machine = std::fs::read_to_string("/var/lib/dbus/machine-id")
                .or_else(|_| std::fs::read_to_string("/etc/machine-id"))?;
            let config = match std::env::var_os("XDG_CONFIG_HOME") {
                Some(config) => std::path::PathBuf::from(config),
                None => std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config"),
            };
            config.join("ibus/bus").join(format!("{}-{host}-{display}", machine.trim()))
        }
    };
    parse_address_file(&std::fs::read_to_string(file)?)
}

fn display_parts(display: &str) -> (String, String) {
    let (host, number) = display.split_once(':').unwrap_or((display, "0"));
    let number = number.split('.').next().unwrap_or_default();
    let host = if host.is_empty() { "unix" } else { host };
    (host.to_owned(), if display.is_empty() { "0" } else { number }.to_owned())
}

fn parse_address_file(content: &str) -> ResultType<String> {
    let field = |key: &str| {
        content.lines().filter(|line| !line.starts_with('#'))
            .filter_map(|line| line.strip_prefix(key)).last().map(str::to_owned)
    };
    let Some(address) = field("IBUS_ADDRESS=") else { bail!("no IBUS_ADDRESS") };
    // A file left by a daemon that has exited names a dead socket.
    if let Some(pid) = field("IBUS_DAEMON_PID=") {
        if !std::path::Path::new("/proc").join(pid.trim()).exists() {
            bail!("IBus daemon is not running");
        }
    }
    Ok(address)
}

fn open() -> ResultType<Connection> {
    let mut channel = Channel::open_private(&address()?)?;
    channel.register()?;
    let connection = Connection::from(channel);
    let (reply,): (u32,) = connection
        .with_proxy("org.freedesktop.DBus", "/org/freedesktop/DBus", TIMEOUT)
        .method_call("org.freedesktop.DBus", "RequestName", (NAME, REPLACE_EXISTING))?;
    // Not primary means queued behind an owner that refuses replacement;
    // dropping the connection leaves the queue.
    if reply != PRIMARY_OWNER {
        bail!("panel extension name not acquired: {reply}");
    }
    Ok(connection)
}

/// IBus `IBusText` serialization: (sa{sv}sv) holding an empty IBusAttrList.
fn ibus_text(text: &str) -> Variant<(String, PropMap, String, Variant<(String, PropMap, Vec<Variant<u8>>)>)> {
    let attrs = ("IBusAttrList".to_owned(), PropMap::new(), Vec::new());
    Variant(("IBusText".to_owned(), PropMap::new(), text.to_owned(), Variant(attrs)))
}

fn send(connection: &Connection, text: &str) -> ResultType<bool> {
    // This round trip also orders the commit after the daemon has finished
    // creating its panel proxy for a freshly acquired name.
    let focused: ObjectPath = connection
        .with_proxy("org.freedesktop.IBus", "/org/freedesktop/IBus", TIMEOUT)
        .get("org.freedesktop.IBus", "CurrentInputContext")?;
    if is_fake_context(&focused) {
        return Ok(false);
    }
    let signal = Message::new_signal(PANEL_PATH, PANEL_INTERFACE, "CommitText")
        .map_err(|error| hbb_common::anyhow::anyhow!(error))?
        .append1(ibus_text(text));
    if connection.channel().send(signal).is_err() {
        bail!("CommitText not sent");
    }
    connection.channel().flush();
    Ok(true)
}

fn release_later() {
    let generation = GENERATION.fetch_add(1, Ordering::Relaxed) + 1;
    let spawned = std::thread::Builder::new().name("ibus-commit-release".into()).spawn(move || {
        std::thread::sleep(HOLD);
        let mut session = SESSION.lock().unwrap();
        if GENERATION.load(Ordering::Relaxed) == generation {
            // Closing the private connection releases the name.
            *session = None;
        }
    });
    if spawned.is_err() {
        *SESSION.lock().unwrap() = None;
    }
}

/// True when the text was handed to the focused IBus client. False means
/// nothing was sent and the caller should paste instead.
pub fn commit(text: &str) -> bool {
    let result = {
        let mut session = SESSION.lock().unwrap();
        match session.as_ref() {
            Some(connection) => send(connection, text),
            None => open().and_then(|connection| send(session.insert(connection), text)),
        }
    };
    match result {
        Ok(true) => {
            release_later();
            log::debug!("Native committed text: IBus commit sent");
            true
        }
        Ok(false) => {
            release_later();
            log::debug!("Native committed text: no IBus client focused; using paste");
            false
        }
        Err(error) => {
            *SESSION.lock().unwrap() = None;
            hbb_common::throttled_log!(Duration::from_secs(60), info,
                "Native committed text: IBus unavailable; using paste: {error}");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_file_follows_libibus_rules() {
        let file = "# comment IBUS_ADDRESS=wrong\nIBUS_ADDRESS=unix:abstract=/tmp/x,guid=1\nIBUS_DAEMON_PID=1\n";
        assert_eq!(parse_address_file(file).unwrap(), "unix:abstract=/tmp/x,guid=1");
        assert!(parse_address_file("IBUS_ADDRESS=a\nIBUS_DAEMON_PID=999999999\n").is_err());
        assert!(parse_address_file("# IBUS_ADDRESS=a\n").is_err());
        assert_eq!(display_parts(":0"), ("unix".into(), "0".into()));
        assert_eq!(display_parts("unix:1.0"), ("unix".into(), "1".into()));
        assert_eq!(display_parts(""), ("unix".into(), "0".into()));
    }

    #[test]
    fn commit_text_matches_ibus_serialization() {
        let message = Message::new_signal(PANEL_PATH, PANEL_INTERFACE, "CommitText").unwrap()
            .append1(ibus_text("中文"));
        use dbus::arg::RefArg;
        let Variant(inner): Variant<Box<dyn RefArg>> = message.read1().unwrap();
        assert_eq!(&*inner.signature(), "(sa{sv}sv)");
        assert!(is_fake_context("/org/freedesktop/IBus/InputContext_1"));
        assert!(!is_fake_context("/org/freedesktop/IBus/InputContext_12"));
    }
}
