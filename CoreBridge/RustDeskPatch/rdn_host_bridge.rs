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
    collections::HashMap,
    ffi::{c_char, c_void, CStr},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{sync_channel, Receiver, SyncSender, TrySendError},
        Arc, Mutex,
    },
    thread::JoinHandle,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const HOST_ABI_VERSION: u32 = 2;
const HOST_MEDIA_ABI_VERSION: u32 = 1;
const SNAPSHOT_SCHEMA_VERSION: u32 = 1;
const UPSTREAM_COMMIT: &[u8] = b"6c578292e8ebbbec708b76986ba8c4bc7c509747\0";
const MAX_ENVELOPE_BYTES: usize = 64 * 1024;
const MAX_NAME_BYTES: usize = 64;
const MAX_SERVER_BYTES: usize = 512;
const MAX_SERVER_PUBLIC_KEY_BYTES: usize = 1024;
const MAX_ENCODER_ID_BYTES: usize = 128;
const MAX_MEDIA_ACCESS_UNIT_BYTES: usize = 8 * 1024 * 1024;
const MEDIA_QUEUE_CAPACITY: usize = 3;
const MEDIA_FLAG_KEYFRAME: u32 = 1 << 0;
const MEDIA_FLAG_PARAMETER_SETS: u32 = 1 << 1;
const MEDIA_KNOWN_FLAGS: u32 = MEDIA_FLAG_KEYFRAME | MEDIA_FLAG_PARAMETER_SETS;
pub(crate) const MEDIA_CODEC_H264: u32 = 1;
pub(crate) const MEDIA_CODEC_H265: u32 = 2;
const MEDIA_FRAMING_ANNEX_B: u32 = 1;
const MEDIA_FRAMING_AVCC: u32 = 2;

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
const RDN_HOST_ERR_STALE_EPOCH: i32 = -7;
const RDN_HOST_ERR_BACKPRESSURE: i32 = -8;
const RDN_HOST_ERR_PACKET_TOO_LARGE: i32 = -9;
const RDN_HOST_ERR_NON_MONOTONIC_PTS: i32 = -10;
const RDN_HOST_ERR_MISSING_PARAMETER_SETS: i32 = -11;
const RDN_HOST_ERR_CODEC_MISMATCH: i32 = -12;

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

