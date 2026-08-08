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

use hbb_common::{config, password_security, tokio};
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
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const HOST_ABI_VERSION: u32 = 5;
const HOST_MEDIA_ABI_VERSION: u32 = 1;
const EVENT_SCHEMA_VERSION: u32 = 1;
const SNAPSHOT_SCHEMA_VERSION: u32 = 4;
const UPSTREAM_COMMIT: &[u8] = b"6c578292e8ebbbec708b76986ba8c4bc7c509747\0";
const MAX_ENVELOPE_BYTES: usize = 64 * 1024;
const MAX_NAME_BYTES: usize = 64;
const MAX_SERVER_BYTES: usize = 512;
const MAX_SERVER_PUBLIC_KEY_BYTES: usize = 1024;
const MAX_ENCODER_ID_BYTES: usize = 128;
const PERMANENT_PASSWORD_POLICY_VERSION: u32 = 1;
const PERMANENT_PASSWORD_MIN_CHARACTERS: usize = 6;
const PERMANENT_PASSWORD_MAX_CHARACTERS: usize = 128;
const PERMANENT_PASSWORD_MAX_UTF8_BYTES: usize = 512;
const NATIVE_APPROVAL_TIMEOUT_MS: u64 = 30_000;
const MAX_REMOTE_METADATA_BYTES: usize = 256;
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
const RDN_HOST_ERR_SECRET_INVALID_UTF8: i32 = -13;
const RDN_HOST_ERR_SECRET_EMPTY: i32 = -14;
const RDN_HOST_ERR_SECRET_TOO_SHORT: i32 = -15;
const RDN_HOST_ERR_SECRET_TOO_LONG: i32 = -16;
const RDN_HOST_ERR_SECRET_FORBIDDEN_CHARACTER: i32 = -17;
const RDN_HOST_ERR_SECRET_OUTER_WHITESPACE: i32 = -18;
const RDN_HOST_ERR_CHANGE_DISABLED: i32 = -19;
const RDN_HOST_ERR_STORAGE: i32 = -20;
const RDN_HOST_ERR_APPROVAL_NOT_FOUND: i32 = -21;
const RDN_HOST_ERR_APPROVAL_FINALIZED: i32 = -22;
const RDN_HOST_ERR_APPROVAL_EXPIRED: i32 = -23;

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

/// Caller-owned secret bytes borrowed across the C ABI. Every return path
/// after a valid pointer/length pair reaches this guard and wipes the complete
/// caller buffer with libsodium before Rust releases the borrow.
struct SecretBuffer<'a> {
    bytes: &'a mut [u8],
}

impl SecretBuffer<'_> {
    unsafe fn from_raw_parts(pointer: *mut u8, length: usize) -> Self {
        Self {
            bytes: std::slice::from_raw_parts_mut(pointer, length),
        }
    }

    fn bytes(&self) -> &[u8] {
        self.bytes
    }
}

impl Drop for SecretBuffer<'_> {
    fn drop(&mut self) {
        password_security::memzero_secret(self.bytes);
    }
}

#[derive(Clone, Copy)]
struct PasswordPolicyRejection {
    code: i32,
    detail: &'static str,
}

fn validate_permanent_password(bytes: &[u8]) -> Result<&str, PasswordPolicyRejection> {
    if bytes.is_empty() {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_EMPTY,
            detail: "permanent-password-empty",
        });
    }
    if bytes.len() > PERMANENT_PASSWORD_MAX_UTF8_BYTES {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_TOO_LONG,
            detail: "permanent-password-too-long",
        });
    }
    let password = std::str::from_utf8(bytes).map_err(|_| PasswordPolicyRejection {
        code: RDN_HOST_ERR_SECRET_INVALID_UTF8,
        detail: "permanent-password-invalid-utf8",
    })?;
    let character_count = password.chars().count();
    if character_count < PERMANENT_PASSWORD_MIN_CHARACTERS {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_TOO_SHORT,
            detail: "permanent-password-too-short",
        });
    }
    if character_count > PERMANENT_PASSWORD_MAX_CHARACTERS {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_TOO_LONG,
            detail: "permanent-password-too-long",
        });
    }
    if password.chars().any(char::is_control) {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_FORBIDDEN_CHARACTER,
            detail: "permanent-password-forbidden-character",
        });
    }
    if password
        .chars()
        .next()
        .map(char::is_whitespace)
        .unwrap_or(false)
        || password
            .chars()
            .next_back()
            .map(char::is_whitespace)
            .unwrap_or(false)
    {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_OUTER_WHITESPACE,
            detail: "permanent-password-outer-whitespace",
        });
    }
    Ok(password)
}

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
    queue_telemetry: Arc<NativeMediaQueueTelemetry>,
    writer_telemetry: Arc<NativeMediaWriterTelemetry>,
    network_telemetry: Arc<NativeMediaNetworkTelemetry>,
    transport_telemetry: Arc<NativeMediaTransportTelemetry>,
    last_pts_us: Option<u64>,
    needs_parameter_sets: bool,
}

