use crate::ui_cm_interface::{Client, ConnectionManager, InvokeUiCM};
use farpane_protocol::{Inbound, Permissions};
use hbb_common::{bail, ResultType};
use std::{
    collections::HashMap,
    sync::{
        mpsc::{self, SyncSender},
        Mutex,
    },
    time::{Duration, Instant},
};

static READY: Mutex<Option<SyncSender<bool>>> = Mutex::new(None);
static PENDING: Mutex<Option<HashMap<i32, (String, Instant)>>> = Mutex::new(None);
pub fn ready(success: bool) {
    super::activity::CM_READY.store(success, std::sync::atomic::Ordering::Release);
    if let Some(sender) = READY.lock().unwrap().take() {
        let _ = sender.try_send(success);
    }
}
pub fn start() -> ResultType<()> {
    let (tx, rx) = mpsc::sync_channel(1);
    *READY.lock().unwrap() = Some(tx);
    std::thread::Builder::new()
        .name("native-cm".into())
        .spawn(|| {
            crate::ui_cm_interface::start_ipc(ConnectionManager {
                ui_handler: NativeCm,
            });
            ready(false);
        })?;
    if rx.recv_timeout(std::time::Duration::from_secs(4)) != Ok(true) {
        bail!("Native connection manager did not become ready");
    }
    std::thread::Builder::new()
        .name("native-approval-timeout".into())
        .spawn(|| loop {
            std::thread::sleep(Duration::from_secs(1));
            let clients = connections();
            let mut pending = PENDING.lock().unwrap();
            let pending = pending.get_or_insert_with(HashMap::new);
            pending.retain(|id, (peer, since)| {
                if !clients
                    .iter()
                    .any(|c| c.id == *id && c.peer == *peer && !c.authorized)
                {
                    return false;
                }
                if since.elapsed() >= Duration::from_secs(30) {
                    crate::ui_cm_interface::close(*id);
                    return false;
                }
                true
            });
        })?;
    Ok(())
}
pub fn connections() -> Vec<Inbound> {
    crate::ui_cm_interface::native_clients()
        .iter()
        .filter(|c| !c.disconnected)
        .map(|c| Inbound {
            id: c.id,
            peer: c.peer_id.clone(),
            name: c.name.clone(),
            authorized: c.authorized,
            permissions: Permissions {
                keyboard: c.keyboard,
                clipboard: c.clipboard,
                audio: c.audio,
                file: c.file,
            },
        })
        .collect()
}
#[derive(Clone)]
struct NativeCm;
impl InvokeUiCM for NativeCm {
    fn add_connection(&self, client: &Client) {
        super::control::changed();
        if !client.authorized {
            let mut pending = PENDING.lock().unwrap();
            let pending = pending.get_or_insert_with(HashMap::new);
            if pending.len() >= 64 {
                crate::ui_cm_interface::close(client.id);
                return;
            }
            pending.insert(client.id, (client.peer_id.clone(), Instant::now()));
        }
    }
    fn remove_connection(&self, _id: i32, _close: bool) {
        super::control::changed();
    }
    fn new_message(&self, id: i32, _text: String) {
        crate::ui_cm_interface::send_chat(id, "FarPane native does not support chat.".into());
    }
    fn change_theme(&self, _dark: String) {}
    fn change_language(&self) {}
    fn show_elevation(&self, _show: bool) {}
    fn update_voice_call_state(&self, client: &Client) {
        if client.incoming_voice_call {
            client.native_reject_voice();
        }
        super::control::changed();
    }
    fn file_transfer_log(&self, _action: &str, _log: &str) {
        super::control::changed();
    }
}