/// Canonical server configuration is copied during create and installed in
/// the isolated config root before any identity or rendezvous access (§18).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostCreateOptions {
    abi_version: u32,
    rendezvous_server: *const c_char,
    relay_server: *const c_char,
    server_public_key: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostEncoderCapabilities {
    abi_version: u32,
    host_instance_id: *const c_char,
    h264_hardware: u32,
    h265_hardware: u32,
    max_width: u32,
    max_height: u32,
    max_fps: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostEncodedAccessUnit {
    abi_version: u32,
    host_instance_id: *const c_char,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    codec: u32,
    framing: u32,
    flags: u32,
    pts_us: u64,
    data: *const u8,
    length: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostEncoderState {
    abi_version: u32,
    host_instance_id: *const c_char,
    connection_epoch: u64,
    codec_epoch: u64,
    codec: u32,
    hardware_accelerated: u32,
    software_fallback: u32,
    encoder_id: *const c_char,
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
    event_id: Arc<AtomicU64>,
    callbacks: RdnHostCallbacks,
    rendezvous_server: String,
    relay_server: String,
    server_public_key: String,
    runtime: Option<HostRuntime>,
}

struct HostRuntime {
    stop_requested: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

struct RuntimeFinished(Arc<AtomicBool>);

#[derive(Clone)]
struct MediaHostBinding {
    instance_id: String,
    callback: Option<RdnHostEventCallback>,
    context: usize,
    event_id: Arc<AtomicU64>,
}

#[derive(Clone, Copy, Default)]
struct MediaCapabilities {
    h264_hardware: bool,
    h265_hardware: bool,
    max_width: u32,
    max_height: u32,
    max_fps: u32,
}

struct MediaRoute {
    connection_epoch: u64,
    codec_epoch: u64,
    display_revision: u64,
    codec: u32,
    sender: SyncSender<NativeMediaAccessUnit>,
    last_pts_us: Option<u64>,
    needs_parameter_sets: bool,
}

#[derive(Default)]
struct MediaBroker {
    binding: Option<MediaHostBinding>,
    capabilities: MediaCapabilities,
    routes: HashMap<u64, MediaRoute>,
}

pub(crate) struct NativeMediaAccessUnit {
    pub(crate) codec: u32,
    pub(crate) framing: u32,
    pub(crate) pts_us: u64,
    pub(crate) keyframe: bool,
    pub(crate) has_parameter_sets: bool,
    pub(crate) data: Vec<u8>,
}

#[derive(Clone, Copy)]
pub(crate) struct NativeMediaPacketMetadata {
    pub(crate) framing: u32,
    pub(crate) pts_us: u64,
    pub(crate) keyframe: bool,
    pub(crate) has_parameter_sets: bool,
}

impl NativeMediaAccessUnit {
    pub(crate) fn metadata(&self) -> NativeMediaPacketMetadata {
        NativeMediaPacketMetadata {
            framing: self.framing,
            pts_us: self.pts_us,
            keyframe: self.keyframe,
            has_parameter_sets: self.has_parameter_sets,
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) enum NativeMediaMilestone {
    FirstPacketDispatched,
    FirstPacketAcknowledged,
    RefreshKeyframeDispatched,
}

pub(crate) struct NativeMediaRoute {
    pub(crate) connection_epoch: u64,
    pub(crate) codec_epoch: u64,
    pub(crate) display_id: u64,
    pub(crate) display_revision: u64,
    pub(crate) codec: u32,
    pub(crate) receiver: Receiver<NativeMediaAccessUnit>,
}

static NEXT_CONNECTION_EPOCH: AtomicU64 = AtomicU64::new(1);
static NEXT_CODEC_EPOCH: AtomicU64 = AtomicU64::new(1);

lazy_static::lazy_static! {
    static ref MEDIA_BROKER: Mutex<MediaBroker> = Mutex::new(MediaBroker::default());
}

fn emit_bound_event(binding: &MediaHostBinding, event_type: &str, payload: Value) {
    let Some(callback) = binding.callback else {
        return;
    };
    let envelope = json!({
        "schemaVersion": SNAPSHOT_SCHEMA_VERSION,
        "eventId": binding.event_id.fetch_add(1, Ordering::Relaxed),
        "eventType": event_type,
        "hostInstanceId": binding.instance_id,
        "sentAt": now_unix_millis(),
        "payload": payload,
    });
    let Some(encoded) = serde_json::to_vec(&envelope).ok() else {
        return;
    };
    unsafe {
        callback(
            binding.context as *mut c_void,
            encoded.as_ptr() as *const c_char,
            encoded.len(),
        )
    };
}

fn bind_media_host(host: &RdnHost) {
    let mut broker = MEDIA_BROKER.lock().unwrap();
    broker.routes.clear();
    broker.capabilities = MediaCapabilities::default();
    broker.binding = Some(MediaHostBinding {
        instance_id: host.instance_id.clone(),
        callback: host.callbacks.on_event,
        context: host.callbacks.context as usize,
        event_id: host.event_id.clone(),
    });
    scrap::codec::set_native_encoding_capabilities(false, false);
}

/// The native FarPane Host owns connection status inside the main App and has
/// no separate RustDesk connection-manager process. Server connections use
/// this signal to avoid spawning the current executable with `--cm`.
pub(crate) fn native_host_is_bound() -> bool {
    MEDIA_BROKER.lock().unwrap().binding.is_some()
}

fn unbind_media_host() {
    let (binding, routes) = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let binding = broker.binding.take();
        let routes = broker
            .routes
            .drain()
            .map(|(display, route)| (display, route.connection_epoch, route.codec_epoch))
            .collect::<Vec<_>>();
        broker.capabilities = MediaCapabilities::default();
        (binding, routes)
    };
    scrap::codec::set_native_encoding_capabilities(false, false);
    if let Some(binding) = binding {
        for (display_id, connection_epoch, codec_epoch) in routes {
            emit_bound_event(
                &binding,
                "mediaControl",
                json!({
                    "command": "stopCapture",
                    "connectionEpoch": connection_epoch,
                    "codecEpoch": codec_epoch,
                    "displayId": display_id,
                }),
            );
        }
    }
}

pub(crate) fn native_media_begin_route(
    display_id: u64,
    display_revision: u64,
    codec: u32,
    width: u32,
    height: u32,
    fps: u32,
    bitrate: u32,
) -> Result<NativeMediaRoute, &'static str> {
    let (sender, receiver) = sync_channel(MEDIA_QUEUE_CAPACITY);
    let connection_epoch = NEXT_CONNECTION_EPOCH.fetch_add(1, Ordering::Relaxed);
    let codec_epoch = NEXT_CODEC_EPOCH.fetch_add(1, Ordering::Relaxed);
    let binding = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let binding = broker
            .binding
            .clone()
            .ok_or("native host media is not bound")?;
        let capable = match codec {
            MEDIA_CODEC_H264 => broker.capabilities.h264_hardware,
            MEDIA_CODEC_H265 => broker.capabilities.h265_hardware,
            _ => false,
        };
        if !capable {
            return Err("negotiated codec is not available from native adapter");
        }
        if width == 0
            || height == 0
            || fps == 0
            || width > broker.capabilities.max_width
            || height > broker.capabilities.max_height
            || fps > broker.capabilities.max_fps
        {
            return Err("display requirements exceed native adapter capabilities");
        }
        broker.routes.insert(
            display_id,
            MediaRoute {
                connection_epoch,
                codec_epoch,
                display_revision,
                codec,
                sender,
                last_pts_us: None,
                needs_parameter_sets: true,
            },
        );
        binding
    };
    let codec_name = if codec == MEDIA_CODEC_H264 {
        "h264"
    } else {
        "h265"
    };
    emit_bound_event(
        &binding,
        "mediaControl",
        json!({
            "command": "startCapture",
            "connectionEpoch": connection_epoch,
            "codecEpoch": codec_epoch,
            "displayId": display_id,
            "displayRevision": display_revision,
        }),
    );
    emit_bound_event(
        &binding,
        "mediaControl",
        json!({
            "command": "reconfigure",
            "connectionEpoch": connection_epoch,
            "codecEpoch": codec_epoch,
            "displayId": display_id,
            "displayRevision": display_revision,
            "codec": codec_name,
            "width": width,
            "height": height,
            "fps": fps,
            "bitrate": bitrate,
        }),
    );
    Ok(NativeMediaRoute {
        connection_epoch,
        codec_epoch,
        display_id,
        display_revision,
        codec,
        receiver,
    })
}

pub(crate) fn native_media_request_idr(route: &NativeMediaRoute, reason: &str) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaControl",
            json!({
                "command": "requestIdr",
                "connectionEpoch": route.connection_epoch,
                "codecEpoch": route.codec_epoch,
                "displayId": route.display_id,
                "displayRevision": route.display_revision,
                "reason": reason,
            }),
        );
    }
}

