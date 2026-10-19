//! One Host clipboard worker, one replaceable incoming job and one replaceable
//! outgoing value per connection. All payload work stays off network/control threads.
use super::{clipboard_platform, clipboard_wire};
use base::message_proto::{Clipboard, Message};
use farpane_protocol::clipboard::{Category, Direction, Directions, Policy};
use hbb_common::{config::Config, tokio::sync::watch};
use std::{
    collections::HashMap,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    sync::{Arc, Condvar, Mutex, OnceLock},
    time::{Duration, Instant},
};

pub const KEY: &str = "farpane-clipboard-policy";
pub const GENERATION: &str = "farpane-clipboard-generation";
const MAX_CONNECTIONS: usize = 64;
struct Entry {
    epoch: u64,
    send: bool,
    receive: bool,
    sent: u64,
    revoked: bool,
    output: watch::Sender<Option<Arc<Output>>>,
}
struct Input {
    id: i32,
    epoch: u64,
    revision: u64,
    values: Vec<Clipboard>,
}
pub struct Output {
    pub message: Message,
    revision: u64,
    epoch: u64,
    category: Category,
    serial: u64,
}
struct State {
    policy: Policy,
    revision: u64,
    entries: HashMap<i32, Entry>,
    pending: Option<Input>,
    refresh: bool,
    applying: bool,
    network_busy: bool,
    serial: u64,
    detail: &'static str,
}
struct Signal(OwnedFd);
impl Signal {
    fn new() -> std::io::Result<Self> {
        let fd = unsafe {
            hbb_common::libc::eventfd(
                0,
                hbb_common::libc::EFD_CLOEXEC | hbb_common::libc::EFD_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Self(unsafe { OwnedFd::from_raw_fd(fd) }))
    }
    fn notify(&self) {
        unsafe {
            hbb_common::libc::write(self.0.as_raw_fd(), (&1u64 as *const u64).cast(), 8);
        }
    }
    fn drain(&self) {
        let mut value = 0u64;
        unsafe {
            hbb_common::libc::read(self.0.as_raw_fd(), (&mut value as *mut u64).cast(), 8);
        }
    }
}
struct Owner {
    state: Mutex<State>,
    wake: Condvar,
    signal: Signal,
}
static OWNER: OnceLock<Arc<Owner>> = OnceLock::new();

/// Absent native policy preserves only the old text grant. Rich/image require
/// explicit consent. Invalid native JSON fails closed, never falls back to legacy.
fn parse_policy(raw: Option<&str>, legacy: bool) -> Option<Policy> {
    match raw {
        Some(raw) => serde_json::from_str(raw).ok(),
        None => Some(Policy {
            text: Directions {
                send: legacy,
                receive: legacy,
            },
            ..Default::default()
        }),
    }
}
pub fn settings() -> Option<Policy> {
    let options = Config::get_options();
    let legacy = match options.get("access-mode").map(String::as_str) {
        Some("full") => true,
        Some("view") => false,
        _ => hbb_common::config::option2bool(
            "enable-clipboard",
            options
                .get("enable-clipboard")
                .map(String::as_str)
                .unwrap_or_default(),
        ),
    };
    parse_policy(options.get(KEY).map(String::as_str), legacy)
}
pub fn enabled() -> bool {
    let p = settings().unwrap_or_default();
    p.any(Direction::Send) || p.any(Direction::Receive)
}
pub fn detail() -> String {
    if settings().is_none() {
        return "剪贴板策略无效，共享已停止；请重新保存设置".into();
    }
    OWNER
        .get()
        .map(|o| o.state.lock().unwrap().detail)
        .unwrap_or("等待获准连接")
        .into()
}
pub fn start() -> hbb_common::ResultType<()> {
    if OWNER.get().is_some() {
        return Ok(());
    }
    let owner = Arc::new(Owner {
        state: Mutex::new(State {
            policy: settings().unwrap_or_default(),
            revision: Config::get_option(GENERATION).parse().unwrap_or(0),
            entries: HashMap::new(),
            pending: None,
            refresh: false,
            applying: false,
            network_busy: false,
            serial: 0,
            detail: "等待获准连接",
        }),
        wake: Condvar::new(),
        signal: Signal::new()?,
    });
    let worker = owner.clone();
    std::thread::Builder::new()
        .name("host-clipboard".into())
        .stack_size(256 * 1024)
        .spawn(move || worker.run())?;
    let _ = OWNER.set(owner);
    Ok(())
}
pub fn reload() {
    if let Some(owner) = OWNER.get() {
        let mut s = owner.state.lock().unwrap();
        s.policy = settings().unwrap_or_default();
        s.revision = Config::get_option(GENERATION).parse().unwrap_or(0);
        s.pending = None;
        s.refresh = true;
        for entry in s.entries.values() {
            entry.output.send_replace(None);
        }
        owner.signal.notify();
    }
}
/// Control replies wait for an already-issued platform set to finish; a revoke
/// cannot erase content already copied, but no older pending write survives ACK.
pub fn barrier() -> hbb_common::ResultType<()> {
    if let Some(owner) = OWNER.get() {
        let deadline = Instant::now() + Duration::from_secs(4);
        let mut s = owner.state.lock().unwrap();
        while s.applying {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                hbb_common::bail!("Clipboard backend has not completed revocation");
            }
            s = owner.wake.wait_timeout(s, left).unwrap().0;
        }
    }
    Ok(())
}
pub fn revoke(id: i32) {
    if let Some(owner) = OWNER.get() {
        let mut s = owner.state.lock().unwrap();
        if let Some(e) = s.entries.get_mut(&id) {
            e.epoch = e.epoch.saturating_add(1);
            e.send = false;
            e.receive = false;
            e.revoked = true;
            e.output.send_replace(None);
        }
        if s.pending.as_ref().is_some_and(|p| p.id == id) {
            s.pending = None;
        }
        owner.signal.notify();
    }
}

