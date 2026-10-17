//! Activity-based Host supervision. Never infer idle from a missing GUI/CM.
use farpane_protocol::supervision::{Activity, Decision, Health, Supervisor};
use hbb_common::{log, tokio};
use std::{
    process::Child,
    sync::Mutex,
    time::{Duration, Instant},
};

static STATE: Mutex<Option<State>> = Mutex::new(None);
struct State {
    pid: u32,
    start: u64,
    last_probe: Instant,
    policy: Supervisor,
}

pub fn run_service() {
    use super::discovery::{self, Environment, Session};
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };
    let running = Arc::new(AtomicBool::new(true));
    let signal = running.clone();
    if let Err(error) = ctrlc::set_handler(move || {
        signal.store(false, Ordering::Release);
    }) {
        log::error!("Cannot install native service shutdown handler: {error}");
        return;
    }
    let mut context: Option<(Session, Environment)> = None;
    let mut uid = String::new();
    let mut child = None;
    let mut last_restart = Instant::now();
    while running.load(Ordering::Acquire) {
        let result = (|| -> hbb_common::ResultType<()> {
            let next = match discovery::query()? {
                Some(session) => session,
                None => {
                    discovery::publish(None);
                    if stop_session(&mut uid, &mut child) {
                        context = None;
                    }
                    return Ok(());
                }
            };
            if context.as_ref().is_some_and(|(old, _)| old.key != next.key) {
                discovery::publish(None);
                if !stop_session(&mut uid, &mut child) {
                    return Ok(());
                }
                context = None;
            }
            if context.is_none() {
                discovery::publish(None);
                // Adoption also needs login provenance. Same UID alone cannot
                // carry a previous login's remote authorization into this one.
                for process in super::process::servers(None)? {
                    if !discovery::matches_process(&next, &process)? {
                        process.stop()?;
                    }
                }
            }
            let refresh = context
                .as_ref()
                .map_or(true, |(old, _)| old.display != next.display);
            let environment = if refresh {
                discovery::environment(&next)?
            } else {
                match context.as_ref() {
                    Some((_, env)) => env.clone(),
                    None => return Err(hbb_common::anyhow::anyhow!("Missing desktop environment")),
                }
            };
            let changed_display = context.as_ref().is_some_and(|(_, old)| {
                ["DISPLAY", "XAUTHORITY", "WAYLAND_DISPLAY"]
                    .iter()
                    .any(|k| old.get(*k) != environment.get(*k))
            });
            discovery::publish(Some(&next));
            let start = should_start(
                next.key.uid,
                &mut uid,
                changed_display,
                &mut last_restart,
                &mut child,
            );
            context = Some((next, environment));
            if start {
                if let Some((session, env)) = context.as_ref() {
                    child = Some(super::session::spawn_desktop(session, env)?);
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            // Retain the Host/network process while logind or environment
            // discovery is unknown, but withdraw privileged media/input access.
            discovery::publish(None);
            hbb_common::throttled_log!(
                Duration::from_secs(10),
                warn,
                "Native desktop context unavailable; privileged access suspended: {error}"
            );
        }
        for _ in 0..5 {
            if !running.load(Ordering::Acquire) {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    discovery::publish(None);
    stop_session(&mut uid, &mut child);
    log::info!("Native service exit");
}

pub fn should_start(
    uid: u32,
    previous_uid: &mut String,
    changed_display: bool,
    last_restart: &mut Instant,
    child: &mut Option<Child>,
) -> bool {
    // The first discovered display is not a change to an adopted agent's
    // environment. Only compare within a desktop context already supervised.
    let changed_display = changed_display && previous_uid.parse::<u32>().ok() == Some(uid);
    if previous_uid.is_empty() {
        // Adopt a matching live agent, but never overlap an agent retained
        // from a different desktop context before this service started.
        if let Err(error) = super::process::stop_other_servers(uid) {
            hbb_common::throttled_log!(
                Duration::from_secs(10),
                error,
                "Cannot retire the previous desktop Host: {error}"
            );
            return false;
        }
    }
    let changed_user = previous_uid
        .parse::<u32>()
        .ok()
        .is_some_and(|old| old != uid);
    if changed_user {
        hbb_common::throttled_log!(
            Duration::from_secs(10),
            info,
            "Native Host desktop user changed; ending the previous authorization context"
        );
        if let Err(error) = super::process::stop_servers(previous_uid.parse().ok()) {
            hbb_common::throttled_log!(
                Duration::from_secs(10),
                error,
                "Previous desktop Host did not stop; refusing a new authorization context: {error}"
            );
            return false;
        }
        reap_wrapper(child);
        *STATE.lock().unwrap() = None;
    }
    *previous_uid = uid.to_string();
    if let Some(process) = child.as_mut() {
        if matches!(process.try_wait(), Ok(Some(_))) {
            *child = None;
        }
    }
    // A child handle alone does not prove that the core is healthy. Keep its
    // first few seconds for startup; the bounded probes below cover deadlocks.
    let processes = match super::process::servers(Some(uid)) {
        Ok(processes) => processes,
        Err(error) => {
            hbb_common::throttled_log!(
                Duration::from_secs(10),
                warn,
                "Native Host identity query failed: {error}"
            );
            return false;
        }
    };
    if processes.is_empty() {
        if child.is_some() && last_restart.elapsed() < Duration::from_secs(10) {
            return false;
        }
        if last_restart.elapsed() < Duration::from_secs(2) {
            return false;
        }
        reap_wrapper(child);
        *STATE.lock().unwrap() = None;
        *last_restart = Instant::now();
        return true;
    }
    if processes.len() != 1 {
        hbb_common::throttled_log!(
            Duration::from_secs(10),
            error,
            "Multiple native Host processes for one UID; refusing an ambiguous restart"
        );
        return false;
    }
    let process = &processes[0];
    let mut guard = STATE.lock().unwrap();
    let state = guard.get_or_insert_with(|| State {
        pid: process.pid,
        start: process.start,
        last_probe: Instant::now() - Duration::from_secs(2),
        policy: Supervisor::default(),
    });
    if state.pid != process.pid || state.start != process.start {
        *state = State {
            pid: process.pid,
            start: process.start,
            last_probe: Instant::now() - Duration::from_secs(2),
            policy: Supervisor::default(),
        };
    }
    if state.last_probe.elapsed() < Duration::from_secs(1) {
        return false;
    }
    state.last_probe = Instant::now();
    let (activity, health) = probe(uid, process.pid, process.start);
    let now = super::activity::monotonic_ms();
    let restart_ms = now.saturating_sub(last_restart.elapsed().as_millis() as u64);
    let mut decision = state.policy.decide(
        now,
        restart_ms,
        process.start,
        process.exited().unwrap_or(false),
        activity.as_ref(),
        health,
    );
    if changed_display {
        // Display changes are never a reason to interrupt an active or unknown
        // Host. Existing capture recreation handles active display generations.
        if activity
            .as_ref()
            .is_some_and(|a| a.valid_at(now, process.start) && !a.busy())
        {
            decision = Decision::RestartIdle;
        } else {
            log::info!("Native display environment changed; retaining the active/unknown Host");
        }
    }
    if decision == Decision::Keep {
        return false;
    }
    if decision == Decision::RecoverUnresponsive {
        log::error!("Native Host failed independent health probes for 60s; recovery may interrupt connections");
    } else {
        log::info!("Native Host maintenance: {decision:?}");
    }
    if let Err(error) = process.stop() {
        hbb_common::throttled_log!(
            Duration::from_secs(10),
            error,
            "Native Host stop failed: {error}"
        );
        return false;
    }
    reap_wrapper(child);
    *guard = None;
    *last_restart = Instant::now();
    true
}

pub fn stop_session(previous_uid: &mut String, child: &mut Option<Child>) -> bool {
    if let Err(error) = super::process::stop_servers(None) {
        hbb_common::throttled_log!(
            Duration::from_secs(10),
            error,
            "Native Host shutdown failed; retaining process ownership: {error}"
        );
        return false;
    }
    reap_wrapper(child);
    previous_uid.clear();
    *STATE.lock().unwrap() = None;
    true
}

fn reap_wrapper(child: &mut Option<Child>) {
    // This handle came from our own spawn, never a name/PID search. Stop the
    // core through pidfd before releasing its child handle.
    if let Some(mut child) = child.take() {
        if !matches!(child.try_wait(), Ok(Some(_))) {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

pub async fn serve_probe(
    mut connection: crate::ipc::Connection,
    peer: farpane_protocol::transport::Peer,
) {
    use crate::ipc::Data;
    // A user cannot inspect /proc/<root>/exe. Root authenticates the Host's
    // exact executable/UID/role before accepting these observations. This
    // direction accepts only kernel-identified root and two read-only queries,
    // never the legacy IPC command handler or any privileged service endpoint.
    let response = match connection.next_timeout2(800).await {
        Some(Ok(Some(Data::NativeActivity(None)))) => {
            Data::NativeActivity(super::activity::snapshot())
        }
        Some(Ok(Some(Data::NativeHealth(None)))) => Data::NativeHealth(Some(
            super::activity::CM_READY.load(std::sync::atomic::Ordering::Acquire),
        )),
        _ => return,
    };
    if peer.ensure_alive().is_ok() {
        if !matches!(
            tokio::time::timeout(Duration::from_millis(800), connection.send(&response)).await,
            Ok(Ok(()))
        ) {
            log::trace!("Native observation peer stopped receiving its response");
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn probe(uid: u32, pid: u32, start: u64) -> (Option<Activity>, Health) {
    use crate::ipc::{self, Data};
    async fn query(uid: u32, pid: u32, start: u64, message: Data) -> Result<Data, Health> {
        let mut connection = ipc::connect_for_uid(800, uid, "")
            .await
            .map_err(|_| Health::TimedOut)?;
        let identity = connection
            .native_server_identity(uid)
            .ok_or(Health::Rejected)?;
        if identity.pid != pid || identity.start != start {
            return Err(Health::Rejected);
        }
        tokio::time::timeout(Duration::from_millis(800), connection.send(&message))
            .await
            .map_err(|_| Health::TimedOut)?
            .map_err(|_| Health::Rejected)?;
        let response = match connection.next_timeout2(800).await {
            Some(Ok(Some(response))) => response,
            None => return Err(Health::TimedOut),
            Some(_) => return Err(Health::Rejected),
        };
        if identity.exited().unwrap_or(true) {
            return Err(Health::Rejected);
        }
        Ok(response)
    }
    let activity = match query(uid, pid, start, Data::NativeActivity(None)).await {
        Ok(Data::NativeActivity(snapshot)) => snapshot,
        Err(Health::Rejected) => return (None, Health::Rejected),
        _ => None,
    };
    // A separate request/connection, not the activity request's timeout.
    let health = match query(uid, pid, start, Data::NativeHealth(None)).await {
        Ok(Data::NativeHealth(Some(true))) => Health::Responsive,
        Ok(Data::NativeHealth(Some(false))) => Health::TimedOut,
        Ok(_) | Err(Health::Rejected) => Health::Rejected,
        Err(_) => Health::TimedOut,
    };
    (activity, health)
}