pub(crate) fn native_media_report_milestone(
    route: &NativeMediaRoute,
    milestone: NativeMediaMilestone,
    packet: NativeMediaPacketMetadata,
    subscriber_count: usize,
) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    let Some(binding) = binding else { return };
    let Some(payload) = native_media_milestone_payload(route, milestone, packet, subscriber_count)
    else {
        return;
    };
    emit_bound_event(&binding, "mediaDiagnostic", payload);
}

fn native_media_milestone_payload(
    route: &NativeMediaRoute,
    milestone: NativeMediaMilestone,
    packet: NativeMediaPacketMetadata,
    subscriber_count: usize,
) -> Option<Value> {
    if subscriber_count == 0 {
        return None;
    }
    let kind = match milestone {
        NativeMediaMilestone::FirstPacketDispatched => "firstPacketDispatched",
        NativeMediaMilestone::FirstPacketAcknowledged => "firstPacketAcknowledged",
        NativeMediaMilestone::RefreshKeyframeDispatched => "refreshKeyframeDispatched",
    };
    let codec = match route.codec {
        MEDIA_CODEC_H264 => "h264",
        MEDIA_CODEC_H265 => "h265",
        _ => return None,
    };
    let framing = match packet.framing {
        MEDIA_FRAMING_ANNEX_B => "annexB",
        MEDIA_FRAMING_AVCC => "avcc",
        _ => return None,
    };
    Some(json!({
        "kind": kind,
        "connectionEpoch": route.connection_epoch,
        "codecEpoch": route.codec_epoch,
        "displayId": route.display_id,
        "displayRevision": route.display_revision,
        "codec": codec,
        "framing": framing,
        "ptsUs": packet.pts_us,
        "keyframe": packet.keyframe,
        "hasParameterSets": packet.has_parameter_sets,
        "subscriberCount": subscriber_count,
    }))
}