#[derive(Default)]
struct MediaBroker {
    binding: Option<MediaHostBinding>,
    capabilities: MediaCapabilities,
    routes: HashMap<u64, MediaRoute>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeApprovalRequest {
    connection_id: String,
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    requested_at_ms: u64,
    expires_at_ms: u64,
    requested_capabilities: Vec<String>,
}

impl NativeApprovalRequest {
    fn event_payload(&self) -> Value {
        json!({
            "connectionId": self.connection_id,
            "remoteId": self.remote_id,
            "remoteName": self.remote_name,
            "remotePlatform": self.remote_platform,
            "remoteMetadataTrust": "untrusted",
            "requestedAt": self.requested_at_ms,
            "expiresAt": self.expires_at_ms,
            "requestedCapabilities": self.requested_capabilities,
            "transport": "unknown",
            "authenticationMethod": "localApproval",
            "riskAlerts": [],
        })
    }
}

struct PendingNativeApproval {
    request: NativeApprovalRequest,
    deadline: Instant,
    decision_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeApprovalFinalStatus {
    Approved,
    Rejected,
    Expired,
    Cancelled,
}

impl NativeApprovalFinalStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Approved => "approved",
            Self::Rejected => "rejected",
            Self::Expired => "expired",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeApprovalStartResult {
    Accepted,
    Existing,
    Busy,
    Finalized,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeApprovalDecision {
    Approve,
    Reject,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeApprovalResolveResult {
    Approved,
    Rejected,
    Expired,
    AlreadyFinal,
    NotFound,
}

struct NativeApprovalCompletion {
    pending: PendingNativeApproval,
    status: NativeApprovalFinalStatus,
}

#[derive(Default)]
struct NativeApprovalBroker {
    pending: Option<PendingNativeApproval>,
    last_finalized: Option<(String, NativeApprovalFinalStatus)>,
}

impl NativeApprovalBroker {
    fn begin(&mut self, pending: PendingNativeApproval) -> NativeApprovalStartResult {
        if self
            .last_finalized
            .as_ref()
            .map(|(connection_id, _)| connection_id == &pending.request.connection_id)
            .unwrap_or(false)
        {
            return NativeApprovalStartResult::Finalized;
        }
        if let Some(current) = self.pending.as_ref() {
            return if current.request.connection_id == pending.request.connection_id {
                NativeApprovalStartResult::Existing
            } else {
                NativeApprovalStartResult::Busy
            };
        }
        self.pending = Some(pending);
        NativeApprovalStartResult::Accepted
    }

    fn resolve(
        &mut self,
        connection_id: &str,
        decision: NativeApprovalDecision,
        now: Instant,
    ) -> (
        NativeApprovalResolveResult,
        Option<NativeApprovalCompletion>,
    ) {
        let Some(pending) = self.pending.as_ref() else {
            let already_final = self
                .last_finalized
                .as_ref()
                .map(|(finalized_id, _)| finalized_id == connection_id)
                .unwrap_or(false);
            return (
                if already_final {
                    NativeApprovalResolveResult::AlreadyFinal
                } else {
                    NativeApprovalResolveResult::NotFound
                },
                None,
            );
        };
        if pending.request.connection_id != connection_id {
            return (NativeApprovalResolveResult::NotFound, None);
        }

        let (status, result) = if now >= pending.deadline {
            (
                NativeApprovalFinalStatus::Expired,
                NativeApprovalResolveResult::Expired,
            )
        } else {
            match decision {
                NativeApprovalDecision::Approve => (
                    NativeApprovalFinalStatus::Approved,
                    NativeApprovalResolveResult::Approved,
                ),
                NativeApprovalDecision::Reject => (
                    NativeApprovalFinalStatus::Rejected,
                    NativeApprovalResolveResult::Rejected,
                ),
            }
        };
        let Some(pending) = self.pending.take() else {
            return (NativeApprovalResolveResult::NotFound, None);
        };
        self.last_finalized = Some((pending.request.connection_id.clone(), status));
        (result, Some(NativeApprovalCompletion { pending, status }))
    }

    fn expire(&mut self, connection_id: &str, now: Instant) -> Option<NativeApprovalCompletion> {
        let should_expire = self
            .pending
            .as_ref()
            .map(|pending| {
                pending.request.connection_id == connection_id && now >= pending.deadline
            })
            .unwrap_or(false);
        if !should_expire {
            return None;
        }
        let pending = self.pending.take()?;
        self.last_finalized = Some((
            pending.request.connection_id.clone(),
            NativeApprovalFinalStatus::Expired,
        ));
        Some(NativeApprovalCompletion {
            pending,
            status: NativeApprovalFinalStatus::Expired,
        })
    }

    fn cancel(&mut self, core_connection_id: i32) -> Option<NativeApprovalCompletion> {
        let matches = self
            .pending
            .as_ref()
            .map(|pending| pending.request.core_connection_id == core_connection_id)
            .unwrap_or(false);
        if !matches {
            return None;
        }
        let pending = self.pending.take()?;
        self.last_finalized = Some((
            pending.request.connection_id.clone(),
            NativeApprovalFinalStatus::Cancelled,
        ));
        Some(NativeApprovalCompletion {
            pending,
            status: NativeApprovalFinalStatus::Cancelled,
        })
    }

    fn reset(&mut self) -> Option<PendingNativeApproval> {
        self.last_finalized = None;
        self.pending.take()
    }

    fn snapshot(
        &mut self,
        now: Instant,
    ) -> (
        Option<NativeApprovalRequest>,
        Option<NativeApprovalCompletion>,
    ) {
        let expired_connection_id = self
            .pending
            .as_ref()
            .filter(|pending| now >= pending.deadline)
            .map(|pending| pending.request.connection_id.clone());
        let completion = expired_connection_id
            .as_deref()
            .and_then(|connection_id| self.expire(connection_id, now));
        let request = self.pending.as_ref().map(|pending| pending.request.clone());
        (request, completion)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NativeSessionCapabilities {
    control_keyboard_mouse: bool,
    clipboard: bool,
    system_audio: bool,
}

impl NativeSessionCapabilities {
    pub(crate) fn new(control_keyboard_mouse: bool, clipboard: bool, system_audio: bool) -> Self {
        Self {
            control_keyboard_mouse,
            clipboard,
            system_audio,
        }
    }

    fn names(self) -> Vec<&'static str> {
        let mut names = vec!["viewDisplay"];
        if self.control_keyboard_mouse {
            names.push("controlKeyboardMouse");
        }
        if self.clipboard {
            names.push("readClipboard");
            names.push("writeClipboard");
        }
        if self.system_audio {
            names.push("hearSystemAudio");
        }
        names
    }

    fn is_subset_of(self, other: Self) -> bool {
        (!self.control_keyboard_mouse || other.control_keyboard_mouse)
            && (!self.clipboard || other.clipboard)
            && (!self.system_audio || other.system_audio)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeSessionSnapshot {
    connection_id: String,
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    started_at_ms: u64,
    initial_capabilities: NativeSessionCapabilities,
    active_capabilities: NativeSessionCapabilities,
}

impl NativeSessionSnapshot {
    fn event_payload(&self) -> Value {
        json!({
            "connectionId": self.connection_id,
            "remoteId": self.remote_id,
            "remoteName": self.remote_name,
            "remotePlatform": self.remote_platform,
            "remoteMetadataTrust": "untrusted",
            "startedAt": self.started_at_ms,
            "initialCapabilities": self.initial_capabilities.names(),
            "activeCapabilities": self.active_capabilities.names(),
        })
    }
}

struct NativeActiveSession {
    snapshot: NativeSessionSnapshot,
    command_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionStartResult {
    Accepted,
    Existing,
    Busy,
    Invalid,
}

#[derive(Default)]
struct NativeSessionBroker {
    active: Option<NativeActiveSession>,
}

impl NativeSessionBroker {
    fn begin(&mut self, session: NativeActiveSession) -> NativeSessionStartResult {
        if !session
            .snapshot
            .active_capabilities
            .is_subset_of(session.snapshot.initial_capabilities)
        {
            return NativeSessionStartResult::Invalid;
        }
        if let Some(active) = self.active.as_ref() {
            return if active.snapshot.connection_id == session.snapshot.connection_id {
                if active.snapshot == session.snapshot {
                    NativeSessionStartResult::Existing
                } else {
                    NativeSessionStartResult::Invalid
                }
            } else {
                NativeSessionStartResult::Busy
            };
        }
        self.active = Some(session);
        NativeSessionStartResult::Accepted
    }

    fn update_capabilities(
        &mut self,
        core_connection_id: i32,
        active_capabilities: NativeSessionCapabilities,
    ) -> Option<NativeSessionSnapshot> {
        let active = self.active.as_mut()?;
        if active.snapshot.core_connection_id != core_connection_id
            || active.snapshot.active_capabilities == active_capabilities
        {
            return None;
        }
        active.snapshot.active_capabilities = active_capabilities;
        Some(active.snapshot.clone())
    }

    fn end(&mut self, core_connection_id: i32) -> Option<NativeActiveSession> {
        let matches = self
            .active
            .as_ref()
            .map(|active| active.snapshot.core_connection_id == core_connection_id)
            .unwrap_or(false);
        matches.then(|| self.active.take()).flatten()
    }

    fn reset(&mut self) -> Option<NativeActiveSession> {
        self.active.take()
    }

    fn snapshot(&self) -> Option<NativeSessionSnapshot> {
        self.active.as_ref().map(|active| active.snapshot.clone())
    }
}

pub(crate) struct NativeMediaAccessUnit {
    pub(crate) codec: u32,
    pub(crate) framing: u32,
    pub(crate) pts_us: u64,
    pub(crate) keyframe: bool,
    pub(crate) has_parameter_sets: bool,
    pub(crate) data: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeMediaQueueDropReason {
    NetworkBackpressure,
    Shutdown,
}

#[derive(Default)]
struct NativeMediaQueueState {
    depth: usize,
    maximum_depth: usize,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaQueueSnapshot {
    current_depth: usize,
    maximum_depth: usize,
}

#[derive(Default)]
struct NativeMediaQueueTelemetry {
    state: Mutex<NativeMediaQueueState>,
}

impl NativeMediaQueueTelemetry {
    fn try_enqueue(
        &self,
        sender: &SyncSender<NativeMediaAccessUnit>,
        packet: NativeMediaAccessUnit,
    ) -> Result<(), (NativeMediaQueueDropReason, NativeMediaAccessUnit)> {
        // Hold the small counter lock across try_send so the receiver cannot
        // decrement before a successful enqueue has published its depth.
        let mut state = self.state.lock().unwrap();
        match sender.try_send(packet) {
            Ok(()) => {
                state.depth += 1;
                state.maximum_depth = state.maximum_depth.max(state.depth);
                Ok(())
            }
            Err(TrySendError::Full(packet)) => {
                Err((NativeMediaQueueDropReason::NetworkBackpressure, packet))
            }
            Err(TrySendError::Disconnected(packet)) => {
                Err((NativeMediaQueueDropReason::Shutdown, packet))
            }
        }
    }

    fn record_dequeued(&self) {
        let mut state = self.state.lock().unwrap();
        state.depth = state.depth.saturating_sub(1);
    }

    fn snapshot(&self) -> NativeMediaQueueSnapshot {
        let state = self.state.lock().unwrap();
        NativeMediaQueueSnapshot {
            current_depth: state.depth,
            maximum_depth: state.maximum_depth,
        }
    }
}

#[derive(Default)]
struct NativeMediaWriterState {
    cycles: u64,
    subscriber_dispatches: u64,
    dispatch_wall_total_us: u64,
    maximum_dispatch_wall_us: u64,
    confirmation_wait_total_us: u64,
    maximum_confirmation_wait_us: u64,
    completed_confirmations: u64,
    timed_out_confirmations: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaWriterSnapshot {
    cycles: u64,
    subscriber_dispatches: u64,
    dispatch_wall_total_us: u64,
    maximum_dispatch_wall_us: u64,
    confirmation_wait_total_us: u64,
    maximum_confirmation_wait_us: u64,
    completed_confirmations: u64,
    timed_out_confirmations: u64,
}

#[derive(Default)]
struct NativeMediaWriterTelemetry {
    state: Mutex<NativeMediaWriterState>,
}

impl NativeMediaWriterTelemetry {
    fn record(
        &self,
        subscriber_count: usize,
        dispatch_wall: Duration,
        confirmation_wait: Duration,
        confirmation_complete: bool,
    ) {
        if subscriber_count == 0 {
            return;
        }
        let dispatch_us = duration_microseconds(dispatch_wall);
        let confirmation_us = duration_microseconds(confirmation_wait);
        let mut state = self.state.lock().unwrap();
        state.cycles = state.cycles.saturating_add(1);
        state.subscriber_dispatches = state
            .subscriber_dispatches
            .saturating_add(subscriber_count.min(u64::MAX as usize) as u64);
        state.dispatch_wall_total_us = state.dispatch_wall_total_us.saturating_add(dispatch_us);
        state.maximum_dispatch_wall_us = state.maximum_dispatch_wall_us.max(dispatch_us);
        state.confirmation_wait_total_us = state
            .confirmation_wait_total_us
            .saturating_add(confirmation_us);
        state.maximum_confirmation_wait_us =
            state.maximum_confirmation_wait_us.max(confirmation_us);
        if confirmation_complete {
            state.completed_confirmations = state.completed_confirmations.saturating_add(1);
        } else {
            state.timed_out_confirmations = state.timed_out_confirmations.saturating_add(1);
        }
    }

    fn snapshot(&self) -> NativeMediaWriterSnapshot {
        let state = self.state.lock().unwrap();
        NativeMediaWriterSnapshot {
            cycles: state.cycles,
            subscriber_dispatches: state.subscriber_dispatches,
            dispatch_wall_total_us: state.dispatch_wall_total_us,
            maximum_dispatch_wall_us: state.maximum_dispatch_wall_us,
            confirmation_wait_total_us: state.confirmation_wait_total_us,
            maximum_confirmation_wait_us: state.maximum_confirmation_wait_us,
            completed_confirmations: state.completed_confirmations,
            timed_out_confirmations: state.timed_out_confirmations,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaNetworkSnapshot {
    subscriber_count: u64,
    qos_subscriber_count: u64,
    delay_sampled_subscribers: u64,
    rtt_sampled_subscribers: u64,
    response_delayed_subscribers: u64,
    worst_network_delay_ms: Option<u32>,
    worst_rtt_ms: Option<u32>,
}

#[derive(Default)]
struct NativeMediaNetworkTelemetry {
    latest: Mutex<NativeMediaNetworkSnapshot>,
}

impl NativeMediaNetworkTelemetry {
    fn record(
        &self,
        subscriber_count: usize,
        qos_subscriber_count: usize,
        delay_sampled_subscribers: usize,
        rtt_sampled_subscribers: usize,
        response_delayed_subscribers: usize,
        worst_network_delay_ms: Option<u32>,
        worst_rtt_ms: Option<u32>,
    ) -> bool {
        if qos_subscriber_count > subscriber_count
            || delay_sampled_subscribers > qos_subscriber_count
            || rtt_sampled_subscribers > delay_sampled_subscribers
            || response_delayed_subscribers > qos_subscriber_count
            || (delay_sampled_subscribers == 0) != worst_network_delay_ms.is_none()
            || (rtt_sampled_subscribers == 0) != worst_rtt_ms.is_none()
        {
            return false;
        }
        *self.latest.lock().unwrap() = NativeMediaNetworkSnapshot {
            subscriber_count: subscriber_count.min(u64::MAX as usize) as u64,
            qos_subscriber_count: qos_subscriber_count.min(u64::MAX as usize) as u64,
            delay_sampled_subscribers: delay_sampled_subscribers.min(u64::MAX as usize) as u64,
            rtt_sampled_subscribers: rtt_sampled_subscribers.min(u64::MAX as usize) as u64,
            response_delayed_subscribers: response_delayed_subscribers.min(u64::MAX as usize)
                as u64,
            worst_network_delay_ms,
            worst_rtt_ms,
        };
        true
    }

    fn snapshot(&self) -> NativeMediaNetworkSnapshot {
        *self.latest.lock().unwrap()
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaTransportSnapshot {
    subscriber_count: u64,
    direct_subscribers: u64,
    relay_subscribers: u64,
    unknown_subscribers: u64,
}

#[derive(Default)]
struct NativeMediaTransportTelemetry {
    latest: Mutex<NativeMediaTransportSnapshot>,
}

impl NativeMediaTransportTelemetry {
    fn record(
        &self,
        subscriber_count: usize,
        direct_subscribers: usize,
        relay_subscribers: usize,
        unknown_subscribers: usize,
    ) -> bool {
        let Some(classified_subscribers) = direct_subscribers.checked_add(relay_subscribers) else {
            return false;
        };
        let Some(all_subscribers) = classified_subscribers.checked_add(unknown_subscribers) else {
            return false;
        };
        if all_subscribers != subscriber_count {
            return false;
        }
        *self.latest.lock().unwrap() = NativeMediaTransportSnapshot {
            subscriber_count: subscriber_count.min(u64::MAX as usize) as u64,
            direct_subscribers: direct_subscribers.min(u64::MAX as usize) as u64,
            relay_subscribers: relay_subscribers.min(u64::MAX as usize) as u64,
            unknown_subscribers: unknown_subscribers.min(u64::MAX as usize) as u64,
        };
        true
    }

    fn snapshot(&self) -> NativeMediaTransportSnapshot {
        *self.latest.lock().unwrap()
    }
}

fn duration_microseconds(duration: Duration) -> u64 {
    duration.as_micros().min(u64::MAX as u128) as u64
}

fn try_enqueue_native_media(
    sender: &SyncSender<NativeMediaAccessUnit>,
    telemetry: &NativeMediaQueueTelemetry,
    packet: NativeMediaAccessUnit,
) -> Result<(), (NativeMediaQueueDropReason, NativeMediaAccessUnit)> {
    telemetry.try_enqueue(sender, packet)
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
    queue_telemetry: Arc<NativeMediaQueueTelemetry>,
    writer_telemetry: Arc<NativeMediaWriterTelemetry>,
    network_telemetry: Arc<NativeMediaNetworkTelemetry>,
    transport_telemetry: Arc<NativeMediaTransportTelemetry>,
}

static NEXT_CONNECTION_EPOCH: AtomicU64 = AtomicU64::new(1);
static NEXT_CODEC_EPOCH: AtomicU64 = AtomicU64::new(1);

lazy_static::lazy_static! {
    static ref MEDIA_BROKER: Mutex<MediaBroker> = Mutex::new(MediaBroker::default());
    static ref APPROVAL_BROKER: Mutex<NativeApprovalBroker> =
        Mutex::new(NativeApprovalBroker::default());
    static ref SESSION_BROKER: Mutex<NativeSessionBroker> =
        Mutex::new(NativeSessionBroker::default());
}

fn emit_bound_event(binding: &MediaHostBinding, event_type: &str, payload: Value) {
    let Some(callback) = binding.callback else {
        return;
    };
    let envelope = json!({
        "schemaVersion": EVENT_SCHEMA_VERSION,
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

fn bounded_remote_metadata(value: String) -> String {
    let mut result = String::new();
    for character in value.chars().filter(|character| !character.is_control()) {
        if result.len() + character.len_utf8() > MAX_REMOTE_METADATA_BYTES {
            break;
        }
        result.push(character);
    }
    result
}

fn emit_native_approval_completion(completion: &NativeApprovalCompletion) {
    let signal = match completion.status {
        NativeApprovalFinalStatus::Approved => Some(crate::ipc::Data::Authorize),
        NativeApprovalFinalStatus::Rejected | NativeApprovalFinalStatus::Expired => {
            Some(crate::ipc::Data::Close)
        }
        NativeApprovalFinalStatus::Cancelled => None,
    };
    if let Some(signal) = signal {
        let _ = completion.pending.decision_sender.send(signal);
    }
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "incomingConnectionResolved",
            json!({
                "connectionId": completion.pending.request.connection_id,
                "status": completion.status.as_str(),
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

fn expire_native_approval(connection_id: &str) {
    let completion = APPROVAL_BROKER
        .lock()
        .unwrap()
        .expire(connection_id, Instant::now());
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
}

pub(crate) fn native_host_begin_approval(
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    requested_capabilities: Vec<String>,
    decision_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
) -> NativeApprovalStartResult {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    let Some(binding) = binding else {
        return NativeApprovalStartResult::Unavailable;
    };
    let requested_at_ms = now_unix_millis();
    let connection_id = format!("{}:{core_connection_id}", binding.instance_id);
    let request = NativeApprovalRequest {
        connection_id: connection_id.clone(),
        core_connection_id,
        remote_id: bounded_remote_metadata(remote_id),
        remote_name: bounded_remote_metadata(remote_name),
        remote_platform: bounded_remote_metadata(remote_platform),
        requested_at_ms,
        expires_at_ms: requested_at_ms.saturating_add(NATIVE_APPROVAL_TIMEOUT_MS),
        requested_capabilities,
    };
    let result = APPROVAL_BROKER
        .lock()
        .unwrap()
        .begin(PendingNativeApproval {
            request: request.clone(),
            deadline: Instant::now() + Duration::from_millis(NATIVE_APPROVAL_TIMEOUT_MS),
            decision_sender: decision_sender.clone(),
        });
    match result {
        NativeApprovalStartResult::Accepted => {
            emit_bound_event(
                &binding,
                "incomingConnectionRequest",
                request.event_payload(),
            );
            emit_bound_event(&binding, "snapshotChanged", json!({}));
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(NATIVE_APPROVAL_TIMEOUT_MS)).await;
                expire_native_approval(&connection_id);
            });
        }
        NativeApprovalStartResult::Busy
        | NativeApprovalStartResult::Finalized
        | NativeApprovalStartResult::Unavailable => {
            let _ = decision_sender.send(crate::ipc::Data::Close);
        }
        NativeApprovalStartResult::Existing => {}
    }
    result
}

pub(crate) fn native_host_resolve_approval(
    connection_id: &str,
    decision: NativeApprovalDecision,
) -> NativeApprovalResolveResult {
    let (result, completion) =
        APPROVAL_BROKER
            .lock()
            .unwrap()
            .resolve(connection_id, decision, Instant::now());
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
    result
}

pub(crate) fn native_host_cancel_approval(core_connection_id: i32) {
    let completion = APPROVAL_BROKER.lock().unwrap().cancel(core_connection_id);
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
}

pub(crate) fn native_host_begin_session(
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    initial_capabilities: NativeSessionCapabilities,
    active_capabilities: NativeSessionCapabilities,
    command_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
) -> bool {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    let Some(binding) = binding else {
        return false;
    };
    let snapshot = NativeSessionSnapshot {
        connection_id: format!("{}:{core_connection_id}", binding.instance_id),
        core_connection_id,
        remote_id: bounded_remote_metadata(remote_id),
        remote_name: bounded_remote_metadata(remote_name),
        remote_platform: bounded_remote_metadata(remote_platform),
        started_at_ms: now_unix_millis(),
        initial_capabilities,
        active_capabilities,
    };
    let result = SESSION_BROKER.lock().unwrap().begin(NativeActiveSession {
        snapshot: snapshot.clone(),
        command_sender,
    });
    match result {
        NativeSessionStartResult::Accepted => {
            emit_bound_event(&binding, "sessionStarted", snapshot.event_payload());
            emit_bound_event(&binding, "snapshotChanged", json!({}));
            true
        }
        NativeSessionStartResult::Existing => true,
        NativeSessionStartResult::Busy | NativeSessionStartResult::Invalid => false,
    }
}

pub(crate) fn native_host_update_session_capabilities(
    core_connection_id: i32,
    active_capabilities: NativeSessionCapabilities,
) {
    let snapshot = SESSION_BROKER
        .lock()
        .unwrap()
        .update_capabilities(core_connection_id, active_capabilities);
    let Some(snapshot) = snapshot else { return };
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionCapabilitiesChanged",
            json!({
                "connectionId": snapshot.connection_id,
                "activeCapabilities": snapshot.active_capabilities.names(),
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

pub(crate) fn native_host_end_session(core_connection_id: i32) {
    let ended = SESSION_BROKER.lock().unwrap().end(core_connection_id);
    let Some(ended) = ended else { return };
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionEnded",
            json!({
                "connectionId": ended.snapshot.connection_id,
                "reason": "connectionClosed",
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

fn native_host_pending_approval_snapshot(host_instance_id: &str) -> Option<Value> {
    let (request, completion) = APPROVAL_BROKER.lock().unwrap().snapshot(Instant::now());
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
    let request = request?;
    let expected_prefix = format!("{host_instance_id}:");
    request
        .connection_id
        .starts_with(&expected_prefix)
        .then(|| request.event_payload())
}

fn native_host_active_session_snapshot(host_instance_id: &str) -> Option<Value> {
    let snapshot = SESSION_BROKER.lock().unwrap().snapshot()?;
    let expected_prefix = format!("{host_instance_id}:");
    snapshot
        .connection_id
        .starts_with(&expected_prefix)
        .then(|| snapshot.event_payload())
}

fn reset_native_approval_broker() {
    let pending = APPROVAL_BROKER.lock().unwrap().reset();
    if let Some(pending) = pending {
        let _ = pending.decision_sender.send(crate::ipc::Data::Close);
    }
}

fn reset_native_session_broker(reason: &str) {
    let active = SESSION_BROKER.lock().unwrap().reset();
    let Some(active) = active else { return };
    let _ = active.command_sender.send(crate::ipc::Data::Close);
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionEnded",
            json!({
                "connectionId": active.snapshot.connection_id,
                "reason": reason,
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

fn bind_media_host(host: &RdnHost) {
    reset_native_approval_broker();
    reset_native_session_broker("hostRebound");
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

/// Stable for the full native Host instance lifetime, including the interval
/// where stop has unbound media but server connections are still draining.
pub(crate) fn native_host_instance_is_live() -> bool {
    HOST_INSTANCE_LIVE.load(Ordering::Acquire)
}

fn unbind_media_host() {
    reset_native_approval_broker();
    reset_native_session_broker("hostStopped");
    let (binding, routes) = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let binding = broker.binding.take();
        let routes = broker
            .routes
            .drain()
            .map(|(display, route)| {
                (
                    display,
                    route.connection_epoch,
                    route.codec_epoch,
                    route.display_revision,
                    route.queue_telemetry.snapshot(),
                    route.writer_telemetry.snapshot(),
                    route.network_telemetry.snapshot(),
                    route.transport_telemetry.snapshot(),
                )
            })
            .collect::<Vec<_>>();
        broker.capabilities = MediaCapabilities::default();
        (binding, routes)
    };
    scrap::codec::set_native_encoding_capabilities(false, false);
    if let Some(binding) = binding {
        for (
            display_id,
            connection_epoch,
            codec_epoch,
            display_revision,
            queue,
            writer,
            network,
            transport,
        ) in routes
        {
            emit_bound_event(
                &binding,
                "mediaQueueDiagnostic",
                native_media_queue_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    queue,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaWriterDiagnostic",
                native_media_writer_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    writer,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaNetworkDiagnostic",
                native_media_network_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    network,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaTransportDiagnostic",
                native_media_transport_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    transport,
                ),
            );
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
    let queue_telemetry = Arc::new(NativeMediaQueueTelemetry::default());
    let writer_telemetry = Arc::new(NativeMediaWriterTelemetry::default());
    let network_telemetry = Arc::new(NativeMediaNetworkTelemetry::default());
    let transport_telemetry = Arc::new(NativeMediaTransportTelemetry::default());
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
                queue_telemetry: queue_telemetry.clone(),
                writer_telemetry: writer_telemetry.clone(),
                network_telemetry: network_telemetry.clone(),
                transport_telemetry: transport_telemetry.clone(),
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
        queue_telemetry,
        writer_telemetry,
        network_telemetry,
        transport_telemetry,
    })
}

pub(crate) fn native_media_record_dequeued(route: &NativeMediaRoute) {
    route.queue_telemetry.record_dequeued();
}

pub(crate) fn native_media_report_queue_depth(route: &NativeMediaRoute) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaQueueDiagnostic",
            native_media_queue_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.queue_telemetry.snapshot(),
            ),
        );
    }
}

pub(crate) fn native_media_record_writer_cycle(
    route: &NativeMediaRoute,
    subscriber_count: usize,
    dispatch_wall: Duration,
    confirmation_wait: Duration,
    confirmation_complete: bool,
) {
    route.writer_telemetry.record(
        subscriber_count,
        dispatch_wall,
        confirmation_wait,
        confirmation_complete,
    );
}

pub(crate) fn native_media_report_writer_timing(route: &NativeMediaRoute) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaWriterDiagnostic",
            native_media_writer_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.writer_telemetry.snapshot(),
            ),
        );
    }
}

pub(crate) fn native_media_report_network(
    route: &NativeMediaRoute,
    subscriber_count: usize,
    qos_subscriber_count: usize,
    delay_sampled_subscribers: usize,
    rtt_sampled_subscribers: usize,
    response_delayed_subscribers: usize,
    worst_network_delay_ms: Option<u32>,
    worst_rtt_ms: Option<u32>,
) {
    if !route.network_telemetry.record(
        subscriber_count,
        qos_subscriber_count,
        delay_sampled_subscribers,
        rtt_sampled_subscribers,
        response_delayed_subscribers,
        worst_network_delay_ms,
        worst_rtt_ms,
    ) {
        return;
    }
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaNetworkDiagnostic",
            native_media_network_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.network_telemetry.snapshot(),
            ),
        );
    }
}

pub(crate) fn native_media_report_transport(
    route: &NativeMediaRoute,
    subscriber_count: usize,
    direct_subscribers: usize,
    relay_subscribers: usize,
    unknown_subscribers: usize,
) {
    if !route.transport_telemetry.record(
        subscriber_count,
        direct_subscribers,
        relay_subscribers,
        unknown_subscribers,
    ) {
        return;
    }
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaTransportDiagnostic",
            native_media_transport_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.transport_telemetry.snapshot(),
            ),
        );
    }
}

fn native_media_queue_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    queue: NativeMediaQueueSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "currentDepth": queue.current_depth,
        "maximumDepth": queue.maximum_depth,
        "capacity": MEDIA_QUEUE_CAPACITY,
    })
}

fn native_media_writer_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    writer: NativeMediaWriterSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "cycles": writer.cycles,
        "subscriberDispatches": writer.subscriber_dispatches,
        "dispatchWallTotalUs": writer.dispatch_wall_total_us,
        "maximumDispatchWallUs": writer.maximum_dispatch_wall_us,
        "confirmationWaitTotalUs": writer.confirmation_wait_total_us,
        "maximumConfirmationWaitUs": writer.maximum_confirmation_wait_us,
        "completedConfirmations": writer.completed_confirmations,
        "timedOutConfirmations": writer.timed_out_confirmations,
    })
}

fn native_media_network_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    network: NativeMediaNetworkSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "subscriberCount": network.subscriber_count,
        "qosSubscriberCount": network.qos_subscriber_count,
        "delaySampledSubscribers": network.delay_sampled_subscribers,
        "rttSampledSubscribers": network.rtt_sampled_subscribers,
        "responseDelayedSubscribers": network.response_delayed_subscribers,
        "worstNetworkDelayMs": network.worst_network_delay_ms,
        "worstRttMs": network.worst_rtt_ms,
    })
}

fn native_media_transport_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    transport: NativeMediaTransportSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "subscriberCount": transport.subscriber_count,
        "directSubscribers": transport.direct_subscribers,
        "relaySubscribers": transport.relay_subscribers,
        "unknownSubscribers": transport.unknown_subscribers,
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
            "mediaQueueDiagnostic",
            native_media_queue_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.queue_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaWriterDiagnostic",
            native_media_writer_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.writer_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaNetworkDiagnostic",
            native_media_network_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.network_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaTransportDiagnostic",
            native_media_transport_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.transport_telemetry.snapshot(),
            ),
        );
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
        map.insert(
            "pendingApproval".into(),
            native_host_pending_approval_snapshot(&self.instance_id).unwrap_or(Value::Null),
        );
        map.insert(
            "activeSession".into(),
            native_host_active_session_snapshot(&self.instance_id).unwrap_or(Value::Null),
        );
        map.insert("temporaryPasswordPresentation".into(), presentation);
        map.insert(
            "passwordPolicy".into(),
            json!({
                "localPasswordSet": config::Config::has_local_permanent_password(),
                "effectivePasswordSet": config::Config::has_permanent_password(),
                "usingPresetPassword": config::Config::is_using_preset_password(),
                "changeAllowed": !config::Config::is_disable_change_permanent_password(),
                "strengthPolicy": {
                    "version": PERMANENT_PASSWORD_POLICY_VERSION,
                    "minimumCharacters": PERMANENT_PASSWORD_MIN_CHARACTERS,
                    "maximumCharacters": PERMANENT_PASSWORD_MAX_CHARACTERS,
                    "maximumUtf8Bytes": PERMANENT_PASSWORD_MAX_UTF8_BYTES,
                    "rejectsControlCharacters": true,
                    "rejectsOuterWhitespace": true,
                },
            }),
        );
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
    // FarPane Host owns an active authenticated screen route as a bounded
    // user-idle sleep assertion. The connection lifecycle releases it when
    // the last remote screen session ends; native mode never forces the
    // physical display to stay lit.
    config::Config::set_option(
        config::keys::OPTION_KEEP_AWAKE_DURING_INCOMING_SESSIONS.to_owned(),
        "Y".to_owned(),
    );
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

fn approval_connection_id(envelope: &Value) -> Result<&str, i32> {
    let Some(object) = envelope.as_object() else {
        return Err(RDN_HOST_ERR_VALIDATION);
    };
    if object.len() != 3
        || !object.contains_key("commandId")
        || !object.contains_key("name")
        || !object.contains_key("connectionId")
    {
        return Err(RDN_HOST_ERR_VALIDATION);
    }
    match object.get("connectionId").and_then(Value::as_str) {
        Some(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            Ok(value)
        }
        _ => Err(RDN_HOST_ERR_VALIDATION),
    }
}

fn handle_approval_command(
    host: &mut RdnHost,
    command_id: &str,
    decision: NativeApprovalDecision,
    envelope: &Value,
) -> i32 {
    let connection_id = match approval_connection_id(envelope) {
        Ok(value) => value,
        Err(code) => {
            host.emit_command_result(command_id, "rejected", "approval-command-invalid");
            return code;
        }
    };
    let expected_prefix = format!("{}:", host.instance_id);
    if !connection_id.starts_with(&expected_prefix) {
        host.emit_command_result(command_id, "rejected", "approval-not-found");
        return RDN_HOST_ERR_APPROVAL_NOT_FOUND;
    }
    match native_host_resolve_approval(connection_id, decision) {
        NativeApprovalResolveResult::Approved => {
            host.emit_command_result(command_id, "ok", "approval-approved");
            RDN_HOST_OK
        }
        NativeApprovalResolveResult::Rejected => {
            host.emit_command_result(command_id, "ok", "approval-rejected");
            RDN_HOST_OK
        }
        NativeApprovalResolveResult::Expired => {
            host.emit_command_result(command_id, "rejected", "approval-expired");
            RDN_HOST_ERR_APPROVAL_EXPIRED
        }
        NativeApprovalResolveResult::AlreadyFinal => {
            host.emit_command_result(command_id, "rejected", "approval-already-finalized");
            RDN_HOST_ERR_APPROVAL_FINALIZED
        }
        NativeApprovalResolveResult::NotFound => {
            host.emit_command_result(command_id, "rejected", "approval-not-found");
            RDN_HOST_ERR_APPROVAL_NOT_FOUND
        }
    }
}

fn handle_command(host: &mut RdnHost, command_id: &str, name: &str, envelope: &Value) -> i32 {
    match name {
        "enableHost" => {
            // Host already runs in-process for the H1a spike; accept as no-op.
            host.emit_command_result(command_id, "ok", "host-enabled");
            RDN_HOST_OK
        }
        "disableHost" => {
            host.emit_command_result(command_id, "ok", "host-disabled");
            RDN_HOST_OK
        }
        "regenerateTemporaryPassword" => {
            password_security::update_temporary_password();
            host.emit_command_result(command_id, "ok", "temporary-password-regenerated");
            host.emit_snapshot_changed();
            RDN_HOST_OK
        }
        "revealTemporaryPassword" => {
            host.reveal_temporary_password = true;
            host.emit_command_result(command_id, "ok", "temporary-password-revealed");
            RDN_HOST_OK
        }
        "clearPermanentPassword" => {
            if config::Config::is_disable_change_permanent_password() {
                host.emit_command_result(
                    command_id,
                    "rejected",
                    "permanent-password-change-disabled",
                );
                RDN_HOST_ERR_CHANGE_DISABLED
            } else if config::Config::set_permanent_password("") {
                let detail = if config::Config::has_permanent_password() {
                    "permanent-password-local-cleared-preset-still-effective"
                } else {
                    "permanent-password-local-cleared"
                };
                host.emit_command_result(command_id, "ok", detail);
                host.emit_snapshot_changed();
                RDN_HOST_OK
            } else {
                host.emit_command_result(command_id, "error", "permanent-password-storage-failed");
                RDN_HOST_ERR_STORAGE
            }
        }
        "approveConnection" => {
            handle_approval_command(host, command_id, NativeApprovalDecision::Approve, envelope)
        }
        "rejectConnection" => {
            handle_approval_command(host, command_id, NativeApprovalDecision::Reject, envelope)
        }
        _ => {
            host.emit_command_result(command_id, "unknownCommand", name);
            RDN_HOST_OK
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
        Some(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            value.to_owned()
        }
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    handle_command(host, &command_id, &name, &envelope)
}

/// Dedicated permanent-password ingress (§9.3). Password bytes never enter
/// JSON, logging, command-line arguments or persistent Swift storage. Rust
/// borrows the caller-owned mutable buffer and SecretBuffer wipes it on every
/// path after pointer validation; the Swift wrapper performs a second wipe.
#[no_mangle]
pub unsafe extern "C" fn rdn_host_set_permanent_password(
    host: *mut RdnHost,
    command_id: *const c_char,
    password_utf8: *mut u8,
    password_length: usize,
) -> i32 {
    if password_utf8.is_null() && password_length != 0 {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    let secret = if password_utf8.is_null() {
        None
    } else {
        Some(SecretBuffer::from_raw_parts(password_utf8, password_length))
    };
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    let command_id = match required_string(command_id) {
        Ok(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            value
        }
        Ok(_) => return RDN_HOST_ERR_VALIDATION,
        Err(code) => return code,
    };
    let bytes = secret.as_ref().map(SecretBuffer::bytes).unwrap_or_default();
    let password = match validate_permanent_password(bytes) {
        Ok(password) => password,
        Err(rejection) => {
            host.emit_command_result(&command_id, "rejected", rejection.detail);
            return rejection.code;
        }
    };
    if config::Config::is_disable_change_permanent_password() {
        host.emit_command_result(
            &command_id,
            "rejected",
            "permanent-password-change-disabled",
        );
        return RDN_HOST_ERR_CHANGE_DISABLED;
    }
    if !config::Config::set_permanent_password(password) {
        host.emit_command_result(&command_id, "error", "permanent-password-storage-failed");
        return RDN_HOST_ERR_STORAGE;
    }
    host.emit_command_result(&command_id, "ok", "permanent-password-set");
    host.emit_snapshot_changed();
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
    match try_enqueue_native_media(&route.sender, &route.queue_telemetry, packet) {
        Ok(()) => {
            route.last_pts_us = Some(access_unit.pts_us);
            route.needs_parameter_sets = false;
            RDN_HOST_OK
        }
        Err((NativeMediaQueueDropReason::NetworkBackpressure, _)) => RDN_HOST_ERR_BACKPRESSURE,
        Err((NativeMediaQueueDropReason::Shutdown, _)) => RDN_HOST_ERR_BAD_STATE,
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
    use std::ffi::CString;

    static MEDIA_BROKER_TEST_LOCK: Mutex<()> = Mutex::new(());
    static PASSWORD_COMMAND_TEST_LOCK: Mutex<()> = Mutex::new(());

    struct BuiltinSettingGuard {
        key: &'static str,
        previous: Option<String>,
    }

    impl BuiltinSettingGuard {
        fn set(key: &'static str, value: &str) -> Self {
            let previous = config::BUILTIN_SETTINGS
                .write()
                .unwrap()
                .insert(key.to_owned(), value.to_owned());
            Self { key, previous }
        }
    }

    impl Drop for BuiltinSettingGuard {
        fn drop(&mut self) {
            let mut settings = config::BUILTIN_SETTINGS.write().unwrap();
            if let Some(previous) = &self.previous {
                settings.insert(self.key.to_owned(), previous.clone());
            } else {
                settings.remove(self.key);
            }
        }
    }

    unsafe extern "C" fn collect_test_event(
        context: *mut c_void,
        json: *const c_char,
        length: usize,
    ) {
        if context.is_null() || json.is_null() || length == 0 {
            return;
        }
        let sink = &*(context as *const Mutex<Vec<Value>>);
        let bytes = std::slice::from_raw_parts(json as *const u8, length);
        if let Ok(event) = serde_json::from_slice(bytes) {
            sink.lock().unwrap().push(event);
        }
    }

    struct BoundMediaTestGuard;

    impl Drop for BoundMediaTestGuard {
        fn drop(&mut self) {
            unbind_media_host();
        }
    }

    fn ready_test_host(instance_id: &str) -> RdnHost {
        RdnHost {
            instance_id: instance_id.to_owned(),
            state: RdnHostState::Ready,
            local_id: "test-local-id".to_owned(),
            registration_status: "ready",
            reveal_temporary_password: false,
            last_error: None,
            event_id: Arc::new(AtomicU64::new(0)),
            callbacks: RdnHostCallbacks {
                abi_version: HOST_ABI_VERSION,
                on_event: None,
                context: std::ptr::null_mut(),
            },
            rendezvous_server: String::new(),
            relay_server: String::new(),
            server_public_key: String::new(),
            runtime: None,
        }
    }

    #[test]
    fn permanent_password_change_disabled_wipes_secret_and_propagates_clear_error() {
        let _lock = PASSWORD_COMMAND_TEST_LOCK.lock().unwrap();
        let _setting =
            BuiltinSettingGuard::set(config::keys::OPTION_DISABLE_CHANGE_PERMANENT_PASSWORD, "Y");
        let events = Mutex::new(Vec::new());
        let mut host = ready_test_host("password-disabled-host");
        host.callbacks = RdnHostCallbacks {
            abi_version: HOST_ABI_VERSION,
            on_event: Some(collect_test_event),
            context: &events as *const Mutex<Vec<Value>> as *mut c_void,
        };

        let command_id = CString::new("password-disabled").unwrap();
        let mut secret = b"valid-password".to_vec();
        let result = unsafe {
            rdn_host_set_permanent_password(
                &mut host,
                command_id.as_ptr(),
                secret.as_mut_ptr(),
                secret.len(),
            )
        };
        assert_eq!(result, RDN_HOST_ERR_CHANGE_DISABLED);
        assert!(secret.iter().all(|byte| *byte == 0));

        assert_eq!(
            handle_command(
                &mut host,
                "clear-disabled",
                "clearPermanentPassword",
                &json!({
                    "commandId": "clear-disabled",
                    "name": "clearPermanentPassword",
                }),
            ),
            RDN_HOST_ERR_CHANGE_DISABLED
        );
        let encoded = serde_json::to_string(&*events.lock().unwrap()).unwrap();
        assert!(encoded.contains("permanent-password-change-disabled"));
        assert!(!encoded.contains("valid-password"));
    }

    fn pending_approval_fixture(
        connection_id: &str,
        core_connection_id: i32,
        deadline: Instant,
    ) -> (
        PendingNativeApproval,
        tokio::sync::mpsc::UnboundedReceiver<crate::ipc::Data>,
    ) {
        let (decision_sender, decision_receiver) = tokio::sync::mpsc::unbounded_channel();
        (
            PendingNativeApproval {
                request: NativeApprovalRequest {
                    connection_id: connection_id.to_owned(),
                    core_connection_id,
                    remote_id: "remote-id".to_owned(),
                    remote_name: "Remote Mac".to_owned(),
                    remote_platform: "macOS".to_owned(),
                    requested_at_ms: 1_000,
                    expires_at_ms: 31_000,
                    requested_capabilities: vec![
                        "viewDisplay".to_owned(),
                        "controlKeyboardMouse".to_owned(),
                    ],
                },
                deadline,
                decision_sender,
            },
            decision_receiver,
        )
    }

    #[test]
    fn native_approval_broker_is_single_final_and_expiry_safe() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let base = Instant::now();
        let deadline = base + Duration::from_secs(30);
        let mut broker = NativeApprovalBroker::default();

        let (first, mut first_receiver) = pending_approval_fixture("host:1", 1, deadline);
        assert_eq!(broker.begin(first), NativeApprovalStartResult::Accepted);
        let (duplicate, _duplicate_receiver) = pending_approval_fixture("host:1", 1, deadline);
        assert_eq!(broker.begin(duplicate), NativeApprovalStartResult::Existing);
        let (busy, _busy_receiver) = pending_approval_fixture("host:2", 2, deadline);
        assert_eq!(broker.begin(busy), NativeApprovalStartResult::Busy);

        let (result, completion) = broker.resolve(
            "host:1",
            NativeApprovalDecision::Approve,
            base + Duration::from_secs(29),
        );
        assert_eq!(result, NativeApprovalResolveResult::Approved);
        let completion = completion.unwrap();
        assert_eq!(completion.status, NativeApprovalFinalStatus::Approved);
        emit_native_approval_completion(&completion);
        assert!(matches!(
            first_receiver.try_recv(),
            Ok(crate::ipc::Data::Authorize)
        ));
        let (result, completion) = broker.resolve(
            "host:1",
            NativeApprovalDecision::Reject,
            base + Duration::from_secs(29),
        );
        assert_eq!(result, NativeApprovalResolveResult::AlreadyFinal);
        assert!(completion.is_none());

        let second_deadline = base + Duration::from_secs(60);
        let (second, mut second_receiver) = pending_approval_fixture("host:2", 2, second_deadline);
        assert_eq!(broker.begin(second), NativeApprovalStartResult::Accepted);
        assert!(broker
            .expire("host:2", second_deadline - Duration::from_millis(1))
            .is_none());
        let completion = broker.expire("host:2", second_deadline).unwrap();
        assert_eq!(completion.status, NativeApprovalFinalStatus::Expired);
        emit_native_approval_completion(&completion);
        assert!(matches!(
            second_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));
        let (result, completion) =
            broker.resolve("host:2", NativeApprovalDecision::Approve, second_deadline);
        assert_eq!(result, NativeApprovalResolveResult::AlreadyFinal);
        assert!(completion.is_none());

        let (third, mut third_receiver) =
            pending_approval_fixture("host:3", 3, base + Duration::from_secs(90));
        assert_eq!(broker.begin(third), NativeApprovalStartResult::Accepted);
        let cancelled = broker.cancel(3).unwrap();
        assert_eq!(cancelled.status, NativeApprovalFinalStatus::Cancelled);
        assert!(third_receiver.try_recv().is_err());
        let (finalized, _finalized_receiver) =
            pending_approval_fixture("host:3", 3, base + Duration::from_secs(90));
        assert_eq!(
            broker.begin(finalized),
            NativeApprovalStartResult::Finalized
        );
    }

    fn active_session_fixture(
        connection_id: &str,
        core_connection_id: i32,
        initial_capabilities: NativeSessionCapabilities,
        active_capabilities: NativeSessionCapabilities,
    ) -> NativeActiveSession {
        let (command_sender, _command_receiver) = tokio::sync::mpsc::unbounded_channel();
        NativeActiveSession {
            snapshot: NativeSessionSnapshot {
                connection_id: connection_id.to_owned(),
                core_connection_id,
                remote_id: "remote-id".to_owned(),
                remote_name: "Remote Mac".to_owned(),
                remote_platform: "macOS".to_owned(),
                started_at_ms: 1_000,
                initial_capabilities,
                active_capabilities,
            },
            command_sender,
        }
    }

    #[test]
    fn native_active_session_broker_is_single_and_capability_snapshot_safe() {
        let initial = NativeSessionCapabilities::new(true, true, true);
        let active = NativeSessionCapabilities::new(true, false, true);
        let mut broker = NativeSessionBroker::default();
        assert_eq!(
            broker.begin(active_session_fixture("host:1", 1, initial, active)),
            NativeSessionStartResult::Accepted
        );
        assert_eq!(
            broker.begin(active_session_fixture("host:1", 1, initial, active)),
            NativeSessionStartResult::Existing
        );
        assert_eq!(
            broker.begin(active_session_fixture("host:2", 2, initial, active)),
            NativeSessionStartResult::Busy
        );

        let snapshot = broker.snapshot().unwrap();
        assert_eq!(snapshot.connection_id, "host:1");
        assert_eq!(
            snapshot.initial_capabilities.names(),
            vec![
                "viewDisplay",
                "controlKeyboardMouse",
                "readClipboard",
                "writeClipboard",
                "hearSystemAudio",
            ]
        );
        assert_eq!(
            snapshot.active_capabilities.names(),
            vec!["viewDisplay", "controlKeyboardMouse", "hearSystemAudio"]
        );
        assert_eq!(snapshot.event_payload()["remoteMetadataTrust"], "untrusted");

        let revoked = NativeSessionCapabilities::new(false, false, true);
        assert!(broker.update_capabilities(9, revoked).is_none());
        assert_eq!(
            broker
                .update_capabilities(1, revoked)
                .unwrap()
                .active_capabilities,
            revoked
        );
        assert!(broker.update_capabilities(1, revoked).is_none());
        assert!(broker.end(9).is_none());
        assert_eq!(broker.end(1).unwrap().snapshot.connection_id, "host:1");
        assert!(broker.snapshot().is_none());

        let no_keyboard = NativeSessionCapabilities::new(false, true, true);
        assert_eq!(
            broker.begin(active_session_fixture(
                "host:3",
                3,
                no_keyboard,
                NativeSessionCapabilities::new(true, true, true),
            )),
            NativeSessionStartResult::Invalid
        );
    }

    #[test]
    fn native_active_session_lifecycle_emits_sanitized_events_and_closes_on_reset() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let events = Mutex::new(Vec::new());
        let mut host = ready_test_host("session-host");
        host.callbacks = RdnHostCallbacks {
            abi_version: HOST_ABI_VERSION,
            on_event: Some(collect_test_event),
            context: &events as *const Mutex<Vec<Value>> as *mut c_void,
        };
        bind_media_host(&host);
        let _guard = BoundMediaTestGuard;

        let initial = NativeSessionCapabilities::new(true, true, true);
        let active = NativeSessionCapabilities::new(true, true, false);
        let (first_sender, mut first_receiver) = tokio::sync::mpsc::unbounded_channel();
        assert!(native_host_begin_session(
            7,
            "remote-id".to_owned(),
            "Remote\nMac".to_owned(),
            "macOS".to_owned(),
            initial,
            active,
            first_sender,
        ));
        let active_snapshot = host.snapshot_json();
        assert_eq!(active_snapshot["schemaVersion"], 4);
        assert_eq!(
            active_snapshot["activeSession"]["connectionId"],
            "session-host:7"
        );
        assert_eq!(
            active_snapshot["activeSession"]["remoteMetadataTrust"],
            "untrusted"
        );
        assert_eq!(
            active_snapshot["activeSession"]["activeCapabilities"],
            json!([
                "viewDisplay",
                "controlKeyboardMouse",
                "readClipboard",
                "writeClipboard"
            ])
        );
        assert_eq!(
            SESSION_BROKER
                .lock()
                .unwrap()
                .snapshot()
                .unwrap()
                .connection_id,
            "session-host:7"
        );
        native_host_update_session_capabilities(
            7,
            NativeSessionCapabilities::new(false, true, false),
        );
        assert_eq!(
            host.snapshot_json()["activeSession"]["activeCapabilities"],
            json!(["viewDisplay", "readClipboard", "writeClipboard"])
        );
        native_host_end_session(7);
        assert!(SESSION_BROKER.lock().unwrap().snapshot().is_none());
        assert!(host.snapshot_json()["activeSession"].is_null());
        assert!(first_receiver.try_recv().is_err());

        let (second_sender, mut second_receiver) = tokio::sync::mpsc::unbounded_channel();
        assert!(native_host_begin_session(
            8,
            "remote-id-2".to_owned(),
            "Second Mac".to_owned(),
            "macOS".to_owned(),
            initial,
            initial,
            second_sender,
        ));
        reset_native_session_broker("hostStopped");
        assert!(matches!(
            second_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));
        assert!(SESSION_BROKER.lock().unwrap().snapshot().is_none());

        let encoded = serde_json::to_string(&*events.lock().unwrap()).unwrap();
        assert!(encoded.contains("sessionStarted"));
        assert!(encoded.contains("sessionCapabilitiesChanged"));
        assert!(encoded.contains("sessionEnded"));
        assert!(encoded.contains("RemoteMac"));
        assert!(!encoded.contains("Remote\\nMac"));
        assert!(encoded.contains("hostStopped"));
    }

    #[test]
    fn native_approval_snapshot_and_commands_are_recoverable_and_fail_closed() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let events = Mutex::new(Vec::new());
        let mut host = ready_test_host("approval-command-host");
        host.callbacks = RdnHostCallbacks {
            abi_version: HOST_ABI_VERSION,
            on_event: Some(collect_test_event),
            context: &events as *const Mutex<Vec<Value>> as *mut c_void,
        };

        let (pending, mut approve_receiver) = pending_approval_fixture(
            "approval-command-host:7",
            7,
            Instant::now() + Duration::from_secs(30),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(pending),
            NativeApprovalStartResult::Accepted
        );
        let snapshot = host.snapshot_json();
        assert_eq!(snapshot["schemaVersion"], SNAPSHOT_SCHEMA_VERSION);
        assert_eq!(
            snapshot["pendingApproval"]["connectionId"],
            "approval-command-host:7"
        );
        assert_eq!(
            snapshot["pendingApproval"]["remoteMetadataTrust"],
            "untrusted"
        );

        let approve = json!({
            "commandId": "approval-approve",
            "name": "approveConnection",
            "connectionId": "approval-command-host:7",
        });
        assert_eq!(
            handle_command(&mut host, "approval-approve", "approveConnection", &approve,),
            RDN_HOST_OK
        );
        assert!(matches!(
            approve_receiver.try_recv(),
            Ok(crate::ipc::Data::Authorize)
        ));
        assert!(host.snapshot_json()["pendingApproval"].is_null());
        assert_eq!(
            handle_command(&mut host, "approval-late", "approveConnection", &approve,),
            RDN_HOST_ERR_APPROVAL_FINALIZED
        );

        let malformed = json!({
            "commandId": "approval-malformed",
            "name": "rejectConnection",
            "connectionId": "approval-command-host:8",
            "ignored": true,
        });
        assert_eq!(
            handle_command(
                &mut host,
                "approval-malformed",
                "rejectConnection",
                &malformed,
            ),
            RDN_HOST_ERR_VALIDATION
        );

        let (reject_pending, mut reject_receiver) = pending_approval_fixture(
            "approval-command-host:8",
            8,
            Instant::now() + Duration::from_secs(30),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(reject_pending),
            NativeApprovalStartResult::Accepted
        );
        let reject = json!({
            "commandId": "approval-reject",
            "name": "rejectConnection",
            "connectionId": "approval-command-host:8",
        });
        assert_eq!(
            handle_command(&mut host, "approval-reject", "rejectConnection", &reject,),
            RDN_HOST_OK
        );
        assert!(matches!(
            reject_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));

        let (expired_pending, mut expired_receiver) = pending_approval_fixture(
            "approval-command-host:9",
            9,
            Instant::now() - Duration::from_millis(1),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(expired_pending),
            NativeApprovalStartResult::Accepted
        );
        let expired = json!({
            "commandId": "approval-expired",
            "name": "approveConnection",
            "connectionId": "approval-command-host:9",
        });
        assert_eq!(
            handle_command(&mut host, "approval-expired", "approveConnection", &expired,),
            RDN_HOST_ERR_APPROVAL_EXPIRED
        );
        assert!(matches!(
            expired_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));

        let (snapshot_expired, mut snapshot_expired_receiver) = pending_approval_fixture(
            "approval-command-host:10",
            10,
            Instant::now() - Duration::from_millis(1),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(snapshot_expired),
            NativeApprovalStartResult::Accepted
        );
        assert!(host.snapshot_json()["pendingApproval"].is_null());
        assert!(matches!(
            snapshot_expired_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));

        let encoded_events = serde_json::to_string(&*events.lock().unwrap()).unwrap();
        assert!(encoded_events.contains("approval-approved"));
        assert!(encoded_events.contains("approval-rejected"));
        assert!(encoded_events.contains("approval-expired"));
        assert!(!encoded_events.contains("decision_sender"));
        unbind_media_host();
    }

    fn submit_h264_access_unit(
        host: &mut RdnHost,
        route: &NativeMediaRoute,
        instance_id: &CString,
        pts_us: u64,
        keyframe: bool,
    ) -> i32 {
        let data = [pts_us as u8];
        let flags = if keyframe {
            MEDIA_FLAG_KEYFRAME | MEDIA_FLAG_PARAMETER_SETS
        } else {
            0
        };
        let access_unit = RdnHostEncodedAccessUnit {
            abi_version: HOST_MEDIA_ABI_VERSION,
            host_instance_id: instance_id.as_ptr(),
            connection_epoch: route.connection_epoch,
            codec_epoch: route.codec_epoch,
            display_id: route.display_id,
            display_revision: route.display_revision,
            codec: MEDIA_CODEC_H264,
            framing: MEDIA_FRAMING_AVCC,
            flags,
            pts_us,
            data: data.as_ptr(),
            length: data.len(),
        };
        unsafe { rdn_host_media_submit_access_unit(host, &access_unit) }
    }

    fn media_packet(pts_us: u64, keyframe: bool) -> NativeMediaAccessUnit {
        NativeMediaAccessUnit {
            codec: MEDIA_CODEC_H264,
            framing: MEDIA_FRAMING_AVCC,
            pts_us,
            keyframe,
            has_parameter_sets: keyframe,
            data: vec![pts_us as u8],
        }
    }

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
            queue_telemetry: Arc::new(NativeMediaQueueTelemetry::default()),
            writer_telemetry: Arc::new(NativeMediaWriterTelemetry::default()),
            network_telemetry: Arc::new(NativeMediaNetworkTelemetry::default()),
            transport_telemetry: Arc::new(NativeMediaTransportTelemetry::default()),
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

    #[test]
    fn full_media_queue_rejects_newest_without_evicting_encoded_packets() {
        let (sender, receiver) = sync_channel(MEDIA_QUEUE_CAPACITY);
        let telemetry = NativeMediaQueueTelemetry::default();
        for (pts_us, keyframe) in [(100, true), (200, false), (300, false)] {
            assert!(
                try_enqueue_native_media(&sender, &telemetry, media_packet(pts_us, keyframe))
                    .is_ok()
            );
        }
        assert_eq!(
            telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: MEDIA_QUEUE_CAPACITY,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            }
        );

        let (reason, rejected) =
            try_enqueue_native_media(&sender, &telemetry, media_packet(400, false))
                .expect_err("a full encoded queue must reject the new packet");
        assert_eq!(reason, NativeMediaQueueDropReason::NetworkBackpressure);
        assert_eq!(rejected.pts_us, 400);
        assert_eq!(
            telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: MEDIA_QUEUE_CAPACITY,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            }
        );

        let retained = (0..MEDIA_QUEUE_CAPACITY)
            .map(|_| {
                let packet = receiver.try_recv().expect("queued packet");
                telemetry.record_dequeued();
                packet
            })
            .collect::<Vec<_>>();
        assert_eq!(
            telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 0,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            }
        );
        assert_eq!(
            retained
                .iter()
                .map(|packet| packet.pts_us)
                .collect::<Vec<_>>(),
            vec![100, 200, 300]
        );
        assert_eq!(
            retained
                .iter()
                .map(|packet| packet.keyframe)
                .collect::<Vec<_>>(),
            vec![true, false, false]
        );
    }

