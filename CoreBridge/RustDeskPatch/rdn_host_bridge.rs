// RustDesk Native Host bridge (Host Control ABI, H1a scope).
//
// This file is compiled inside RustDesk 1.4.9 at commit
// 6c578292e8ebbbec708b76986ba8c4bc7c509747. The surrounding RustDesk-derived
// build is AGPL-3.0; see CoreBridge/README.md and the repository root LICENSE.
//
// Contract (host-mode-design.md §8.1–§8.5, §9, §18; host-mode-h0.md §2.3):
// - independent `rdn-native-host` feature and namespace; no behavior change
//   without the feature, coexists with the viewer ABI (`rdn-native-core`);
// - low-frequency semantic control only: versioned JSON envelopes for
//   commands, events and snapshots; no raw frames, no encoded packets here;
// - opaque handle with create/start/stop/destroy lifecycle; at most one host
//   instance per process (process-global RustDesk state, §18 rule 1);
// - `rdn_host_set_config_root` must run before any hbb_common Config access
//   in the process; it switches APP_NAME/ORG so the config directory, toml
//   names, log directory and IPC socket are isolated;
// - temporary passwords never appear in logs; snapshot presentation is
//   redacted unless explicitly revealed for one copy.

use hbb_common::{config, password_security};
use serde_json::{json, Map, Value};
use std::{
    ffi::{c_char, c_void, CStr},
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

const HOST_ABI_VERSION: u32 = 1;
const SNAPSHOT_SCHEMA_VERSION: u32 = 1;
const UPSTREAM_COMMIT: &[u8] = b"6c578292e8ebbbec708b76986ba8c4bc7c509747\0";
const MAX_ENVELOPE_BYTES: usize = 64 * 1024;
const MAX_NAME_BYTES: usize = 64;

// Stable error codes (design §17): negative values are contract failures.
const RDN_HOST_OK: i32 = 0;
const RDN_HOST_ERR_INVALID_ARG: i32 = -1;
const RDN_HOST_ERR_ABI_MISMATCH: i32 = -2;
const RDN_HOST_ERR_BAD_STATE: i32 = -3;
// Reserved for H1b/H3 command growth; kept in the stable code surface now.
#[allow(dead_code)]
const RDN_HOST_ERR_NOT_SUPPORTED: i32 = -4;
const RDN_HOST_ERR_VALIDATION: i32 = -5;
const RDN_HOST_ERR_INTERNAL: i32 = -6;

#[repr(C)]
#[derive(Clone, Copy)]
pub enum RdnHostState {
    Created = 0,
    Starting = 1,
    Ready = 2,
    Stopping = 3,
    Stopped = 4,
    Error = 5,
}

fn state_name(state: RdnHostState) -> &'static str {
    match state {
        RdnHostState::Created => "created",
        RdnHostState::Starting => "starting",
        RdnHostState::Ready => "ready",
        RdnHostState::Stopping => "stopping",
        RdnHostState::Stopped => "stopped",
        RdnHostState::Error => "error",
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
#[allow(dead_code)] // constructed by C callers through the ABI boundary
pub enum RdnHostStopReason {
    UserRequest = 0,
    AppExit = 1,
    Error = 2,
}

/// Owned byte buffer returned by `rdn_host_copy_snapshot`; freed with
/// `rdn_host_free_bytes`. `length` is the valid UTF-8 byte count, `capacity`
/// is the allocation size and must be used for deallocation.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostOwnedBytes {
    data: *mut u8,
    length: usize,
    capacity: usize,
}

type RdnHostEventCallback = unsafe extern "C" fn(*mut c_void, *const c_char, usize);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostCallbacks {
    abi_version: u32,
    /// Versioned JSON event envelope (§8.5). Called outside Rust locks; the
    /// UTF-8 payload is only valid for the duration of the call.
    on_event: Option<RdnHostEventCallback>,
    /// Opaque pointer passed back as the first argument of every callback.
    context: *mut c_void,
}

/// H1a create options carry no fields yet; the struct exists so later
/// options (canonical server config, §18 rule 4) extend the ABI in place.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostCreateOptions {
    abi_version: u32,
}