pub(crate) fn native_media_end_route(route: &NativeMediaRoute) {
    let binding = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let matches = broker
            .routes
            .get(&route.display_id)
            .map(|current| {
                current.connection_epoch == route.connection_epoch
                    && current.codec_epoch == route.codec_epoch
            })
            .unwrap_or(false);
        if matches {
            broker.routes.remove(&route.display_id);
            broker.binding.clone()
        } else {
            None
        }
    };
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaControl",
            json!({
                "command": "stopCapture",
                "connectionEpoch": route.connection_epoch,
                "codecEpoch": route.codec_epoch,
                "displayId": route.display_id,
            }),
        );
    }
}

impl Drop for RuntimeFinished {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

impl HostRuntime {
    fn start(rendezvous_server: String) -> Result<Self, ()> {
        let stop_requested = Arc::new(AtomicBool::new(false));
        let finished = Arc::new(AtomicBool::new(false));
        let thread_stop = stop_requested.clone();
        let thread_finished = finished.clone();
        crate::RendezvousMediator::prepare_native_host_runtime();
        let thread = std::thread::Builder::new()
            .name("farpane-host-rendezvous".to_owned())
            .spawn(move || {
                let _finished = RuntimeFinished(thread_finished);
                let Ok(runtime) = hbb_common::tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                else {
                    return;
                };
                runtime.block_on(async move {
                    let server = crate::server::new();
                    while !thread_stop.load(Ordering::Acquire) {
                        let _ = crate::RendezvousMediator::start(
                            server.clone(),
                            rendezvous_server.clone(),
                        )
                        .await;
                        if thread_stop.load(Ordering::Acquire) {
                            break;
                        }
                        config::Config::reset_online();
                        hbb_common::tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                });
            })
            .map_err(|_| ())?;
        Ok(Self {
            stop_requested,
            finished,
            thread: Some(thread),
        })
    }

    fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    fn stop(&mut self) -> bool {
        self.stop_requested.store(true, Ordering::Release);
        crate::RendezvousMediator::stop_native_host_runtime();
        let joined = self
            .thread
            .take()
            .map(|thread| thread.join().is_ok())
            .unwrap_or(true);
        config::Config::reset_online();
        joined
    }
}

impl RdnHost {
    fn refresh_registration_state(&mut self) {
        if !matches!(self.state, RdnHostState::Starting | RdnHostState::Ready) {
            return;
        }
        if config::Config::get_key_confirmed() && config::get_online_state() > 0 {
            self.registration_status = "ready";
            self.state = RdnHostState::Ready;
            self.last_error = None;
        } else if self
            .runtime
            .as_ref()
            .map(HostRuntime::is_finished)
            .unwrap_or(true)
        {
            self.registration_status = "degraded";
            self.state = RdnHostState::Error;
            self.last_error = Some("registration.runtimeExited".to_owned());
        } else {
            self.registration_status = "pending";
            self.state = RdnHostState::Starting;
        }
    }