pub struct Link {
    owner: Arc<Owner>,
    id: i32,
}
impl Link {
    pub fn new(id: i32, output: watch::Sender<Option<Arc<Output>>>) -> Option<Self> {
        let owner = OWNER.get()?.clone();
        let mut s = owner.state.lock().unwrap();
        if s.entries.len() >= MAX_CONNECTIONS || s.entries.contains_key(&id) {
            return None;
        }
        s.entries.insert(
            id,
            Entry {
                epoch: 1,
                send: false,
                receive: false,
                sent: 0,
                revoked: false,
                output,
            },
        );
        drop(s);
        Some(Self { owner, id })
    }
    pub fn configure(&self, send: bool, receive: bool) {
        let mut s = self.owner.state.lock().unwrap();
        if let Some(e) = s.entries.get_mut(&self.id) {
            let (send, receive) = if e.revoked {
                (false, false)
            } else {
                (send, receive)
            };
            if e.send == send && e.receive == receive {
                return;
            }
            e.epoch = e.epoch.saturating_add(1);
            e.send = send;
            e.receive = receive;
            e.output.send_replace(None);
            s.refresh = true;
            if s.pending.as_ref().is_some_and(|p| p.id == self.id) {
                s.pending = None;
            }
            self.owner.signal.notify();
        }
    }
    pub fn receive(&self, values: Vec<Clipboard>) {
        let mut s = self.owner.state.lock().unwrap();
        let Some(e) = s.entries.get(&self.id).filter(|e| e.receive) else {
            return;
        };
        let epoch = e.epoch;
        let Ok(values) = clipboard_wire::select(values, s.policy, Direction::Receive) else {
            return;
        };
        s.pending = Some(Input {
            id: self.id,
            epoch,
            revision: s.revision,
            values,
        });
        self.owner.signal.notify();
    }
    pub fn valid(&self, output: &Output) -> bool {
        let s = self.owner.state.lock().unwrap();
        s.revision == output.revision
            && s.policy.allows(output.category, Direction::Send)
            && s.entries
                .get(&self.id)
                .is_some_and(|e| e.send && e.epoch == output.epoch)
    }
    pub fn claim(&self, output: &Output) -> Option<NetworkCredit> {
        let mut s = self.owner.state.lock().unwrap();
        if s.network_busy
            || s.revision != output.revision
            || !s.policy.allows(output.category, Direction::Send)
        {
            return None;
        }
        let e = s.entries.get_mut(&self.id)?;
        if !e.send || e.epoch != output.epoch || e.sent == output.serial {
            return None;
        }
        e.sent = output.serial;
        s.network_busy = true;
        Some(NetworkCredit(self.owner.clone()))
    }
}
/// Covers serialization and the actual TCP send across all Host connections.
/// Every connection retains its latest slot while waiting; completion wakes
/// them without accumulating timers, queue nodes or per-payload tasks.
pub struct NetworkCredit(Arc<Owner>);
impl Drop for NetworkCredit {
    fn drop(&mut self) {
        let mut s = self.0.state.lock().unwrap();
        s.network_busy = false;
        for e in s.entries.values() {
            e.output.send_modify(|_| {});
        }
    }
}
impl Drop for Link {
    fn drop(&mut self) {
        let mut s = self.owner.state.lock().unwrap();
        s.entries.remove(&self.id);
        if s.pending.as_ref().is_some_and(|p| p.id == self.id) {
            s.pending = None;
        }
        self.owner.signal.notify();
    }
}
impl Owner {
    fn receive_valid(&self, id: i32, epoch: u64, revision: u64, category: Category) -> bool {
        let s = self.state.lock().unwrap();
        s.revision == revision
            && s.policy.allows(category, Direction::Receive)
            && s.entries
                .get(&id)
                .is_some_and(|e| e.receive && e.epoch == epoch)
    }
    fn send_valid(&self, revision: u64) -> bool {
        let s = self.state.lock().unwrap();
        s.revision == revision
            && s.policy.any(Direction::Send)
            && s.entries.values().any(|e| e.send)
    }
    fn service_writer(&self, writer: &mut Option<clipboard_platform::Writer>) {
        let failed = writer.as_mut().is_some_and(|w| w.dispatch().is_err());
        if failed
            || writer
                .as_ref()
                .is_some_and(clipboard_platform::Writer::empty)
        {
            *writer = None;
        }
        if failed {
            self.state.lock().unwrap().detail = clipboard_platform::unavailable();
        }
    }
    fn run(&self) {
        let mut reader = None;
        let mut writer = None;
        let mut retry = Instant::now();
        let (mut reader_error, mut writer_error) = (String::new(), String::new());
        loop {
            let (pending, sending) = {
                let s = self.state.lock().unwrap();
                (
                    s.pending.is_some() || s.refresh,
                    s.policy.any(Direction::Send) && s.entries.values().any(|e| e.send),
                )
            };
            if !pending
                && !reader
                    .as_ref()
                    .is_some_and(clipboard_platform::Reader::more)
                && !writer
                    .as_ref()
                    .is_some_and(clipboard_platform::Writer::more)
            {
                use hbb_common::libc;
                let mut fds = vec![libc::pollfd {
                    fd: self.signal.0.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                }];
                if let Some(r) = reader.as_ref() {
                    fds.push(libc::pollfd {
                        fd: r.fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    });
                }
                if let Some(w) = writer.as_ref() {
                    w.poll_fds(&mut fds);
                }
                let deadline = writer
                    .as_ref()
                    .and_then(clipboard_platform::Writer::deadline);
                let deadline = if sending && reader.is_none() {
                    Some(deadline.map_or(retry, |d| d.min(retry)))
                } else {
                    deadline
                };
                let timeout = deadline.map_or(-1, |d| {
                    d.saturating_duration_since(Instant::now())
                        .as_millis()
                        .min(i32::MAX as u128) as i32
                });
                let result = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, timeout) };
                if result < 0
                    && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
                {
                    self.state.lock().unwrap().detail = "剪贴板事件服务不可用";
                    return;
                }
            }
            self.signal.drain();
            self.service_writer(&mut writer);
            let (policy, revision, input, mut refresh, active) = {
                let mut s = self.state.lock().unwrap();
                let active = s.policy.any(Direction::Send) && s.entries.values().any(|e| e.send);
                (
                    s.policy,
                    s.revision,
                    s.pending.take(),
                    std::mem::take(&mut s.refresh),
                    active,
                )
            };
            if let Some(input) = input {
                let parts = clipboard_wire::decode(input.values, policy, Direction::Receive);
                if let Ok(parts) = parts {
                    let category = farpane_protocol::clipboard::category(
                        &parts.iter().map(|p| p.format).collect::<Vec<_>>(),
                    )
                    .unwrap();
                    let valid =
                        || self.receive_valid(input.id, input.epoch, input.revision, category);
                    if valid() {
                        if writer.is_none() {
                            writer = clipboard_platform::Writer::new()
                                .map_err(|e| report(&mut writer_error, "writer", e))
                                .ok();
                        }
                        // Set applying before the final validity check so control ACK
                        // cannot race between the check and the platform side effect.
                        self.state.lock().unwrap().applying = true;
                        let success = writer.as_mut().is_some_and(|w| w.set(parts, valid).is_ok());
                        let mut s = self.state.lock().unwrap();
                        s.applying = false;
                        s.detail = if success {
                            clipboard_platform::ready()
                        } else if writer.is_none() {
                            clipboard_platform::unavailable()
                        } else {
                            "剪贴板写入失败或已撤权"
                        };
                        self.wake.notify_all();
                    }
                }
            }
            if !active {
                reader = None;
                continue;
            }
            if reader.is_none() && Instant::now() >= retry {
                reader = clipboard_platform::Reader::new()
                    .map_err(|e| report(&mut reader_error, "reader", e))
                    .ok();
                retry = Instant::now() + Duration::from_secs(5);
                refresh = true;
                if reader.is_none() {
                    self.state.lock().unwrap().detail = clipboard_platform::unavailable();
                } else {
                    self.state.lock().unwrap().detail = clipboard_platform::ready();
                }
            }
            let Some(r) = reader.as_mut() else {
                continue;
            };
            match r.changed() {
                Ok(changed) => refresh |= changed,
                Err(_) => {
                    reader = None;
                    self.state.lock().unwrap().detail = clipboard_platform::unavailable();
                    continue;
                }
            }
            if !refresh {
                continue;
            }
            let epochs: HashMap<_, _> = self
                .state
                .lock()
                .unwrap()
                .entries
                .iter()
                .filter(|(_, e)| e.send)
                .map(|(id, e)| (*id, e.epoch))
                .collect();
            let Ok(parts) = r.read(
                policy,
                || self.send_valid(revision),
                || self.service_writer(&mut writer),
            ) else {
                continue;
            };
            if parts.is_empty() {
                continue;
            }
            let category = farpane_protocol::clipboard::category(
                &parts.iter().map(|p| p.format).collect::<Vec<_>>(),
            )
            .unwrap();
            let message = clipboard_wire::encode_parts(parts);
            let mut s = self.state.lock().unwrap();
            if s.revision != revision || !s.policy.allows(category, Direction::Send) {
                continue;
            }
            s.detail = clipboard_platform::ready();
            s.serial = s
                .serial
                .checked_add(1)
                .expect("Host clipboard serial exhausted");
            let serial = s.serial;
            for (_, entry) in s
                .entries
                .iter()
                .filter(|(id, e)| e.send && epochs.get(id) == Some(&e.epoch))
            {
                entry.output.send_replace(Some(Arc::new(Output {
                    message: message.clone(),
                    revision,
                    epoch: entry.epoch,
                    category,
                    serial,
                })));
            }
        }
    }
}

