//! System events refresh registration; they never restart Host/media processes.
use dbus::{
    blocking::{stdintf::org_freedesktop_dbus::Properties, Connection},
    channel::MatchingReceiver,
    message::MatchRule,
};
use farpane_protocol::{RecoveryPhase, RecoveryStatus};
use hbb_common::{bail, config, ResultType};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

const LOGIN: &str = "org.freedesktop.login1";
const LOGIN_PATH: &str = "/org/freedesktop/login1";
const LOGIN_IFACE: &str = "org.freedesktop.login1.Manager";
const NETWORK: &str = "org.freedesktop.NetworkManager";
const NETWORK_PATH: &str = "/org/freedesktop/NetworkManager";
const TIMEOUT: Duration = Duration::from_millis(400);
static STATUS: Mutex<Option<RecoveryStatus>> = Mutex::new(None);
static REGISTRATION: Mutex<(u64, u64)> = Mutex::new((0, 0));

pub fn registration_epoch() -> u64 {
    REGISTRATION.lock().unwrap().0
}
pub fn registration_confirmed(epoch: u64) {
    let mut state = REGISTRATION.lock().unwrap();
    if state.0 == epoch {
        state.1 = epoch;
    }
}
pub fn registration_response(
    epoch: u64,
    response: &Option<hbb_common::rendezvous_proto::rendezvous_message::Union>,
) {
    use hbb_common::rendezvous_proto::{register_pk_response, rendezvous_message::Union};
    let accepted = match response {
        Some(Union::RegisterPeerResponse(response)) => !response.request_pk,
        Some(Union::RegisterPkResponse(response)) => {
            response.result.enum_value() == Ok(register_pk_response::Result::OK)
        }
        _ => false,
    };
    if accepted {
        registration_confirmed(epoch);
    }
}
pub fn begin_registration() -> bool {
    let mut state = REGISTRATION.lock().unwrap();
    let Some(next) = state.0.checked_add(1) else {
        return false;
    };
    state.0 = next;
    true
}
fn confirmed() -> bool {
    let state = REGISTRATION.lock().unwrap();
    state.0 != 0 && state.0 == state.1
}

pub fn status() -> RecoveryStatus {
    STATUS.lock().unwrap().clone().unwrap_or_default()
}

fn publish(status: RecoveryStatus) {
    let mut previous = STATUS.lock().unwrap();
    if previous.as_ref() != Some(&status) {
        *previous = Some(status);
        super::control::changed();
    }
}

pub fn start() -> ResultType<()> {
    std::thread::Builder::new()
        .name("farpane-recovery".into())
        .spawn(|| {
            let mut policy = Policy::new();
            loop {
                if let Err(error) = monitor(&mut policy) {
                    hbb_common::throttled_log!(
                        Duration::from_secs(60),
                        warn,
                        "System recovery monitor unavailable; core retries remain active: {error}"
                    );
                }
                policy.cancel();
                publish(RecoveryStatus::default());
                std::thread::sleep(Duration::from_secs(5));
            }
        })?;
    Ok(())
}