// Process-global guards. `CONFIG_ROOT_SET` enforces the one-time early entry;
// `HOST_INSTANCE_LIVE` enforces the single-instance/exclusion contract and
// will also gate viewer-core coexistence checks (§18 rule 1).
static CONFIG_ROOT_SET: AtomicBool = AtomicBool::new(false);
static HOST_INSTANCE_LIVE: AtomicBool = AtomicBool::new(false);

pub struct RdnHost {
    instance_id: String,
    state: RdnHostState,
    local_id: String,
    registration_status: &'static str,
    reveal_temporary_password: bool,
    last_error: Option<String>,
    event_id: AtomicU64,
    callbacks: RdnHostCallbacks,
}

impl RdnHost {
    fn emit_event(&self, event_type: &str, payload: Value) {
        let Some(callback) = self.callbacks.on_event else {
            return;
        };
        let envelope = json!({
            "schemaVersion": SNAPSHOT_SCHEMA_VERSION,
            "eventId": self.event_id.fetch_add(1, Ordering::Relaxed),
            "eventType": event_type,
            "hostInstanceId": self.instance_id,
            "sentAt": now_unix_millis(),
            "payload": payload,
        });
        let Some(encoded) = serde_json::to_vec(&envelope).ok() else {
            return;
        };
        unsafe { callback(self.callbacks.context, encoded.as_ptr() as *const c_char, encoded.len()) };
    }

    fn emit_snapshot_changed(&self) {
        self.emit_event("snapshotChanged", json!({}));
    }

    fn emit_command_result(&self, command_id: &str, status: &str, detail: &str) {
        self.emit_event(
            "commandResult",
            json!({
                "commandId": command_id,
                "status": status,
                "detail": detail,
            }),
        );
    }

    fn snapshot_json(&mut self) -> Value {
        // §8.3 minimal field set; §9.2: password only leaves Rust when the UI
        // explicitly revealed it, and the reveal flag is one-shot.
        let presentation = if self.reveal_temporary_password {
            self.reveal_temporary_password = false;
            json!({ "policy": "revealed", "value": password_security::temporary_password() })
        } else {
            json!({ "policy": "redacted" })
        };
        let mut map = Map::new();
        map.insert("schemaVersion".into(), json!(SNAPSHOT_SCHEMA_VERSION));
        map.insert("hostInstanceId".into(), json!(self.instance_id));
        map.insert("hostState".into(), json!(state_name(self.state)));
        map.insert("localId".into(), json!(self.local_id));
        map.insert("temporaryPasswordPresentation".into(), presentation);
        map.insert("registrationStatus".into(), json!(self.registration_status));
        map.insert(
            "lastError".into(),
            match &self.last_error {
                Some(error) => json!(error),
                None => Value::Null,
            },
        );
        map.insert("observedAt".into(), json!(now_unix_millis()));
        Value::Object(map)
    }
}

fn now_unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}

/// CSPRNG hex token for the host instance identity (not a secret credential).
fn random_instance_id() -> String {
    let mut bytes = [0u8; 8];
    if let Ok(mut file) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        if file.read_exact(&mut bytes).is_err() {
            bytes = now_unix_millis().to_ne_bytes();
        }
    } else {
        bytes = now_unix_millis().to_ne_bytes();
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

unsafe fn required_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        return Err(RDN_HOST_ERR_INVALID_ARG);
    }
    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| RDN_HOST_ERR_VALIDATION)
}

fn valid_namespace_component(value: &str) -> bool {
    // APP_NAME/ORG flow into directory names, toml names and the IPC socket
    // path; keep them conservative so isolation cannot escape the sandbox.
    !value.is_empty()
        && value.len() <= MAX_NAME_BYTES
        && !value.contains(|component| matches!(component, '/' | '\\' | ':' | '\0'))
        && value != "."
        && value != ".."
}