/// Backend failures used to be dropped silently; log each distinct one once so
/// the 5 s reader retry does not flood the log.
fn report(last: &mut String, side: &str, error: hbb_common::anyhow::Error) {
    let message = format!("Host clipboard {side} unavailable: {error}");
    if *last != message {
        hbb_common::log::warn!("{message}");
        *last = message;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Link, Link) {
        let d = Directions {
            send: true,
            receive: true,
        };
        let owner = Arc::new(Owner {
            state: Mutex::new(State {
                policy: Policy {
                    text: d,
                    rich_text: d,
                    image: d,
                },
                revision: 1,
                entries: HashMap::new(),
                pending: None,
                refresh: false,
                applying: false,
                network_busy: false,
                serial: 0,
                detail: "test",
            }),
            wake: Condvar::new(),
            signal: Signal::new().unwrap(),
        });
        for id in [1, 2] {
            let (output, _) = watch::channel(None);
            owner.state.lock().unwrap().entries.insert(
                id,
                Entry {
                    epoch: 1,
                    send: true,
                    receive: true,
                    sent: 0,
                    revoked: false,
                    output,
                },
            );
        }
        (
            Link {
                owner: owner.clone(),
                id: 1,
            },
            Link { owner, id: 2 },
        )
    }
    #[test]
    fn migration_is_text_only_and_invalid_explicit_policy_fails_closed() {
        assert_eq!(parse_policy(None, false), Some(Policy::default()));
        let old = parse_policy(None, true).unwrap();
        assert!(old.text.send && old.text.receive);
        assert!(!old.rich_text.send && !old.image.receive);
        assert!(parse_policy(Some("invalid"), true).is_none());
        assert_eq!(
            parse_policy(
                Some(&serde_json::to_string(&Policy::default()).unwrap()),
                true
            ),
            Some(Policy::default())
        );
    }
    #[test]
    fn incoming_real_wire_coalesces_and_revoke_invalidates_active_and_pending() {
        let (a, _) = fixture();
        for value in [b"first".as_slice(), b"latest"] {
            a.receive(vec![Clipboard {
                content: value.to_vec().into(),
                ..Default::default()
            }]);
        }
        let input = a.owner.state.lock().unwrap().pending.take().unwrap();
        let policy = a.owner.state.lock().unwrap().policy;
        let decoded = clipboard_wire::decode(input.values, policy, Direction::Receive).unwrap();
        assert_eq!(decoded[0].bytes.as_ref(), b"latest");
        assert!(a
            .owner
            .receive_valid(input.id, input.epoch, input.revision, Category::Text));
        a.receive(vec![Clipboard {
            content: b"pending".to_vec().into(),
            ..Default::default()
        }]);
        a.configure(false, false);
        assert!(a.owner.state.lock().unwrap().pending.is_none());
        assert!(!a
            .owner
            .receive_valid(input.id, input.epoch, input.revision, Category::Text));
        a.configure(true, true);
        assert!(!a
            .owner
            .receive_valid(input.id, input.epoch, input.revision, Category::Text));
    }
    #[test]
    fn global_network_credit_preserves_latest_watch_and_never_resends_completed_value() {
        let (a, b) = fixture();
        let output = Arc::new(Output {
            message: Message::new(),
            revision: 1,
            epoch: 1,
            category: Category::Text,
            serial: 1,
        });
        let mut receiver = b.owner.state.lock().unwrap().entries[&2].output.subscribe();
        b.owner.state.lock().unwrap().entries[&2]
            .output
            .send_replace(Some(output.clone()));
        let credit = a.claim(&output).unwrap();
        assert!(b.claim(&output).is_none());
        receiver.borrow_and_update();
        assert!(!receiver.has_changed().unwrap());
        drop(credit);
        assert!(receiver.has_changed().unwrap());
        let retained = receiver.borrow_and_update().clone().unwrap();
        assert!(Arc::ptr_eq(&retained, &output));
        let credit = b.claim(&retained).unwrap();
        drop(credit);
        assert!(a.claim(&output).is_none() && b.claim(&output).is_none());
        a.owner.state.lock().unwrap().revision += 1;
        assert!(!a.valid(&output));
    }
}