struct Policy {
    epoch: u64,
    attempt: u8,
    pending: bool,
    exhausted: bool,
    sleeping: Option<bool>,
    network: Option<(u32, String)>,
    due: Instant,
    last_attempt: Option<Instant>,
}
impl Policy {
    fn new() -> Self {
        Self {
            epoch: 0,
            attempt: 0,
            pending: false,
            exhausted: false,
            sleeping: None,
            network: None,
            due: Instant::now(),
            last_attempt: None,
        }
    }
    fn cancel(&mut self) {
        self.pending = false;
        self.exhausted = false;
        self.attempt = 0;
    }
    fn trigger(&mut self, now: Instant) {
        if self.pending {
            return;
        }
        let Some(epoch) = self.epoch.checked_add(1) else {
            return;
        };
        self.epoch = epoch;
        self.pending = true;
        self.attempt = 0;
        self.exhausted = false;
        self.due = (now + Duration::from_millis(500)).max(
            self.last_attempt
                .map_or(now, |last| last + Duration::from_secs(2)),
        );
    }
    fn sleep(&mut self, value: bool, now: Instant) {
        let woke = self.sleeping == Some(true) && !value;
        self.sleeping = Some(value);
        if value {
            self.cancel();
        }
        if woke {
            self.trigger(now);
        }
    }
    fn network(&mut self, state: u32, primary: String, now: Instant) {
        let changed = self
            .network
            .as_ref()
            .is_some_and(|old| connected(state) && (!connected(old.0) || old.1 != primary));
        self.network = Some((state, primary));
        if changed {
            self.trigger(now);
        }
    }
    fn tick(&mut self, now: Instant, enabled: bool, registered: bool) -> bool {
        if !enabled {
            self.cancel();
            return false;
        }
        if self.sleeping == Some(true) || self.network.as_ref().is_some_and(|n| !connected(n.0)) {
            return false;
        }
        if self.pending && self.attempt > 0 && registered {
            self.pending = false;
            self.exhausted = false;
        }
        if !self.pending || now < self.due {
            return false;
        }
        if self.attempt == 3 {
            self.pending = false;
            self.exhausted = true;
            return false;
        }
        self.attempt += 1;
        self.last_attempt = Some(now);
        self.due = now + Duration::from_secs([3, 6, 10][usize::from(self.attempt - 1)]);
        true
    }
    fn snapshot(
        &self,
        enabled: bool,
        registered: bool,
        sleep: bool,
        network: bool,
    ) -> RecoveryStatus {
        let (phase, detail) = if !enabled {
            (RecoveryPhase::Disabled, "被控已关闭，不执行后台恢复")
        } else if !sleep && !network {
            (
                RecoveryPhase::Unavailable,
                "系统事件监听不可用，核心仍会自行重试连接",
            )
        } else if self.sleeping == Some(true) {
            (RecoveryPhase::Suspended, "系统准备休眠，恢复将在唤醒后进行")
        } else if self.network.as_ref().is_some_and(|n| !connected(n.0)) {
            (RecoveryPhase::WaitingNetwork, "等待网络恢复")
        } else if self.pending {
            if self.attempt == 0 {
                (RecoveryPhase::Waiting, "网络或系统已恢复，准备重新注册")
            } else {
                (
                    RecoveryPhase::Registering,
                    "正在恢复后台注册，现有会话保持运行",
                )
            }
        } else if self.exhausted && !registered {
            (
                RecoveryPhase::WaitingServer,
                "快速恢复未成功，核心继续等待服务器",
            )
        } else if registered {
            (RecoveryPhase::Ready, "后台注册正常")
        } else {
            (RecoveryPhase::Monitoring, "正在监听系统恢复事件")
        };
        RecoveryStatus {
            phase,
            detail: detail.into(),
            sleep_monitor: sleep,
            network_monitor: network,
            epoch: self.epoch,
            attempt: self.attempt,
        }
    }
}

fn connected(state: u32) -> bool {
    matches!(state, 50 | 60 | 70)
}

enum Event {
    Sleep(String, bool),
    Network(String),
    Owners,
}
fn send(sender: &SyncSender<Event>, overflow: &AtomicBool, event: Event) {
    if sender.try_send(event).is_err() {
        overflow.store(true, Ordering::Release);
    }
}
fn owner(connection: &Connection, name: &str) -> Option<String> {
    let result: Result<(String,), _> = connection
        .with_proxy("org.freedesktop.DBus", "/org/freedesktop/DBus", TIMEOUT)
        .method_call("org.freedesktop.DBus", "GetNameOwner", (name,));
    result.ok().map(|value| value.0)
}
fn network(connection: &Connection, owner: &str) -> Option<(u32, String)> {
    // Unique destinations cannot auto-activate or silently switch providers.
    let proxy = connection.with_proxy(owner, NETWORK_PATH, TIMEOUT);
    let state: u32 = proxy.get(NETWORK, "State").ok()?;
    let path: dbus::Path<'static> = proxy.get(NETWORK, "PrimaryConnection").ok()?;
    if !matches!(state, 0 | 10 | 20 | 30 | 40 | 50 | 60 | 70) || path.len() > 1024 {
        return None;
    }
    Some((state, path.to_string()))
}