    fn emit_event(&self, event_type: &str, payload: Value) {
        emit_bound_event(
            &MediaHostBinding {
                instance_id: self.instance_id.clone(),
                callback: self.callbacks.on_event,
                context: self.callbacks.context as usize,
                event_id: self.event_id.clone(),
            },
            event_type,
            payload,
        );
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
        self.refresh_registration_state();
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

unsafe fn optional_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        return Ok(String::new());
    }
    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| RDN_HOST_ERR_VALIDATION)
}

fn valid_server(value: &str, allow_empty: bool) -> bool {
    (allow_empty || !value.is_empty())
        && value.len() <= MAX_SERVER_BYTES
        && !value.chars().any(|character| {
            character.is_control()
                || character.is_whitespace()
                || matches!(character, '@' | '?' | '#' | '&')
        })
}

fn valid_server_public_key(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_SERVER_PUBLIC_KEY_BYTES
        && crate::decode64(value)
            .map(|decoded| decoded.len() == 32)
            .unwrap_or(false)
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
    if (*options).abi_version != HOST_ABI_VERSION || (*callbacks).abi_version != HOST_ABI_VERSION {
        return RDN_HOST_ERR_ABI_MISMATCH;
    }
    if !CONFIG_ROOT_SET.load(Ordering::Acquire) {
        // Fail closed: creating a host before the config-root switch would
        // touch the shared RustDesk config namespace (§18 rule 6).
        return RDN_HOST_ERR_BAD_STATE;
    }
    let rendezvous_server = match required_string((*options).rendezvous_server) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let relay_server = match optional_string((*options).relay_server) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let server_public_key = match required_string((*options).server_public_key) {
        Ok(value) => value,
        Err(code) => return code,
    };
    if !valid_server(&rendezvous_server, false)
        || !valid_server(&relay_server, true)
        || !valid_server_public_key(&server_public_key)
    {
        return RDN_HOST_ERR_VALIDATION;
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
        event_id: Arc::new(AtomicU64::new(0)),
        callbacks: *callbacks,
        rendezvous_server,
        relay_server,
        server_public_key,
        runtime: None,
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
    // Install the canonical self-hosted configuration before identity or
    // rendezvous state is touched. The public key is persisted only in the
    // isolated RustDesk host config and never emitted in snapshots/logs.
    config::Config::set_option(
        "custom-rendezvous-server".to_owned(),
        host.rendezvous_server.clone(),
    );
    config::Config::set_option("relay-server".to_owned(), host.relay_server.clone());
    config::Config::set_option("key".to_owned(), host.server_public_key.clone());
    // First identity access inside the isolated root generates and persists
    // the stable ID/key pair (§9.1).
    host.local_id = config::Config::get_id();
    password_security::update_temporary_password();
    config::Config::set_option("stop-service".to_owned(), String::new());
    bind_media_host(host);
    host.runtime = match HostRuntime::start(host.rendezvous_server.clone()) {
        Ok(runtime) => Some(runtime),
        Err(()) => {
            unbind_media_host();
            host.registration_status = "degraded";
            host.state = RdnHostState::Error;
            host.last_error = Some("registration.runtimeStartFailed".to_owned());
            host.emit_snapshot_changed();
            return RDN_HOST_ERR_INTERNAL;
        }
    };
    host.registration_status = "pending";
    host.state = RdnHostState::Starting;
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
    unbind_media_host();
    if let Some(mut runtime) = host.runtime.take() {
        if !runtime.stop() {
            host.registration_status = "degraded";
            host.state = RdnHostState::Error;
            host.last_error = Some("registration.runtimeJoinFailed".to_owned());
            host.emit_snapshot_changed();
            return RDN_HOST_ERR_INTERNAL;
        }
    }
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
pub extern "C" fn rdn_host_media_abi_version() -> u32 {
    HOST_MEDIA_ABI_VERSION
}

unsafe fn validate_media_instance(
    host: &RdnHost,
    abi_version: u32,
    instance_pointer: *const c_char,
) -> Result<(), i32> {
    if abi_version != HOST_MEDIA_ABI_VERSION {
        return Err(RDN_HOST_ERR_ABI_MISMATCH);
    }
    let instance_id = required_string(instance_pointer)?;
    if instance_id != host.instance_id {
        return Err(RDN_HOST_ERR_STALE_EPOCH);
    }
    if !matches!(host.state, RdnHostState::Starting | RdnHostState::Ready) {
        return Err(RDN_HOST_ERR_BAD_STATE);
    }
    Ok(())
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_media_set_capabilities(
    host: *mut RdnHost,
    capabilities: *const RdnHostEncoderCapabilities,
) -> i32 {
    let (Some(host), Some(capabilities)) = (host.as_ref(), capabilities.as_ref()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if let Err(code) = validate_media_instance(
        host,
        capabilities.abi_version,
        capabilities.host_instance_id,
    ) {
        return code;
    }
    if capabilities.h264_hardware > 1
        || capabilities.h265_hardware > 1
        || capabilities.h264_hardware + capabilities.h265_hardware == 0
        || !(16..=16_384).contains(&capabilities.max_width)
        || !(16..=16_384).contains(&capabilities.max_height)
        || !(1..=240).contains(&capabilities.max_fps)
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    let mut broker = MEDIA_BROKER.lock().unwrap();
    let Some(binding) = broker.binding.as_ref() else {
        return RDN_HOST_ERR_BAD_STATE;
    };
    if binding.instance_id != host.instance_id {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    broker.capabilities = MediaCapabilities {
        h264_hardware: capabilities.h264_hardware == 1,
        h265_hardware: capabilities.h265_hardware == 1,
        max_width: capabilities.max_width,
        max_height: capabilities.max_height,
        max_fps: capabilities.max_fps,
    };
    scrap::codec::set_native_encoding_capabilities(
        broker.capabilities.h264_hardware,
        broker.capabilities.h265_hardware,
    );
    drop(broker);
    scrap::codec::Encoder::update(scrap::codec::EncodingUpdate::Check);
    host.emit_event(
        "mediaCapabilitiesChanged",
        json!({
            "h264Hardware": capabilities.h264_hardware == 1,
            "h265Hardware": capabilities.h265_hardware == 1,
            "maxWidth": capabilities.max_width,
            "maxHeight": capabilities.max_height,
            "maxFps": capabilities.max_fps,
        }),
    );
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_media_submit_access_unit(
    host: *mut RdnHost,
    access_unit: *const RdnHostEncodedAccessUnit,
) -> i32 {
    let (Some(host), Some(access_unit)) = (host.as_ref(), access_unit.as_ref()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if let Err(code) =
        validate_media_instance(host, access_unit.abi_version, access_unit.host_instance_id)
    {
        return code;
    }
    if access_unit.data.is_null() || access_unit.length == 0 {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    if access_unit.length > MAX_MEDIA_ACCESS_UNIT_BYTES {
        return RDN_HOST_ERR_PACKET_TOO_LARGE;
    }
    if !matches!(access_unit.codec, MEDIA_CODEC_H264 | MEDIA_CODEC_H265)
        || !matches!(
            access_unit.framing,
            MEDIA_FRAMING_ANNEX_B | MEDIA_FRAMING_AVCC
        )
        || access_unit.flags & !MEDIA_KNOWN_FLAGS != 0
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    let keyframe = access_unit.flags & MEDIA_FLAG_KEYFRAME != 0;
    let has_parameter_sets = access_unit.flags & MEDIA_FLAG_PARAMETER_SETS != 0;
    if keyframe && !has_parameter_sets {
        return RDN_HOST_ERR_MISSING_PARAMETER_SETS;
    }
    // Copy before touching the queue so Swift may release its callback-scoped
    // VideoToolbox buffer as soon as this function returns.
    let data = std::slice::from_raw_parts(access_unit.data, access_unit.length).to_vec();
    let mut broker = MEDIA_BROKER.lock().unwrap();
    let Some(route) = broker.routes.get_mut(&access_unit.display_id) else {
        return RDN_HOST_ERR_BAD_STATE;
    };
    if route.connection_epoch != access_unit.connection_epoch
        || route.codec_epoch != access_unit.codec_epoch
        || route.display_revision != access_unit.display_revision
    {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    if route.codec != access_unit.codec {
        return RDN_HOST_ERR_CODEC_MISMATCH;
    }
    if route.needs_parameter_sets && !(keyframe && has_parameter_sets) {
        return RDN_HOST_ERR_MISSING_PARAMETER_SETS;
    }
    if route
        .last_pts_us
        .map(|last| access_unit.pts_us <= last)
        .unwrap_or(false)
    {
        return RDN_HOST_ERR_NON_MONOTONIC_PTS;
    }
    let packet = NativeMediaAccessUnit {
        codec: access_unit.codec,
        framing: access_unit.framing,
        pts_us: access_unit.pts_us,
        keyframe,
        has_parameter_sets,
        data,
    };
    match route.sender.try_send(packet) {
        Ok(()) => {
            route.last_pts_us = Some(access_unit.pts_us);
            route.needs_parameter_sets = false;
            RDN_HOST_OK
        }
        Err(TrySendError::Full(_)) => RDN_HOST_ERR_BACKPRESSURE,
        Err(TrySendError::Disconnected(_)) => RDN_HOST_ERR_BAD_STATE,
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_media_report_encoder_state(
    host: *mut RdnHost,
    state: *const RdnHostEncoderState,
) -> i32 {
    let (Some(host), Some(state)) = (host.as_ref(), state.as_ref()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if let Err(code) = validate_media_instance(host, state.abi_version, state.host_instance_id) {
        return code;
    }
    if !matches!(state.codec, MEDIA_CODEC_H264 | MEDIA_CODEC_H265)
        || state.hardware_accelerated > 1
        || state.software_fallback > 1
        || state.hardware_accelerated + state.software_fallback != 1
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    let encoder_id = match required_string(state.encoder_id) {
        Ok(value) if !value.is_empty() && value.len() <= MAX_ENCODER_ID_BYTES => value,
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    let broker = MEDIA_BROKER.lock().unwrap();
    let route_matches = broker.routes.values().any(|route| {
        route.connection_epoch == state.connection_epoch
            && route.codec_epoch == state.codec_epoch
            && route.codec == state.codec
    });
    drop(broker);
    if !route_matches {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    host.emit_event(
        "encoderStateChanged",
        json!({
            "connectionEpoch": state.connection_epoch,
            "codecEpoch": state.codec_epoch,
            "codec": if state.codec == MEDIA_CODEC_H264 { "h264" } else { "h265" },
            "hardwareAccelerated": state.hardware_accelerated == 1,
            "softwareFallback": state.software_fallback == 1,
            "encoderId": encoder_id,
        }),
    );
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_destroy(host: *mut RdnHost) {
    if host.is_null() {
        return;
    }
    let mut host = Box::from_raw(host);
    unbind_media_host();
    if let Some(mut runtime) = host.runtime.take() {
        let _ = runtime.stop();
    }
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

    #[test]
    fn media_milestone_payload_is_sanitized_and_fail_closed() {
        let (_, receiver) = sync_channel(1);
        let route = NativeMediaRoute {
            connection_epoch: 7,
            codec_epoch: 9,
            display_id: 0,
            display_revision: 3,
            codec: MEDIA_CODEC_H264,
            receiver,
        };
        let packet = NativeMediaPacketMetadata {
            framing: MEDIA_FRAMING_AVCC,
            pts_us: 42_999,
            keyframe: true,
            has_parameter_sets: true,
        };
        let payload = native_media_milestone_payload(
            &route,
            NativeMediaMilestone::FirstPacketAcknowledged,
            packet,
            1,
        )
        .unwrap();
        assert_eq!(payload["kind"], "firstPacketAcknowledged");
        assert_eq!(payload["codec"], "h264");
        assert_eq!(payload["framing"], "avcc");
        assert_eq!(payload["subscriberCount"], 1);
        let encoded = serde_json::to_string(&payload).unwrap();
        for forbidden in ["peerId", "data", "password", "server"] {
            assert!(!encoded.contains(forbidden));
        }
        assert!(native_media_milestone_payload(
            &route,
            NativeMediaMilestone::FirstPacketDispatched,
            packet,
            0,
        )
        .is_none());
        let invalid_packet = NativeMediaPacketMetadata {
            framing: 99,
            ..packet
        };
        assert!(native_media_milestone_payload(
            &route,
            NativeMediaMilestone::RefreshKeyframeDispatched,
            invalid_packet,
            1,
        )
        .is_none());
    }
}