    #[test]
    fn public_access_unit_api_reports_saturation_then_accepts_replacement_idr() {
        let _serial = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        let mut host = ready_test_host("queue-saturation-host");
        bind_media_host(&host);
        let _bound = BoundMediaTestGuard;
        {
            let mut broker = MEDIA_BROKER.lock().unwrap();
            broker.capabilities = MediaCapabilities {
                h264_hardware: true,
                h265_hardware: false,
                max_width: 1_920,
                max_height: 1_080,
                max_fps: 60,
            };
        }
        let route = native_media_begin_route(0, 1, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
            .expect("test route should use the production bounded queue");
        let instance_id = CString::new(host.instance_id.clone()).unwrap();

        for (pts_us, keyframe) in [(100, true), (200, false), (300, false)] {
            assert_eq!(
                submit_h264_access_unit(&mut host, &route, &instance_id, pts_us, keyframe),
                RDN_HOST_OK
            );
        }
        assert_eq!(
            route.queue_telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 3,
                maximum_depth: 3,
            }
        );
        assert_eq!(
            submit_h264_access_unit(&mut host, &route, &instance_id, 400, false),
            RDN_HOST_ERR_BACKPRESSURE
        );

        let first = route.receiver.try_recv().expect("first queued IDR");
        native_media_record_dequeued(&route);
        assert_eq!(first.pts_us, 100);
        assert!(first.keyframe);
        assert!(first.has_parameter_sets);

        // A rejected submit must not advance route state. Reusing its PTS for
        // the replacement generation's IDR is therefore valid once one queue
        // slot is available.
        assert_eq!(
            submit_h264_access_unit(&mut host, &route, &instance_id, 400, true),
            RDN_HOST_OK
        );
        assert_eq!(
            route.queue_telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 3,
                maximum_depth: 3,
            }
        );
        let retained = (0..MEDIA_QUEUE_CAPACITY)
            .map(|_| {
                let packet = route.receiver.try_recv().expect("retained queued packet");
                native_media_record_dequeued(&route);
                packet
            })
            .collect::<Vec<_>>();
        assert_eq!(
            route.queue_telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 0,
                maximum_depth: 3,
            }
        );
        assert_eq!(
            retained
                .iter()
                .map(|packet| packet.pts_us)
                .collect::<Vec<_>>(),
            vec![200, 300, 400]
        );
        assert!(!retained[0].keyframe);
        assert!(!retained[1].keyframe);
        assert!(retained[2].keyframe);
        assert!(retained[2].has_parameter_sets);
    }

    #[test]
    fn disconnected_media_queue_classifies_shutdown_and_returns_packet() {
        let (sender, receiver) = sync_channel(MEDIA_QUEUE_CAPACITY);
        let telemetry = NativeMediaQueueTelemetry::default();
        drop(receiver);

        let (reason, rejected) =
            try_enqueue_native_media(&sender, &telemetry, media_packet(500, true))
                .expect_err("a disconnected queue must reject the packet");
        assert_eq!(reason, NativeMediaQueueDropReason::Shutdown);
        assert_eq!(rejected.pts_us, 500);
        assert!(rejected.keyframe);
        assert!(rejected.has_parameter_sets);
        assert_eq!(telemetry.snapshot(), NativeMediaQueueSnapshot::default());
    }

    #[test]
    fn media_queue_payload_is_sanitized_and_bounded() {
        let payload = native_media_queue_payload(
            "routeStopped",
            7,
            9,
            0,
            3,
            NativeMediaQueueSnapshot {
                current_depth: 1,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            },
        );
        assert_eq!(payload["kind"], "routeStopped");
        assert_eq!(payload["connectionEpoch"], 7);
        assert_eq!(payload["codecEpoch"], 9);
        assert_eq!(payload["displayId"], 0);
        assert_eq!(payload["displayRevision"], 3);
        assert_eq!(payload["currentDepth"], 1);
        assert_eq!(payload["maximumDepth"], MEDIA_QUEUE_CAPACITY);
        assert_eq!(payload["capacity"], MEDIA_QUEUE_CAPACITY);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn writer_timing_aggregates_only_route_scoped_wall_measurements() {
        let telemetry = NativeMediaWriterTelemetry::default();
        telemetry.record(
            0,
            Duration::from_micros(99),
            Duration::from_millis(99),
            false,
        );
        telemetry.record(2, Duration::from_micros(15), Duration::from_millis(2), true);
        telemetry.record(
            1,
            Duration::from_micros(10),
            Duration::from_millis(3),
            false,
        );
        let snapshot = NativeMediaWriterSnapshot {
            cycles: 2,
            subscriber_dispatches: 3,
            dispatch_wall_total_us: 25,
            maximum_dispatch_wall_us: 15,
            confirmation_wait_total_us: 5_000,
            maximum_confirmation_wait_us: 3_000,
            completed_confirmations: 1,
            timed_out_confirmations: 1,
        };
        assert_eq!(telemetry.snapshot(), snapshot);
        let payload = native_media_writer_payload("sample", 7, 9, 0, 3, snapshot);
        assert_eq!(payload["cycles"], 2);
        assert_eq!(payload["subscriberDispatches"], 3);
        assert_eq!(payload["dispatchWallTotalUs"], 25);
        assert_eq!(payload["maximumConfirmationWaitUs"], 3_000);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn network_payload_preserves_sample_availability_and_count_bounds() {
        let telemetry = NativeMediaNetworkTelemetry::default();
        assert!(telemetry.record(3, 2, 2, 1, 1, Some(180), Some(42)));
        assert!(!telemetry.record(1, 2, 2, 1, 1, Some(180), Some(42)));
        assert!(!telemetry.record(3, 2, 0, 0, 0, Some(180), None));
        let snapshot = NativeMediaNetworkSnapshot {
            subscriber_count: 3,
            qos_subscriber_count: 2,
            delay_sampled_subscribers: 2,
            rtt_sampled_subscribers: 1,
            response_delayed_subscribers: 1,
            worst_network_delay_ms: Some(180),
            worst_rtt_ms: Some(42),
        };
        assert_eq!(telemetry.snapshot(), snapshot);
        let payload = native_media_network_payload("sample", 7, 9, 0, 3, snapshot);
        assert_eq!(payload["subscriberCount"], 3);
        assert_eq!(payload["qosSubscriberCount"], 2);
        assert_eq!(payload["delaySampledSubscribers"], 2);
        assert_eq!(payload["rttSampledSubscribers"], 1);
        assert_eq!(payload["responseDelayedSubscribers"], 1);
        assert_eq!(payload["worstNetworkDelayMs"], 180);
        assert_eq!(payload["worstRttMs"], 42);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn transport_payload_preserves_unknown_and_rejects_inconsistent_counts() {
        let telemetry = NativeMediaTransportTelemetry::default();
        assert!(telemetry.record(4, 2, 1, 1));
        assert!(!telemetry.record(4, 2, 1, 0));
        let snapshot = NativeMediaTransportSnapshot {
            subscriber_count: 4,
            direct_subscribers: 2,
            relay_subscribers: 1,
            unknown_subscribers: 1,
        };
        assert_eq!(telemetry.snapshot(), snapshot);
        let payload = native_media_transport_payload("sample", 7, 9, 0, 3, snapshot);
        assert_eq!(payload["subscriberCount"], 4);
        assert_eq!(payload["directSubscribers"], 2);
        assert_eq!(payload["relaySubscribers"], 1);
        assert_eq!(payload["unknownSubscribers"], 1);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn route_stop_emits_final_queue_sample_before_stop_control() {
        let _serial = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        let events = Mutex::new(Vec::<Value>::new());
        let mut host = ready_test_host("queue-event-host");
        host.callbacks.on_event = Some(collect_test_event);
        host.callbacks.context = &events as *const _ as *mut c_void;
        bind_media_host(&host);
        let _bound = BoundMediaTestGuard;
        {
            let mut broker = MEDIA_BROKER.lock().unwrap();
            broker.capabilities = MediaCapabilities {
                h264_hardware: true,
                h265_hardware: false,
                max_width: 1_920,
                max_height: 1_080,
                max_fps: 60,
            };
        }
        let route = native_media_begin_route(0, 3, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
            .expect("test route");
        let instance_id = CString::new(host.instance_id.clone()).unwrap();
        assert_eq!(
            submit_h264_access_unit(&mut host, &route, &instance_id, 100, true),
            RDN_HOST_OK
        );
        native_media_record_writer_cycle(
            &route,
            1,
            Duration::from_micros(10),
            Duration::from_millis(2),
            true,
        );
        native_media_report_queue_depth(&route);
        native_media_report_writer_timing(&route);
        native_media_report_network(&route, 1, 1, 1, 1, 0, Some(25), Some(20));
        native_media_report_transport(&route, 1, 0, 1, 0);
        native_media_end_route(&route);

        let events = events.lock().unwrap();
        let tail = &events[events.len() - 9..];
        assert_eq!(tail[0]["eventType"], "mediaQueueDiagnostic");
        assert_eq!(tail[0]["payload"]["kind"], "sample");
        assert_eq!(tail[1]["eventType"], "mediaWriterDiagnostic");
        assert_eq!(tail[1]["payload"]["kind"], "sample");
        assert_eq!(tail[2]["eventType"], "mediaNetworkDiagnostic");
        assert_eq!(tail[2]["payload"]["kind"], "sample");
        assert_eq!(tail[3]["eventType"], "mediaTransportDiagnostic");
        assert_eq!(tail[3]["payload"]["kind"], "sample");
        assert_eq!(tail[4]["eventType"], "mediaQueueDiagnostic");
        assert_eq!(tail[4]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[4]["payload"]["currentDepth"], 1);
        assert_eq!(tail[4]["payload"]["maximumDepth"], 1);
        assert_eq!(tail[5]["eventType"], "mediaWriterDiagnostic");
        assert_eq!(tail[5]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[5]["payload"]["cycles"], 1);
        assert_eq!(tail[6]["eventType"], "mediaNetworkDiagnostic");
        assert_eq!(tail[6]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[6]["payload"]["worstRttMs"], 20);
        assert_eq!(tail[7]["eventType"], "mediaTransportDiagnostic");
        assert_eq!(tail[7]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[7]["payload"]["relaySubscribers"], 1);
        assert_eq!(tail[8]["eventType"], "mediaControl");
        assert_eq!(tail[8]["payload"]["command"], "stopCapture");
    }
}