fn monitor(policy: &mut Policy) -> ResultType<()> {
    let connection = Connection::new_system()?;
    let mut reconnected = policy.sleeping.is_some() || policy.network.is_some();
    let (sender, receiver) = mpsc::sync_channel(32);
    let overflow = Arc::new(AtomicBool::new(false));
    let rules = [
        MatchRule::new_signal(LOGIN_IFACE, "PrepareForSleep")
            .with_sender(LOGIN)
            .with_path(LOGIN_PATH),
        MatchRule::new_signal("org.freedesktop.DBus.Properties", "PropertiesChanged")
            .with_sender(NETWORK)
            .with_path(NETWORK_PATH),
        MatchRule::new_signal("org.freedesktop.DBus", "NameOwnerChanged")
            .with_strict_sender("org.freedesktop.DBus")
            .with_path("/org/freedesktop/DBus"),
    ];
    for (index, rule) in rules.into_iter().enumerate() {
        connection.add_match_no_cb(&rule.match_str())?;
        let sender = sender.clone();
        let overflow = overflow.clone();
        connection.start_receive(
            rule,
            Box::new(move |message, _| {
                let event = match index {
                    0 => message
                        .get1::<bool>()
                        .zip(message.sender())
                        .map(|(sleeping, who)| Event::Sleep(who.to_string(), sleeping)),
                    1 if message.get1::<&str>() == Some(NETWORK) => {
                        message.sender().map(|who| Event::Network(who.to_string()))
                    }
                    2 if message
                        .get1::<&str>()
                        .is_some_and(|n| n == LOGIN || n == NETWORK) =>
                    {
                        Some(Event::Owners)
                    }
                    _ => None,
                };
                if let Some(event) = event {
                    send(&sender, &overflow, event);
                }
                true
            }),
        );
    }
    let mut login_owner = None;
    let mut network_owner = None;
    let mut sleep_monitor = false;
    let mut network_monitor = false;
    let mut refresh = Instant::now() - Duration::from_secs(10);
    let mut revision = super::config::revision();
    loop {
        connection.process(Duration::from_millis(200))?;
        if overflow.swap(false, Ordering::AcqRel) {
            bail!("System event queue overflow; resynchronizing providers");
        }
        let mut owners_dirty = false;
        let mut network_dirty = false;
        for event in receiver.try_iter().take(32) {
            match event {
                Event::Owners => {
                    owners_dirty = true;
                    policy.cancel();
                    login_owner = None;
                    network_owner = None;
                }
                Event::Sleep(who, sleeping) if login_owner.as_deref() == Some(who.as_str()) => {
                    policy.sleep(sleeping, Instant::now());
                }
                Event::Network(who) if network_owner.as_deref() == Some(who.as_str()) => {
                    network_dirty = true
                }
                _ => {}
            }
        }
        if owners_dirty || refresh.elapsed() >= Duration::from_secs(5) {
            refresh = Instant::now();
            login_owner = owner(&connection, LOGIN);
            network_owner = owner(&connection, NETWORK);
            let sleeping = login_owner.as_ref().and_then(|who| {
                connection
                    .with_proxy(who, LOGIN_PATH, TIMEOUT)
                    .get::<bool>(LOGIN_IFACE, "PreparingForSleep")
                    .ok()
            });
            sleep_monitor = sleeping.is_some();
            if let Some(sleeping) = sleeping {
                policy.sleep(sleeping, Instant::now());
            } else {
                policy.sleeping = None;
            }
            network_dirty = true;
        }
        if network_dirty {
            let state = network_owner
                .as_ref()
                .and_then(|who| network(&connection, who));
            network_monitor = state.is_some();
            if let Some((state, path)) = state {
                policy.network(state, path, Instant::now());
            } else {
                policy.network = None;
            }
        }
        let current = super::config::revision();
        if current != revision {
            policy.cancel();
            revision = current;
        }
        if reconnected && (sleep_monitor || network_monitor) {
            reconnected = false;
            policy.trigger(Instant::now());
        }
        let enabled = config::Config::get_option("stop-service") != "Y";
        let registered = config::get_online_state() > 0 && confirmed();
        if policy.tick(Instant::now(), enabled, registered) {
            if !super::config::recover_registration(revision) {
                policy.cancel();
            }
        }
        publish(policy.snapshot(
            enabled,
            config::get_online_state() > 0,
            sleep_monitor,
            network_monitor,
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn events_coalesce_and_registration_must_be_confirmed() {
        let start = Instant::now();
        let mut p = Policy::new();
        p.sleep(false, start);
        p.network(70, "/one".into(), start);
        assert!(!p.tick(start + Duration::from_secs(1), true, true));
        p.sleep(true, start);
        p.sleep(false, start);
        for _ in 0..100 {
            p.trigger(start);
        }
        assert_eq!(p.epoch, 1);
        assert!(!p.tick(start, true, true));
        assert!(p.tick(start + Duration::from_secs(1), true, true));
        assert!(p.pending);
        assert!(!p.tick(start + Duration::from_secs(2), true, true));
        assert!(!p.pending);
        p.network(20, "/".into(), start + Duration::from_secs(3));
        p.network(50, "/two".into(), start + Duration::from_secs(4));
        assert!(p.tick(start + Duration::from_secs(5), true, false));
        assert_eq!(p.epoch, 2);
    }
    #[test]
    fn retries_are_finite_and_sleep_disable_or_config_cancel_stops_them() {
        let start = Instant::now();
        let mut p = Policy::new();
        p.trigger(start);
        let attempts = (0..60)
            .filter(|second| p.tick(start + Duration::from_secs(*second), true, false))
            .count();
        assert_eq!(attempts, 3);
        assert!(p.exhausted);
        p.trigger(start + Duration::from_secs(61));
        p.sleep(true, start + Duration::from_secs(61));
        assert!(!p.tick(start + Duration::from_secs(70), true, false));
        p.sleep(false, start + Duration::from_secs(71));
        assert!(!p.tick(start + Duration::from_secs(72), false, false));
        assert!(!p.pending);
        p.trigger(start + Duration::from_secs(73));
        p.cancel();
        assert!(!p.tick(start + Duration::from_secs(74), true, false));
    }
    #[test]
    fn only_acknowledgement_from_the_requested_registration_counts() {
        let old = registration_epoch();
        assert!(begin_registration());
        registration_confirmed(old);
        assert!(!confirmed());
        let current = registration_epoch();
        registration_confirmed(current);
        assert!(confirmed());
        assert!(begin_registration());
        registration_confirmed(current);
        assert!(!confirmed());
    }
}