#[no_mangle]
pub extern "C" fn rdn_host_abi_version() -> u32 {
    HOST_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn rdn_host_upstream_commit() -> *const c_char {
    UPSTREAM_COMMIT.as_ptr() as *const c_char
}

/// Early config-root entry (host-mode-h0.md §2.3 conclusion 2): must be the
/// first host ABI call in the process, before any hbb_common Config access,
/// and runs exactly once. Switching APP_NAME/ORG moves the config directory,
/// toml file names, log directory and IPC socket (§3.5 of the H0 report).
#[no_mangle]
pub unsafe extern "C" fn rdn_host_set_config_root(
    app_name: *const c_char,
    org: *const c_char,
) -> i32 {
    if CONFIG_ROOT_SET.load(Ordering::Acquire) || HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    let app_name = match required_string(app_name) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let org = match required_string(org) {
        Ok(value) => value,
        Err(code) => return code,
    };
    if !valid_namespace_component(&app_name) || !valid_namespace_component(&org) {
        return RDN_HOST_ERR_VALIDATION;
    }
    *config::APP_NAME.write().unwrap() = app_name;
    #[cfg(target_os = "macos")]
    {
        *config::ORG.write().unwrap() = org;
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = org;
    }
    CONFIG_ROOT_SET.store(true, Ordering::Release);
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_create(
    options: *const RdnHostCreateOptions,
    callbacks: *const RdnHostCallbacks,
    out_host: *mut *mut RdnHost,
) -> i32 {
    if options.is_null() || callbacks.is_null() || out_host.is_null() {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    if (*options).abi_version != HOST_ABI_VERSION || (*callbacks).abi_version != HOST_ABI_VERSION
    {
        return RDN_HOST_ERR_ABI_MISMATCH;
    }
    if !CONFIG_ROOT_SET.load(Ordering::Acquire) {
        // Fail closed: creating a host before the config-root switch would
        // touch the shared RustDesk config namespace (§18 rule 6).
        return RDN_HOST_ERR_BAD_STATE;
    }
    if HOST_INSTANCE_LIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return RDN_HOST_ERR_BAD_STATE;
    }
    let host = Box::new(RdnHost {
        instance_id: random_instance_id(),
        state: RdnHostState::Created,
        local_id: String::new(),
        registration_status: "notStarted",
        reveal_temporary_password: false,
        last_error: None,
        event_id: AtomicU64::new(0),
        callbacks: *callbacks,
    });
    *out_host = Box::into_raw(host);
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_start(host: *mut RdnHost) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if !matches!(host.state, RdnHostState::Created | RdnHostState::Stopped) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    host.state = RdnHostState::Starting;
    host.emit_snapshot_changed();
    // First Config access inside the isolated root: generates and persists
    // the stable ID/key pair (§9.1). H1a.3 extends this with the Hermes
    // rendezvous registration; until then status stays `pending`.
    host.local_id = config::Config::get_id();
    password_security::update_temporary_password();
    host.registration_status = "pending";
    host.state = RdnHostState::Ready;
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_stop(host: *mut RdnHost, reason: RdnHostStopReason) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if matches!(host.state, RdnHostState::Stopped | RdnHostState::Stopping) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    host.state = RdnHostState::Stopping;
    // Invalidate the temporary password on stop (§9.2): rotate so the old
    // value cannot survive a stop/start cycle.
    password_security::update_temporary_password();
    host.reveal_temporary_password = false;
    host.registration_status = "notStarted";
    if matches!(reason, RdnHostStopReason::Error) {
        host.state = RdnHostState::Error;
    } else {
        host.state = RdnHostState::Stopped;
    }
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

fn parse_envelope(bytes: &[u8]) -> Result<Value, i32> {
    if bytes.is_empty() || bytes.len() > MAX_ENVELOPE_BYTES {
        return Err(RDN_HOST_ERR_VALIDATION);
    }
    serde_json::from_slice(bytes).map_err(|_| RDN_HOST_ERR_VALIDATION)
}

fn handle_command(host: &mut RdnHost, command_id: &str, name: &str) {
    match name {
        "enableHost" => {
            // Host already runs in-process for the H1a spike; accept as no-op.
            host.emit_command_result(command_id, "ok", "host-enabled");
        }
        "disableHost" => {
            host.emit_command_result(command_id, "ok", "host-disabled");
        }
        "regenerateTemporaryPassword" => {
            password_security::update_temporary_password();
            host.emit_command_result(command_id, "ok", "temporary-password-regenerated");
            host.emit_snapshot_changed();
        }
        "revealTemporaryPassword" => {
            host.reveal_temporary_password = true;
            host.emit_command_result(command_id, "ok", "temporary-password-revealed");
        }
        _ => {
            host.emit_command_result(command_id, "unknownCommand", name);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_command(
    host: *mut RdnHost,
    command_json: *const u8,
    length: usize,
) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if command_json.is_null() {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    let bytes = std::slice::from_raw_parts(command_json, length);
    let envelope = match parse_envelope(bytes) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let command_id = match envelope.get("commandId").and_then(Value::as_str) {
        Some(value) if !value.is_empty() && value.len() <= 128 => value.to_owned(),
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    let name = match envelope.get("name").and_then(Value::as_str) {
        Some(value) if !value.is_empty() => value.to_owned(),
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    handle_command(host, &command_id, &name);
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_copy_snapshot(
    host: *mut RdnHost,
    out_snapshot: *mut RdnHostOwnedBytes,
) -> i32 {
    let (Some(host), Some(out_snapshot)) = (host.as_mut(), out_snapshot.as_mut()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    let encoded = match serde_json::to_vec(&host.snapshot_json()) {
        Ok(value) => value,
        Err(_) => return RDN_HOST_ERR_INTERNAL,
    };
    let mut boxed = encoded.into_boxed_slice();
    out_snapshot.data = boxed.as_mut_ptr();
    out_snapshot.length = boxed.len();
    out_snapshot.capacity = boxed.len();
    std::mem::forget(boxed);
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_free_bytes(bytes: RdnHostOwnedBytes) {
    if bytes.data.is_null() || bytes.capacity == 0 {
        return;
    }
    drop(Box::from_raw(std::slice::from_raw_parts_mut(
        bytes.data,
        bytes.capacity,
    )));
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_destroy(host: *mut RdnHost) {
    if host.is_null() {
        return;
    }
    let host = Box::from_raw(host);
    if !matches!(host.state, RdnHostState::Stopped | RdnHostState::Error) {
        password_security::update_temporary_password();
    }
    HOST_INSTANCE_LIVE.store(false, Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_namespace_components_that_could_escape_directories() {
        assert!(valid_namespace_component("FarPaneHost"));
        assert!(valid_namespace_component("io.rustdesknative"));
        assert!(!valid_namespace_component(""));
        assert!(!valid_namespace_component("../evil"));
        assert!(!valid_namespace_component("a/b"));
        assert!(!valid_namespace_component("a:b"));
        assert!(!valid_namespace_component(&"x".repeat(MAX_NAME_BYTES + 1)));
    }

    #[test]
    fn command_envelope_bounds_are_enforced() {
        assert_eq!(parse_envelope(b""), Err(RDN_HOST_ERR_VALIDATION));
        assert_eq!(
            parse_envelope(&vec![b' '; MAX_ENVELOPE_BYTES + 1]),
            Err(RDN_HOST_ERR_VALIDATION)
        );
        assert!(parse_envelope(b"{\"commandId\":\"1\",\"name\":\"enableHost\"}").is_ok());
        assert_eq!(parse_envelope(b"{not json"), Err(RDN_HOST_ERR_VALIDATION));
    }
}
