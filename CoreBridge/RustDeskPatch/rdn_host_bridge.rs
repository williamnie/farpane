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

use hbb_common::{
    config,
    message_proto::{message, Clipboard, ClipboardFormat, Message},
    password_security, tokio, toml,
};
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

const HOST_ABI_VERSION: u32 = 13;
const HOST_MEDIA_ABI_VERSION: u32 = 1;
const EVENT_SCHEMA_VERSION: u32 = 1;
const SNAPSHOT_SCHEMA_VERSION: u32 = 8;
const UPSTREAM_COMMIT: &[u8] = b"6c578292e8ebbbec708b76986ba8c4bc7c509747\0";
const MAX_ENVELOPE_BYTES: usize = 64 * 1024;
const MAX_CLIPBOARD_TEXT_UTF8_BYTES: usize = 64 * 1024;
const MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES: usize = 1024 * 1024;
const MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES: usize = 1024 * 1024;
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
const MAX_HOST_CONFIG_BYTES: usize = 1024 * 1024;

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
const RDN_HOST_ERR_SESSION_NOT_FOUND: i32 = -24;
const RDN_HOST_ERR_SESSION_STALE: i32 = -25;
const RDN_HOST_ERR_SESSION_COMMAND_UNAVAILABLE: i32 = -26;
const RDN_HOST_ERR_STALE_GENERATION: i32 = -27;

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HostRecoveryState {
    Running,
    Suspending,
    Suspended,
    Resuming,
    Failed,
}

impl HostRecoveryState {
    fn name(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Suspending => "suspending",
            Self::Suspended => "suspended",
            Self::Resuming => "resuming",
            Self::Failed => "failed",
        }
    }
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

/// Single product authority for whether the current process owns an active
/// Aqua console session. macOS fails closed through the pinned CGSession
/// policy; non-macOS builds retain their existing behavior.
pub(crate) fn native_host_session_is_available() -> bool {
    #[cfg(target_os = "macos")]
    {
        crate::platform::macos::is_active_aqua_session()
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

fn native_host_session_availability_payload(
    available: bool,
) -> (&'static str, Option<&'static str>) {
    if available {
        ("available", None)
    } else {
        ("limited", Some("sessionUnavailable"))
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
    enable_clipboard_read: bool,
    enable_clipboard_write: bool,
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
    recovery_epoch: u64,
    recovery_state: HostRecoveryState,
    network_path_generation: u64,
    reveal_temporary_password: bool,
    last_error: Option<String>,
    event_id: Arc<AtomicU64>,
    callbacks: RdnHostCallbacks,
    rendezvous_server: String,
    relay_server: String,
    server_public_key: String,
    clipboard_policy: NativeClipboardPolicy,
    runtime: Option<HostRuntime>,
}

struct HostRuntime {
    stop_requested: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

struct RuntimeFinished(Arc<AtomicBool>);

const HOST_RUNTIME_RECONNECT_BASE_DELAY_MS: u64 = 250;
const HOST_RUNTIME_RECONNECT_MAX_DELAY_MS: u64 = 5_000;
const HOST_RUNTIME_RECONNECT_STABLE_CONNECTION_MS: u64 = 30_000;
const HOST_RUNTIME_RECONNECT_STOP_POLL_MS: u64 = 50;

#[derive(Default)]
struct HostRuntimeReconnectBackoff {
    consecutive_failures: u32,
}

impl HostRuntimeReconnectBackoff {
    fn delay_after_exit(&mut self, connection_lifetime: Duration, jitter_sample: u64) -> Duration {
        if connection_lifetime >= Duration::from_millis(HOST_RUNTIME_RECONNECT_STABLE_CONNECTION_MS)
        {
            self.consecutive_failures = 0;
        }
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        let doublings = self.consecutive_failures.saturating_sub(1).min(5);
        let nominal = HOST_RUNTIME_RECONNECT_BASE_DELAY_MS
            .saturating_mul(1_u64 << doublings)
            .min(HOST_RUNTIME_RECONNECT_MAX_DELAY_MS);
        let jitter_upper_bound = nominal / 4;
        let jitter = if jitter_upper_bound == 0 {
            0
        } else {
            jitter_sample % (jitter_upper_bound + 1)
        };
        Duration::from_millis(
            nominal
                .saturating_add(jitter)
                .min(HOST_RUNTIME_RECONNECT_MAX_DELAY_MS),
        )
    }
}

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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct NativeDisplayReconfigureProvenance {
    generation: u64,
    previous_display_revision: u64,
    previous_connection_epoch: u64,
    previous_codec_epoch: u64,
}

impl NativeDisplayReconfigureProvenance {
    fn payload(self) -> Value {
        json!({
            "displayReconfigureGeneration": self.generation,
            "previousDisplayRevision": self.previous_display_revision,
            "previousConnectionEpoch": self.previous_connection_epoch,
            "previousCodecEpoch": self.previous_codec_epoch,
        })
    }
}

#[derive(Default)]
struct MediaBroker {
    binding: Option<MediaHostBinding>,
    capabilities: MediaCapabilities,
    clipboard_policy: NativeClipboardPolicy,
    routes: HashMap<u64, MediaRoute>,
    display_revisions: HashMap<u64, u64>,
    pending_display_reconfigures: HashMap<u64, NativeDisplayReconfigureProvenance>,
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

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct NativeClipboardPolicy {
    remote_read: bool,
    remote_write: bool,
}

impl NativeClipboardPolicy {
    pub(crate) fn new(remote_read: bool, remote_write: bool) -> Self {
        Self {
            remote_read,
            remote_write,
        }
    }

    pub(crate) fn bidirectional(enabled: bool) -> Self {
        Self::new(enabled, enabled)
    }

    pub(crate) fn allows_remote_read(self) -> bool {
        self.remote_read
    }

    pub(crate) fn allows_remote_write(self) -> bool {
        self.remote_write
    }

    pub(crate) fn restricted_to(self, enabled: bool) -> Self {
        if enabled {
            self
        } else {
            Self::default()
        }
    }

    fn any_enabled(self) -> bool {
        self.remote_read || self.remote_write
    }

    fn is_subset_of(self, other: Self) -> bool {
        (!self.remote_read || other.remote_read) && (!self.remote_write || other.remote_write)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeClipboardDirection {
    RemoteRead,
    RemoteWrite,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeClipboardPayloadDisposition {
    InlineSmallText,
    // This is a routing requirement, not admission. The current data path
    // accepts only InlineSmallText; rich payloads stay closed until a bounded
    // independent transfer owner is implemented.
    IndependentTransferRequired,
    Reject,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeRichTextFormat {
    Rtf,
    Html,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeRichTextTransferEnvelope {
    format: NativeRichTextFormat,
    payload: String,
}

impl NativeRichTextTransferEnvelope {
    fn from_clipboard(clipboard: &Clipboard) -> Option<Self> {
        let format = match clipboard.format.enum_value().ok()? {
            ClipboardFormat::Rtf => NativeRichTextFormat::Rtf,
            ClipboardFormat::Html => NativeRichTextFormat::Html,
            _ => return None,
        };
        if !clipboard.special_name.is_empty()
            || clipboard.width != 0
            || clipboard.height != 0
            || clipboard.content.is_empty()
            || clipboard.content.len() > MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES
        {
            return None;
        }
        let decoded = if clipboard.compress {
            hbb_common::compress::decompress_with_limit(
                &clipboard.content,
                MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
            )
            .ok()?
        } else {
            clipboard.content.to_vec()
        };
        if decoded.is_empty() || decoded.len() > MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES {
            return None;
        }
        let payload = String::from_utf8(decoded).ok()?;
        if payload.contains('\0') {
            return None;
        }
        Some(Self { format, payload })
    }
}

pub(crate) fn native_host_configured_clipboard_policy() -> NativeClipboardPolicy {
    let broker = MEDIA_BROKER.lock().unwrap();
    if broker.binding.is_some() {
        broker.clipboard_policy
    } else {
        NativeClipboardPolicy::default()
    }
}

fn native_host_clipboard_payload_disposition(
    clipboard: &Clipboard,
) -> NativeClipboardPayloadDisposition {
    let Ok(format) = clipboard.format.enum_value() else {
        return NativeClipboardPayloadDisposition::Reject;
    };
    match format {
        ClipboardFormat::Text => {
            if !clipboard.special_name.is_empty()
                || clipboard.width != 0
                || clipboard.height != 0
                || clipboard.content.is_empty()
                || clipboard.content.len() > MAX_CLIPBOARD_TEXT_UTF8_BYTES
            {
                return NativeClipboardPayloadDisposition::Reject;
            }
            let decoded = if clipboard.compress {
                hbb_common::compress::decompress_with_limit(
                    &clipboard.content,
                    MAX_CLIPBOARD_TEXT_UTF8_BYTES,
                )
                .ok()
            } else {
                Some(clipboard.content.to_vec())
            };
            if decoded
                .filter(|bytes| !bytes.is_empty())
                .and_then(|bytes| String::from_utf8(bytes).ok())
                .is_some_and(|text| !text.contains('\0'))
            {
                NativeClipboardPayloadDisposition::InlineSmallText
            } else {
                NativeClipboardPayloadDisposition::Reject
            }
        }
        ClipboardFormat::Rtf | ClipboardFormat::Html => {
            NativeRichTextTransferEnvelope::from_clipboard(clipboard)
                .map_or(NativeClipboardPayloadDisposition::Reject, |_| {
                    NativeClipboardPayloadDisposition::IndependentTransferRequired
                })
        }
        ClipboardFormat::ImageRgba => {
            if clipboard.special_name.is_empty()
                && clipboard.width > 0
                && clipboard.height > 0
                && !clipboard.content.is_empty()
            {
                NativeClipboardPayloadDisposition::IndependentTransferRequired
            } else {
                NativeClipboardPayloadDisposition::Reject
            }
        }
        ClipboardFormat::ImagePng | ClipboardFormat::ImageSvg => {
            if clipboard.special_name.is_empty()
                && clipboard.width == 0
                && clipboard.height == 0
                && !clipboard.content.is_empty()
            {
                NativeClipboardPayloadDisposition::IndependentTransferRequired
            } else {
                NativeClipboardPayloadDisposition::Reject
            }
        }
        // Special names are remote-controlled UTI/format identifiers. They
        // stay rejected until an explicit allowlist and bounded transfer
        // envelope own both the identifier and payload.
        ClipboardFormat::Special => NativeClipboardPayloadDisposition::Reject,
    }
}

fn native_host_small_text_clipboard(clipboard: &Clipboard) -> bool {
    native_host_clipboard_payload_disposition(clipboard)
        == NativeClipboardPayloadDisposition::InlineSmallText
}

fn native_host_clipboard_direction_allows(
    policy: NativeClipboardPolicy,
    direction: NativeClipboardDirection,
    clipboards: &[Clipboard],
) -> bool {
    let direction_allowed = match direction {
        NativeClipboardDirection::RemoteRead => policy.allows_remote_read(),
        NativeClipboardDirection::RemoteWrite => policy.allows_remote_write(),
    };
    direction_allowed
        && clipboards.len() == 1
        && clipboards
            .first()
            .is_some_and(native_host_small_text_clipboard)
}

pub(crate) fn native_host_outgoing_clipboard_message_is_allowed(
    message: &Message,
    remote_read_allowed: bool,
) -> bool {
    match message.union.as_ref() {
        Some(message::Union::Clipboard(clipboard)) => {
            remote_read_allowed && native_host_small_text_clipboard(clipboard)
        }
        Some(message::Union::MultiClipboards(clipboards)) => {
            remote_read_allowed
                && native_host_clipboard_entries_are_small_text(&clipboards.clipboards)
        }
        _ => true,
    }
}

pub(crate) fn native_host_clipboard_entries_are_small_text(clipboards: &[Clipboard]) -> bool {
    clipboards.len() == 1
        && clipboards
            .first()
            .is_some_and(native_host_small_text_clipboard)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NativeSessionCapabilities {
    control_keyboard_mouse: bool,
    clipboard: NativeClipboardPolicy,
    system_audio: bool,
}

impl NativeSessionCapabilities {
    pub(crate) fn new(control_keyboard_mouse: bool, clipboard: bool, system_audio: bool) -> Self {
        Self::with_clipboard_policy(
            control_keyboard_mouse,
            NativeClipboardPolicy::bidirectional(clipboard),
            system_audio,
        )
    }

    pub(crate) fn with_clipboard_policy(
        control_keyboard_mouse: bool,
        clipboard: NativeClipboardPolicy,
        system_audio: bool,
    ) -> Self {
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
        if self.clipboard.remote_read {
            names.push("readClipboard");
        }
        if self.clipboard.remote_write {
            names.push("writeClipboard");
        }
        if self.system_audio {
            names.push("hearSystemAudio");
        }
        names
    }

    fn is_subset_of(self, other: Self) -> bool {
        (!self.control_keyboard_mouse || other.control_keyboard_mouse)
            && self.clipboard.is_subset_of(other.clipboard)
            && (!self.system_audio || other.system_audio)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeSessionInputUnavailableReason {
    LocalPolicyDisabled,
    RemoteDisabled,
    AccessibilityDenied,
    SessionUnavailable,
}

impl NativeSessionInputUnavailableReason {
    fn name(self) -> &'static str {
        match self {
            Self::LocalPolicyDisabled => "localPolicyDisabled",
            Self::RemoteDisabled => "remoteDisabled",
            Self::AccessibilityDenied => "accessibilityDenied",
            Self::SessionUnavailable => "sessionUnavailable",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeSessionInputAvailability {
    Available,
    Disabled(NativeSessionInputUnavailableReason),
    Limited(NativeSessionInputUnavailableReason),
}

impl NativeSessionInputAvailability {
    pub(crate) fn available() -> Self {
        Self::Available
    }

    pub(crate) fn disabled(reason: NativeSessionInputUnavailableReason) -> Self {
        debug_assert!(matches!(
            reason,
            NativeSessionInputUnavailableReason::LocalPolicyDisabled
                | NativeSessionInputUnavailableReason::RemoteDisabled
        ));
        Self::Disabled(reason)
    }

    pub(crate) fn limited(reason: NativeSessionInputUnavailableReason) -> Self {
        debug_assert!(matches!(
            reason,
            NativeSessionInputUnavailableReason::AccessibilityDenied
                | NativeSessionInputUnavailableReason::SessionUnavailable
        ));
        Self::Limited(reason)
    }

    fn name(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::Disabled(_) => "disabled",
            Self::Limited(_) => "limited",
        }
    }

    fn reason(self) -> Option<&'static str> {
        match self {
            Self::Available => None,
            Self::Disabled(reason) | Self::Limited(reason) => Some(reason.name()),
        }
    }

    fn is_valid(self, control_keyboard_mouse: bool) -> bool {
        match self {
            Self::Available => control_keyboard_mouse,
            Self::Disabled(
                NativeSessionInputUnavailableReason::LocalPolicyDisabled
                | NativeSessionInputUnavailableReason::RemoteDisabled,
            ) => !control_keyboard_mouse,
            Self::Limited(
                NativeSessionInputUnavailableReason::AccessibilityDenied
                | NativeSessionInputUnavailableReason::SessionUnavailable,
            ) => !control_keyboard_mouse,
            Self::Disabled(_) | Self::Limited(_) => false,
        }
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
    input_availability: NativeSessionInputAvailability,
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
            "inputAvailability": self.input_availability.name(),
            "inputUnavailableReason": self.input_availability.reason(),
        })
    }
}

struct NativeActiveSession {
    snapshot: NativeSessionSnapshot,
    command_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
    disconnect_requested: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionStartResult {
    Accepted,
    Existing,
    Busy,
    Invalid,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionCommand {
    DisableInput,
    DisableClipboardRead,
    DisableClipboardWrite,
    DisableClipboard,
    DisableAudio,
    Disconnect,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionCommandResult {
    Queued,
    NoChange,
    NotFound,
    Stale,
    Unavailable,
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
            || !session
                .snapshot
                .input_availability
                .is_valid(session.snapshot.active_capabilities.control_keyboard_mouse)
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
        input_availability: NativeSessionInputAvailability,
    ) -> Option<NativeSessionSnapshot> {
        let active = self.active.as_mut()?;
        if active.snapshot.core_connection_id != core_connection_id
            || !active_capabilities.is_subset_of(active.snapshot.initial_capabilities)
            || !input_availability.is_valid(active_capabilities.control_keyboard_mouse)
        {
            return None;
        }
        if active.snapshot.active_capabilities == active_capabilities
            && active.snapshot.input_availability == input_availability
        {
            return None;
        }
        active.snapshot.active_capabilities = active_capabilities;
        active.snapshot.input_availability = input_availability;
        Some(active.snapshot.clone())
    }

    fn command(
        &mut self,
        connection_id: &str,
        command: NativeSessionCommand,
    ) -> NativeSessionCommandResult {
        let Some(active) = self.active.as_mut() else {
            return NativeSessionCommandResult::NotFound;
        };
        if active.snapshot.connection_id != connection_id {
            return NativeSessionCommandResult::Stale;
        }

        let data = match command {
            NativeSessionCommand::DisableInput => {
                if !active.snapshot.active_capabilities.control_keyboard_mouse {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "keyboard".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableClipboard => {
                if !active.snapshot.active_capabilities.clipboard.any_enabled() {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableClipboardRead => {
                if !active
                    .snapshot
                    .active_capabilities
                    .clipboard
                    .allows_remote_read()
                {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-read".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableClipboardWrite => {
                if !active
                    .snapshot
                    .active_capabilities
                    .clipboard
                    .allows_remote_write()
                {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-write".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableAudio => {
                if !active.snapshot.active_capabilities.system_audio {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "audio".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::Disconnect => {
                if active.disconnect_requested {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::Close
            }
        };
        if active.command_sender.send(data).is_err() {
            return NativeSessionCommandResult::Unavailable;
        }
        if command == NativeSessionCommand::Disconnect {
            active.disconnect_requested = true;
        }
        NativeSessionCommandResult::Queued
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
static NEXT_DISPLAY_RECONFIGURE_GENERATION: AtomicU64 = AtomicU64::new(1);

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
    input_availability: NativeSessionInputAvailability,
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
        input_availability,
    };
    let result = SESSION_BROKER.lock().unwrap().begin(NativeActiveSession {
        snapshot: snapshot.clone(),
        command_sender,
        disconnect_requested: false,
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
    input_availability: NativeSessionInputAvailability,
) {
    let snapshot = SESSION_BROKER.lock().unwrap().update_capabilities(
        core_connection_id,
        active_capabilities,
        input_availability,
    );
    let Some(snapshot) = snapshot else { return };
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionCapabilitiesChanged",
            json!({
                "connectionId": snapshot.connection_id,
                "activeCapabilities": snapshot.active_capabilities.names(),
                "inputAvailability": snapshot.input_availability.name(),
                "inputUnavailableReason": snapshot.input_availability.reason(),
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
    broker.display_revisions.clear();
    broker.pending_display_reconfigures.clear();
    broker.capabilities = MediaCapabilities::default();
    broker.clipboard_policy = host.clipboard_policy;
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
        broker.display_revisions.clear();
        broker.pending_display_reconfigures.clear();
        broker.capabilities = MediaCapabilities::default();
        broker.clipboard_policy = NativeClipboardPolicy::default();
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
    let connection_epoch = next_native_media_epoch(&NEXT_CONNECTION_EPOCH)
        .ok_or("native media connection epoch is exhausted")?;
    let codec_epoch = next_native_media_epoch(&NEXT_CODEC_EPOCH)
        .ok_or("native media codec epoch is exhausted")?;
    let (binding, display_revision, display_reconfigure) = {
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
        let display_reconfigure = broker.pending_display_reconfigures.remove(&display_id);
        let display_revision = match display_reconfigure {
            Some(provenance) => provenance
                .previous_display_revision
                .checked_add(1)
                .ok_or("native media display revision is exhausted")?,
            None => broker
                .display_revisions
                .get(&display_id)
                .copied()
                .unwrap_or(1),
        };
        broker
            .display_revisions
            .insert(display_id, display_revision);
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
        (binding, display_revision, display_reconfigure)
    };
    let codec_name = if codec == MEDIA_CODEC_H264 {
        "h264"
    } else {
        "h265"
    };
    let mut start_payload = json!({
        "command": "startCapture",
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
    });
    let mut reconfigure_payload = json!({
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
    });
    if let Some(provenance) = display_reconfigure {
        start_payload["displayReconfigure"] = provenance.payload();
        reconfigure_payload["displayReconfigure"] = provenance.payload();
    }
    emit_bound_event(&binding, "mediaControl", start_payload);
    emit_bound_event(&binding, "mediaControl", reconfigure_payload);
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

/// Marks only the exact active monitor route whose pinned display inventory
/// comparison observed a change. The next replacement route consumes this
/// marker; codec/subscriber/service retries never synthesize one.
pub(crate) fn native_media_mark_display_reconfigure(
    route: &NativeMediaRoute,
) -> Result<(), &'static str> {
    let (binding, provenance) = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let current = broker
            .routes
            .get(&route.display_id)
            .ok_or("native media display route is unavailable")?;
        if current.connection_epoch != route.connection_epoch
            || current.codec_epoch != route.codec_epoch
            || current.display_revision != route.display_revision
        {
            return Err("native media display route is stale");
        }
        if route.display_revision == u64::MAX
            || broker
                .pending_display_reconfigures
                .contains_key(&route.display_id)
        {
            return Err("native media display reconfigure is unavailable");
        }
        let generation = next_native_media_epoch(&NEXT_DISPLAY_RECONFIGURE_GENERATION)
            .ok_or("native display reconfigure generation is exhausted")?;
        let binding = broker
            .binding
            .clone()
            .ok_or("native host media is not bound")?;
        let provenance = NativeDisplayReconfigureProvenance {
            generation,
            previous_display_revision: route.display_revision,
            previous_connection_epoch: route.connection_epoch,
            previous_codec_epoch: route.codec_epoch,
        };
        broker
            .pending_display_reconfigures
            .insert(route.display_id, provenance);
        (binding, provenance)
    };
    emit_bound_event(
        &binding,
        "mediaDisplayReconfigureStarted",
        json!({
            "displayReconfigureGeneration": provenance.generation,
            "displayId": route.display_id,
            "previousDisplayRevision": provenance.previous_display_revision,
            "previousConnectionEpoch": provenance.previous_connection_epoch,
            "previousCodecEpoch": provenance.previous_codec_epoch,
        }),
    );
    Ok(())
}

fn next_native_media_epoch(counter: &AtomicU64) -> Option<u64> {
    counter
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
            current.checked_add(1)
        })
        .ok()
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

async fn wait_for_host_runtime_retry(stop_requested: &AtomicBool, delay: Duration) -> bool {
    let deadline = Instant::now() + delay;
    loop {
        if stop_requested.load(Ordering::Acquire) {
            return false;
        }
        let now = Instant::now();
        if now >= deadline {
            return true;
        }
        hbb_common::tokio::time::sleep(
            deadline
                .saturating_duration_since(now)
                .min(Duration::from_millis(HOST_RUNTIME_RECONNECT_STOP_POLL_MS)),
        )
        .await;
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
                    let mut reconnect_backoff = HostRuntimeReconnectBackoff::default();
                    while !thread_stop.load(Ordering::Acquire) {
                        let connection_started = Instant::now();
                        let _ = crate::RendezvousMediator::start(
                            server.clone(),
                            rendezvous_server.clone(),
                        )
                        .await;
                        if thread_stop.load(Ordering::Acquire) {
                            break;
                        }
                        config::Config::reset_online();
                        let retry_delay = reconnect_backoff.delay_after_exit(
                            connection_started.elapsed(),
                            u64::from(hbb_common::time_based_rand()),
                        );
                        if !wait_for_host_runtime_retry(&thread_stop, retry_delay).await {
                            break;
                        }
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

    fn request_stop(&self) {
        self.stop_requested.store(true, Ordering::Release);
        crate::RendezvousMediator::stop_native_host_runtime();
    }

    fn join(&mut self) -> bool {
        let joined = self
            .thread
            .take()
            .map(|thread| thread.join().is_ok())
            .unwrap_or(true);
        config::Config::reset_online();
        joined
    }

    fn stop(&mut self) -> bool {
        self.request_stop();
        self.join()
    }
}

impl RdnHost {
    fn refresh_registration_state(&mut self) {
        match self.recovery_state {
            HostRecoveryState::Suspending => {
                self.registration_status = "suspending";
                return;
            }
            HostRecoveryState::Suspended => {
                self.registration_status = "suspended";
                return;
            }
            HostRecoveryState::Failed => return,
            HostRecoveryState::Running | HostRecoveryState::Resuming => {}
        }
        if !matches!(self.state, RdnHostState::Starting | RdnHostState::Ready) {
            return;
        }
        if config::Config::get_key_confirmed() && config::get_online_state() > 0 {
            self.registration_status = "ready";
            self.state = RdnHostState::Ready;
            self.recovery_state = HostRecoveryState::Running;
            self.last_error = None;
        } else if self
            .runtime
            .as_ref()
            .map(HostRuntime::is_finished)
            .unwrap_or(true)
        {
            self.registration_status = "degraded";
            self.state = RdnHostState::Error;
            if self.recovery_state == HostRecoveryState::Resuming {
                self.recovery_state = HostRecoveryState::Failed;
            }
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
        let (session_availability, session_unavailable_reason) =
            native_host_session_availability_payload(native_host_session_is_available());
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
            "authenticatedConnectionCount".into(),
            json!(crate::server::native_host_authenticated_connection_count()),
        );
        map.insert("sessionAvailability".into(), json!(session_availability));
        map.insert(
            "sessionUnavailableReason".into(),
            json!(session_unavailable_reason),
        );
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
        map.insert("recoveryEpoch".into(), json!(self.recovery_epoch));
        map.insert("recoveryStatus".into(), json!(self.recovery_state.name()));
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
        recovery_epoch: 0,
        recovery_state: HostRecoveryState::Running,
        network_path_generation: 0,
        reveal_temporary_password: false,
        last_error: None,
        event_id: Arc::new(AtomicU64::new(0)),
        callbacks: *callbacks,
        rendezvous_server,
        relay_server,
        server_public_key,
        clipboard_policy: NativeClipboardPolicy::new(
            (*options).enable_clipboard_read,
            (*options).enable_clipboard_write,
        ),
        runtime: None,
    });
    *out_host = Box::into_raw(host);
    RDN_HOST_OK
}

#[derive(Debug, PartialEq, Eq)]
enum HostStoragePreflightError {
    InvalidPath,
    #[cfg(not(unix))]
    UnsupportedPlatform,
    OpenDirectory,
    UnsafeDirectory,
    OpenFile,
    UnsafeFile,
    ReadFile,
    InvalidUtf8,
    InvalidToml,
    PersistenceMismatch,
}

#[derive(Clone, Copy)]
enum HostStorageDocument {
    Identity,
    Options,
}

enum HostStorageSnapshot {
    Identity {
        encrypted_id_present: bool,
        password_matches: Option<bool>,
    },
    Options(HashMap<String, String>),
}

#[derive(Default, serde_derive::Deserialize)]
#[serde(deny_unknown_fields)]
struct HostIdentityPersistenceProjection {
    #[serde(default)]
    id: String,
    #[serde(default)]
    enc_id: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    salt: String,
    #[serde(default)]
    key_pair: (Vec<u8>, Vec<u8>),
    #[serde(default)]
    key_confirmed: bool,
    #[serde(default)]
    keys_confirmed: HashMap<String, bool>,
}

impl Drop for HostIdentityPersistenceProjection {
    fn drop(&mut self) {
        wipe_host_storage_string(&mut self.id);
        wipe_host_storage_string(&mut self.enc_id);
        wipe_host_storage_string(&mut self.password);
        wipe_host_storage_string(&mut self.salt);
        password_security::memzero_secret(&mut self.key_pair.0);
        password_security::memzero_secret(&mut self.key_pair.1);
        for (mut key, _) in self.keys_confirmed.drain() {
            wipe_host_storage_string(&mut key);
        }
        self.key_confirmed = false;
    }
}

struct WipedHostStorageBytes(Vec<u8>);

impl WipedHostStorageBytes {
    fn new(capacity: usize) -> Self {
        Self(Vec::with_capacity(capacity))
    }

    fn bytes(&self) -> &[u8] {
        &self.0
    }
}

impl Drop for WipedHostStorageBytes {
    fn drop(&mut self) {
        password_security::memzero_secret(&mut self.0);
    }
}

struct WipedHostStorageString(String);

impl Drop for WipedHostStorageString {
    fn drop(&mut self) {
        wipe_host_storage_string(&mut self.0);
    }
}

fn wipe_host_storage_string(value: &mut String) {
    // String guarantees that its initialized bytes are contiguous. The value
    // is never read again after this wipe; Drop subsequently releases the
    // allocation without exposing verifier, salt or encrypted identity bytes.
    password_security::memzero_secret(unsafe { value.as_mut_vec() });
}

fn preflight_host_storage() -> Result<(), HostStoragePreflightError> {
    preflight_host_storage_paths(&config::Config::file(), &config::Config2::file())
}

fn verify_host_start_storage(host: &RdnHost) -> Result<(), HostStoragePreflightError> {
    verify_host_start_storage_paths(
        &config::Config::file(),
        &config::Config2::file(),
        &host.rendezvous_server,
        &host.relay_server,
        &host.server_public_key,
        host.clipboard_policy,
    )
}

const NATIVE_HOST_ALWAYS_DISABLED_OPTION_KEYS: [&str; 2] = [
    config::keys::OPTION_ENABLE_FILE_TRANSFER,
    config::keys::OPTION_ENABLE_AUDIO,
];

fn native_host_clipboard_option(policy: NativeClipboardPolicy) -> &'static str {
    if policy.any_enabled() {
        "Y"
    } else {
        "N"
    }
}

fn apply_native_host_optional_capability_policy(policy: NativeClipboardPolicy) {
    config::Config::set_option(
        config::keys::OPTION_ENABLE_CLIPBOARD.to_owned(),
        native_host_clipboard_option(policy).to_owned(),
    );
    for key in NATIVE_HOST_ALWAYS_DISABLED_OPTION_KEYS {
        config::Config::set_option(key.to_owned(), "N".to_owned());
    }
}

fn verify_host_password_storage() -> Result<(), HostStoragePreflightError> {
    let (storage, salt) = config::Config::get_local_permanent_password_storage_and_salt();
    let storage = WipedHostStorageString(storage);
    let salt = WipedHostStorageString(salt);
    verify_host_password_storage_paths(
        &config::Config::file(),
        &config::Config2::file(),
        &storage.0,
        &salt.0,
    )
}

#[cfg(not(unix))]
fn preflight_host_storage_paths(
    _identity_path: &std::path::Path,
    _options_path: &std::path::Path,
) -> Result<(), HostStoragePreflightError> {
    Err(HostStoragePreflightError::UnsupportedPlatform)
}

#[cfg(not(unix))]
fn verify_host_start_storage_paths(
    _identity_path: &std::path::Path,
    _options_path: &std::path::Path,
    _rendezvous_server: &str,
    _relay_server: &str,
    _server_public_key: &str,
    _clipboard_policy: NativeClipboardPolicy,
) -> Result<(), HostStoragePreflightError> {
    Err(HostStoragePreflightError::UnsupportedPlatform)
}

#[cfg(not(unix))]
fn verify_host_password_storage_paths(
    _identity_path: &std::path::Path,
    _options_path: &std::path::Path,
    _password_storage: &str,
    _password_salt: &str,
) -> Result<(), HostStoragePreflightError> {
    Err(HostStoragePreflightError::UnsupportedPlatform)
}

#[cfg(unix)]
fn preflight_host_storage_paths(
    identity_path: &std::path::Path,
    options_path: &std::path::Path,
) -> Result<(), HostStoragePreflightError> {
    inspect_host_storage_paths(identity_path, options_path, None).map(|_| ())
}

#[cfg(unix)]
fn verify_host_start_storage_paths(
    identity_path: &std::path::Path,
    options_path: &std::path::Path,
    rendezvous_server: &str,
    relay_server: &str,
    server_public_key: &str,
    clipboard_policy: NativeClipboardPolicy,
) -> Result<(), HostStoragePreflightError> {
    let (identity, options) = inspect_host_storage_paths(identity_path, options_path, None)?;
    let Some(HostStorageSnapshot::Identity {
        encrypted_id_present: true,
        ..
    }) = identity
    else {
        return Err(HostStoragePreflightError::PersistenceMismatch);
    };
    let Some(HostStorageSnapshot::Options(options)) = options else {
        return Err(HostStoragePreflightError::PersistenceMismatch);
    };
    let expected = [
        ("custom-rendezvous-server", rendezvous_server),
        ("relay-server", relay_server),
        ("key", server_public_key),
        (
            config::keys::OPTION_KEEP_AWAKE_DURING_INCOMING_SESSIONS,
            "Y",
        ),
        (
            config::keys::OPTION_ENABLE_CLIPBOARD,
            native_host_clipboard_option(clipboard_policy),
        ),
        (config::keys::OPTION_ENABLE_FILE_TRANSFER, "N"),
        (config::keys::OPTION_ENABLE_AUDIO, "N"),
        ("stop-service", ""),
    ];
    if expected
        .iter()
        .all(|(key, value)| persisted_host_option_matches(&options, key, value))
    {
        Ok(())
    } else {
        Err(HostStoragePreflightError::PersistenceMismatch)
    }
}

#[cfg(unix)]
fn verify_host_password_storage_paths(
    identity_path: &std::path::Path,
    options_path: &std::path::Path,
    password_storage: &str,
    password_salt: &str,
) -> Result<(), HostStoragePreflightError> {
    let (identity, options) = inspect_host_storage_paths(
        identity_path,
        options_path,
        Some((password_storage, password_salt)),
    )?;
    let Some(HostStorageSnapshot::Identity {
        encrypted_id_present: true,
        password_matches: Some(true),
    }) = identity
    else {
        return Err(HostStoragePreflightError::PersistenceMismatch);
    };
    if !matches!(options, Some(HostStorageSnapshot::Options(_))) {
        return Err(HostStoragePreflightError::PersistenceMismatch);
    }
    Ok(())
}

#[cfg(unix)]
fn persisted_host_option_matches(
    options: &HashMap<String, String>,
    key: &str,
    expected: &str,
) -> bool {
    if expected.is_empty() {
        !options.contains_key(key)
    } else {
        options.get(key).map(String::as_str) == Some(expected)
    }
}

#[cfg(unix)]
fn inspect_host_storage_paths(
    identity_path: &std::path::Path,
    options_path: &std::path::Path,
    password_expectation: Option<(&str, &str)>,
) -> Result<(Option<HostStorageSnapshot>, Option<HostStorageSnapshot>), HostStoragePreflightError> {
    use hbb_common::libc;
    use std::{
        ffi::CString,
        fs::File,
        os::unix::{
            ffi::OsStrExt,
            io::{AsRawFd, FromRawFd},
        },
    };

    let directory_path = identity_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or(HostStoragePreflightError::InvalidPath)?;
    if options_path.parent() != Some(directory_path)
        || identity_path.file_name().is_none()
        || options_path.file_name().is_none()
        || identity_path.file_name() == options_path.file_name()
    {
        return Err(HostStoragePreflightError::InvalidPath);
    }
    let directory_c = CString::new(directory_path.as_os_str().as_bytes())
        .map_err(|_| HostStoragePreflightError::InvalidPath)?;
    let directory_fd = unsafe {
        libc::open(
            directory_c.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if directory_fd < 0 {
        return match std::io::Error::last_os_error().raw_os_error() {
            Some(libc::ENOENT) => Ok((None, None)),
            _ => Err(HostStoragePreflightError::OpenDirectory),
        };
    }
    let directory = unsafe { File::from_raw_fd(directory_fd) };
    let directory_stat = checked_fstat(directory.as_raw_fd())
        .map_err(|_| HostStoragePreflightError::UnsafeDirectory)?;
    if directory_stat.st_mode & libc::S_IFMT != libc::S_IFDIR
        || directory_stat.st_uid != unsafe { libc::geteuid() }
        || directory_stat.st_mode & 0o022 != 0
    {
        return Err(HostStoragePreflightError::UnsafeDirectory);
    }

    let identity = inspect_host_storage_file(
        &directory,
        identity_path,
        HostStorageDocument::Identity,
        password_expectation,
    )?;
    let options =
        inspect_host_storage_file(&directory, options_path, HostStorageDocument::Options, None)?;
    Ok((identity, options))
}

#[cfg(unix)]
fn checked_fstat(fd: std::os::fd::RawFd) -> Result<hbb_common::libc::stat, ()> {
    use hbb_common::libc;
    let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(fd, metadata.as_mut_ptr()) } != 0 {
        return Err(());
    }
    Ok(unsafe { metadata.assume_init() })
}

#[cfg(unix)]
fn inspect_host_storage_file(
    directory: &std::fs::File,
    path: &std::path::Path,
    document: HostStorageDocument,
    password_expectation: Option<(&str, &str)>,
) -> Result<Option<HostStorageSnapshot>, HostStoragePreflightError> {
    use hbb_common::libc;
    use std::{
        ffi::CString,
        fs::File,
        io::Read,
        os::unix::{
            ffi::OsStrExt,
            io::{AsRawFd, FromRawFd},
        },
    };

    let file_name = path
        .file_name()
        .ok_or(HostStoragePreflightError::InvalidPath)?;
    let file_name_c =
        CString::new(file_name.as_bytes()).map_err(|_| HostStoragePreflightError::InvalidPath)?;
    let file_fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            file_name_c.as_ptr(),
            libc::O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if file_fd < 0 {
        return match std::io::Error::last_os_error().raw_os_error() {
            Some(libc::ENOENT) => Ok(None),
            _ => Err(HostStoragePreflightError::OpenFile),
        };
    }
    let mut file = unsafe { File::from_raw_fd(file_fd) };
    let initial_stat =
        checked_fstat(file.as_raw_fd()).map_err(|_| HostStoragePreflightError::UnsafeFile)?;
    if initial_stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || initial_stat.st_uid != unsafe { libc::geteuid() }
        || initial_stat.st_mode & 0o777 != 0o600
        || initial_stat.st_nlink != 1
        || initial_stat.st_size <= 0
        || initial_stat.st_size as u64 > MAX_HOST_CONFIG_BYTES as u64
    {
        return Err(HostStoragePreflightError::UnsafeFile);
    }

    let mut bytes = WipedHostStorageBytes::new(initial_stat.st_size as usize);
    file.by_ref()
        .take(MAX_HOST_CONFIG_BYTES as u64 + 1)
        .read_to_end(&mut bytes.0)
        .map_err(|_| HostStoragePreflightError::ReadFile)?;
    let final_stat =
        checked_fstat(file.as_raw_fd()).map_err(|_| HostStoragePreflightError::UnsafeFile)?;
    if bytes.0.len() > MAX_HOST_CONFIG_BYTES
        || bytes.0.len() as i64 != initial_stat.st_size
        || final_stat.st_dev != initial_stat.st_dev
        || final_stat.st_ino != initial_stat.st_ino
        || final_stat.st_size != initial_stat.st_size
    {
        return Err(HostStoragePreflightError::UnsafeFile);
    }
    let text =
        std::str::from_utf8(bytes.bytes()).map_err(|_| HostStoragePreflightError::InvalidUtf8)?;
    match document {
        HostStorageDocument::Identity => {
            let document = toml::from_str::<HostIdentityPersistenceProjection>(text)
                .map_err(|_| HostStoragePreflightError::InvalidToml)?;
            let encrypted_id_present = !document.enc_id.is_empty();
            let password_matches = password_expectation
                .map(|(storage, salt)| document.password == storage && document.salt == salt);
            Ok(Some(HostStorageSnapshot::Identity {
                encrypted_id_present,
                password_matches,
            }))
        }
        HostStorageDocument::Options => toml::from_str::<config::Config2>(text)
            .map(|config| Some(HostStorageSnapshot::Options(config.options)))
            .map_err(|_| HostStoragePreflightError::InvalidToml),
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_start(host: *mut RdnHost) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if !matches!(host.state, RdnHostState::Created | RdnHostState::Stopped) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    // Upstream Config/Config2 loading falls back to defaults on malformed or
    // unreadable TOML. The writes below could then replace the last durable
    // identity/config with generated defaults. Inspect both fixed Host files
    // first, without creating or rewriting anything, and fail closed instead.
    if preflight_host_storage().is_err() {
        host.registration_status = "degraded";
        host.state = RdnHostState::Error;
        host.last_error = Some("configuration.storagePreflightFailed".to_owned());
        host.emit_snapshot_changed();
        return RDN_HOST_ERR_STORAGE;
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
    // Clipboard is enabled only when at least one explicit, independently
    // enforced small-text direction was supplied at create. File transfer and
    // audio remain disabled. Upstream treats a missing `enable-*` option as
    // enabled, so absence is never accepted as product policy.
    apply_native_host_optional_capability_policy(host.clipboard_policy);
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
    // Upstream setters do not propagate confy write failures. Re-open the
    // fixed private files and require the persisted identity/config projection
    // needed by this start before any media or network runtime is created.
    // This proves readback, not fsync durability; the latter remains a
    // separate storage-writer boundary.
    if verify_host_start_storage(host).is_err() {
        host.registration_status = "degraded";
        host.state = RdnHostState::Error;
        host.last_error = Some("configuration.storagePersistenceFailed".to_owned());
        host.emit_snapshot_changed();
        return RDN_HOST_ERR_STORAGE;
    }
    bind_media_host(host);
    // The process-global wakelock worker outlives an individual Host handle.
    // Reset it only after binding this native Host so its thread pins the
    // user-idle (display-off) policy and cannot inherit a prior sleep epoch.
    if !crate::server::native_host_reset_wakelock() {
        unbind_media_host();
        host.registration_status = "degraded";
        host.state = RdnHostState::Error;
        host.recovery_state = HostRecoveryState::Failed;
        host.last_error = Some("power.wakelockResetFailed".to_owned());
        host.emit_snapshot_changed();
        return RDN_HOST_ERR_INTERNAL;
    }
    host.recovery_state = HostRecoveryState::Running;
    // A terminal stop/start begins a fresh product network-observation
    // lifetime. The path trigger owner also restarts from generation zero.
    host.network_path_generation = 0;
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
    host.recovery_state = HostRecoveryState::Running;
    if matches!(reason, RdnHostStopReason::Error) {
        host.state = RdnHostState::Error;
    } else {
        host.state = RdnHostState::Stopped;
    }
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

fn fail_host_network_recovery(host: &mut RdnHost, detail: &str) -> i32 {
    host.registration_status = "degraded";
    // Network registration recovery is independent from the exact-epoch
    // sleep/wake state machine. Preserve Running so snapshot consumers do not
    // misclassify a registration failure as a wakelock recovery failure.
    host.recovery_state = HostRecoveryState::Running;
    host.state = RdnHostState::Error;
    host.last_error = Some(detail.to_owned());
    host.emit_snapshot_changed();
    RDN_HOST_ERR_INTERNAL
}

fn is_next_network_path_generation(current: u64, requested: u64) -> bool {
    requested != 0 && current.checked_add(1) == Some(requested)
}

/// Restart only the Rust-owned Rendezvous registration runtime after an
/// authoritative product network-path change. Success means the replacement
/// runtime was started as pending; a later snapshot must prove ready.
#[no_mangle]
pub unsafe extern "C" fn rdn_host_recover_network_path(
    host: *mut RdnHost,
    path_generation: u64,
) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_state != HostRecoveryState::Running
        || !matches!(host.state, RdnHostState::Starting | RdnHostState::Ready)
        || host.runtime.is_none()
    {
        return RDN_HOST_ERR_BAD_STATE;
    }
    if !is_next_network_path_generation(host.network_path_generation, path_generation) {
        return RDN_HOST_ERR_STALE_GENERATION;
    }

    // Commit the exact generation and withdraw the old ready projection before
    // stopping registration. Host identity/configuration and media/session
    // authorities stay bound to this RdnHost lifetime.
    host.network_path_generation = path_generation;
    host.registration_status = "pending";
    host.state = RdnHostState::Starting;
    host.last_error = None;
    host.emit_snapshot_changed();

    let mut runtime = host.runtime.take().unwrap();
    if !runtime.stop() {
        return fail_host_network_recovery(
            host,
            "registration.runtimeJoinFailedDuringNetworkRecovery",
        );
    }
    host.runtime = match HostRuntime::start(host.rendezvous_server.clone()) {
        Ok(runtime) => Some(runtime),
        Err(()) => {
            return fail_host_network_recovery(
                host,
                "registration.runtimeRestartFailedDuringNetworkRecovery",
            );
        }
    };
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

fn fail_host_sleep_recovery(host: &mut RdnHost, detail: &str) -> i32 {
    host.registration_status = "degraded";
    host.recovery_state = HostRecoveryState::Failed;
    host.state = RdnHostState::Error;
    host.last_error = Some(detail.to_owned());
    host.emit_snapshot_changed();
    RDN_HOST_ERR_INTERNAL
}

fn is_next_recovery_epoch(current: u64, requested: u64) -> bool {
    requested != 0 && current.checked_add(1) == Some(requested)
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_begin_sleep(host: *mut RdnHost, epoch: u64) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_state != HostRecoveryState::Running
        || !matches!(host.state, RdnHostState::Starting | RdnHostState::Ready)
        || host.runtime.is_none()
    {
        return RDN_HOST_ERR_BAD_STATE;
    }
    if !is_next_recovery_epoch(host.recovery_epoch, epoch) {
        return RDN_HOST_ERR_STALE_EPOCH;
    }

    host.recovery_epoch = epoch;
    host.recovery_state = HostRecoveryState::Suspending;
    host.registration_status = "suspending";
    host.state = RdnHostState::Starting;
    host.runtime.as_ref().unwrap().request_stop();
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_finish_sleep(host: *mut RdnHost, epoch: u64) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_epoch != epoch {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    if host.recovery_state != HostRecoveryState::Suspending {
        return RDN_HOST_ERR_BAD_STATE;
    }
    let Some(mut runtime) = host.runtime.take() else {
        return fail_host_sleep_recovery(host, "registration.runtimeMissingDuringSleep");
    };
    if !runtime.join() {
        return fail_host_sleep_recovery(host, "registration.runtimeJoinFailedDuringSleep");
    }
    if !crate::server::native_host_suspend_wakelock(epoch) {
        return fail_host_sleep_recovery(host, "power.wakelockSuspendFailed");
    }

    host.registration_status = "suspended";
    host.recovery_state = HostRecoveryState::Suspended;
    host.state = RdnHostState::Starting;
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_resume_after_wake(host: *mut RdnHost, epoch: u64) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_epoch != epoch {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    if host.recovery_state != HostRecoveryState::Suspended || host.runtime.is_some() {
        return RDN_HOST_ERR_BAD_STATE;
    }

    host.recovery_state = HostRecoveryState::Resuming;
    host.registration_status = "pending";
    host.state = RdnHostState::Starting;
    if !crate::server::native_host_resume_wakelock(epoch) {
        return fail_host_sleep_recovery(host, "power.wakelockResumeFailed");
    }
    host.runtime = match HostRuntime::start(host.rendezvous_server.clone()) {
        Ok(runtime) => Some(runtime),
        Err(()) => {
            return fail_host_sleep_recovery(host, "registration.runtimeResumeFailed");
        }
    };
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

fn fail_host_after_password_persistence_mismatch(host: &mut RdnHost) {
    // Config::set_permanent_password cannot report confy's write error. Once
    // readback proves that the in-memory verifier/salt is not durable, stop
    // every active route before reporting the terminal storage state. This
    // prevents a running Host from authenticating against ephemeral state.
    unbind_media_host();
    if let Some(mut runtime) = host.runtime.take() {
        let _ = runtime.stop();
    }
    password_security::update_temporary_password();
    host.reveal_temporary_password = false;
    host.registration_status = "degraded";
    host.state = RdnHostState::Error;
    host.last_error = Some("configuration.passwordPersistenceFailed".to_owned());
    host.emit_snapshot_changed();
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

fn session_connection_id(envelope: &Value) -> Result<&str, i32> {
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

fn handle_session_command(
    host: &mut RdnHost,
    command_id: &str,
    command: NativeSessionCommand,
    envelope: &Value,
) -> i32 {
    let connection_id = match session_connection_id(envelope) {
        Ok(value) => value,
        Err(code) => {
            host.emit_command_result(command_id, "rejected", "session-command-invalid");
            return code;
        }
    };
    let expected_prefix = format!("{}:", host.instance_id);
    if !connection_id.starts_with(&expected_prefix) {
        host.emit_command_result(command_id, "rejected", "session-not-found");
        return RDN_HOST_ERR_SESSION_NOT_FOUND;
    }

    match SESSION_BROKER
        .lock()
        .unwrap()
        .command(connection_id, command)
    {
        NativeSessionCommandResult::Queued => {
            let detail = match command {
                NativeSessionCommand::DisableInput => "session-input-disable-queued",
                NativeSessionCommand::DisableClipboardRead => {
                    "session-clipboard-read-disable-queued"
                }
                NativeSessionCommand::DisableClipboardWrite => {
                    "session-clipboard-write-disable-queued"
                }
                NativeSessionCommand::DisableClipboard => "session-clipboard-disable-queued",
                NativeSessionCommand::DisableAudio => "session-audio-disable-queued",
                NativeSessionCommand::Disconnect => "session-disconnect-queued",
            };
            host.emit_command_result(command_id, "ok", detail);
            RDN_HOST_OK
        }
        NativeSessionCommandResult::NoChange => {
            let detail = match command {
                NativeSessionCommand::DisableInput => "session-input-already-disabled",
                NativeSessionCommand::DisableClipboardRead => {
                    "session-clipboard-read-already-disabled"
                }
                NativeSessionCommand::DisableClipboardWrite => {
                    "session-clipboard-write-already-disabled"
                }
                NativeSessionCommand::DisableClipboard => "session-clipboard-already-disabled",
                NativeSessionCommand::DisableAudio => "session-audio-already-disabled",
                NativeSessionCommand::Disconnect => "session-disconnect-already-requested",
            };
            host.emit_command_result(command_id, "ok", detail);
            RDN_HOST_OK
        }
        NativeSessionCommandResult::NotFound => {
            host.emit_command_result(command_id, "rejected", "session-not-found");
            RDN_HOST_ERR_SESSION_NOT_FOUND
        }
        NativeSessionCommandResult::Stale => {
            host.emit_command_result(command_id, "rejected", "session-stale");
            RDN_HOST_ERR_SESSION_STALE
        }
        NativeSessionCommandResult::Unavailable => {
            host.emit_command_result(command_id, "error", "session-command-unavailable");
            RDN_HOST_ERR_SESSION_COMMAND_UNAVAILABLE
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
                if verify_host_password_storage().is_err() {
                    host.emit_command_result(
                        command_id,
                        "error",
                        "permanent-password-storage-failed",
                    );
                    fail_host_after_password_persistence_mismatch(host);
                    return RDN_HOST_ERR_STORAGE;
                }
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
        "disableInputForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableInput,
            envelope,
        ),
        "disableClipboardForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableClipboard,
            envelope,
        ),
        "disableClipboardReadForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableClipboardRead,
            envelope,
        ),
        "disableClipboardWriteForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableClipboardWrite,
            envelope,
        ),
        "disableAudioForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableAudio,
            envelope,
        ),
        "disconnectSession" => {
            handle_session_command(host, command_id, NativeSessionCommand::Disconnect, envelope)
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
    if verify_host_password_storage().is_err() {
        host.emit_command_result(&command_id, "error", "permanent-password-storage-failed");
        fail_host_after_password_persistence_mismatch(host);
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
    // Recheck the same Rust Aqua authority at the final encoded admission
    // boundary. This prevents a route-loop acknowledgement wait from allowing
    // post-transition payload copies or queue insertion.
    if !native_host_session_is_available() {
        return RDN_HOST_ERR_BAD_STATE;
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
    use std::{
        ffi::CString,
        fs,
        path::{Path, PathBuf},
        sync::atomic::AtomicU64,
    };

    #[cfg(unix)]
    use std::os::unix::fs::{symlink, PermissionsExt};

    static MEDIA_BROKER_TEST_LOCK: Mutex<()> = Mutex::new(());
    static PASSWORD_COMMAND_TEST_LOCK: Mutex<()> = Mutex::new(());
    static HOST_STORAGE_FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    #[cfg(unix)]
    struct HostStorageFixture {
        root: PathBuf,
        identity: PathBuf,
        options: PathBuf,
    }

    #[cfg(unix)]
    impl HostStorageFixture {
        fn new() -> Self {
            let sequence = HOST_STORAGE_FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "farpane-host-storage-preflight-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&root).expect("create storage fixture");
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
                .expect("secure storage fixture");
            Self {
                identity: root.join("FarPaneHost.toml"),
                options: root.join("FarPaneHost2.toml"),
                root,
            }
        }

        fn write_private(path: &Path, bytes: &[u8]) {
            fs::write(path, bytes).expect("write storage fixture document");
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))
                .expect("secure storage fixture document");
        }

        fn write_valid_documents(&self) -> (Vec<u8>, Vec<u8>) {
            let identity = toml::to_string(&config::Config::default())
                .expect("serialize identity fixture")
                .into_bytes();
            let options = toml::to_string(&config::Config2::default())
                .expect("serialize options fixture")
                .into_bytes();
            Self::write_private(&self.identity, &identity);
            Self::write_private(&self.options, &options);
            (identity, options)
        }

        fn write_startup_documents(
            &self,
            rendezvous_server: &str,
            relay_server: &str,
            server_public_key: &str,
        ) -> (Vec<u8>, Vec<u8>) {
            let identity = b"enc_id = \"opaque-encrypted-id\"\n".to_vec();
            let mut config = config::Config2::default();
            config.options.insert(
                "custom-rendezvous-server".to_owned(),
                rendezvous_server.to_owned(),
            );
            if !relay_server.is_empty() {
                config
                    .options
                    .insert("relay-server".to_owned(), relay_server.to_owned());
            }
            config
                .options
                .insert("key".to_owned(), server_public_key.to_owned());
            config.options.insert(
                config::keys::OPTION_KEEP_AWAKE_DURING_INCOMING_SESSIONS.to_owned(),
                "Y".to_owned(),
            );
            config.options.insert(
                config::keys::OPTION_ENABLE_CLIPBOARD.to_owned(),
                "N".to_owned(),
            );
            for key in NATIVE_HOST_ALWAYS_DISABLED_OPTION_KEYS {
                config.options.insert(key.to_owned(), "N".to_owned());
            }
            let options = toml::to_string(&config)
                .expect("serialize startup options fixture")
                .into_bytes();
            Self::write_private(&self.identity, &identity);
            Self::write_private(&self.options, &options);
            (identity, options)
        }

        fn write_password_documents(
            &self,
            password_storage: &str,
            password_salt: &str,
        ) -> (Vec<u8>, Vec<u8>) {
            let identity = format!(
                "enc_id = \"opaque-encrypted-id\"\npassword = {password_storage:?}\nsalt = {password_salt:?}\n"
            )
            .into_bytes();
            let options = toml::to_string(&config::Config2::default())
                .expect("serialize password options fixture")
                .into_bytes();
            Self::write_private(&self.identity, &identity);
            Self::write_private(&self.options, &options);
            (identity, options)
        }
    }

    #[cfg(unix)]
    impl Drop for HostStorageFixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn host_runtime_reconnect_backoff_grows_caps_and_resets_after_stability() {
        let mut backoff = HostRuntimeReconnectBackoff::default();
        let short_connection = Duration::from_millis(1);
        let maximum_jitter_samples = [62, 125, 250, 500, 1_000, 1_250, 1_250, 1_250];
        let delays: Vec<u64> = maximum_jitter_samples
            .into_iter()
            .map(|jitter| {
                backoff
                    .delay_after_exit(short_connection, jitter)
                    .as_millis() as u64
            })
            .collect();
        assert_eq!(delays, [312, 625, 1_250, 2_500, 5_000, 5_000, 5_000, 5_000]);
        assert!(delays
            .iter()
            .all(|delay| *delay <= HOST_RUNTIME_RECONNECT_MAX_DELAY_MS));

        assert_eq!(
            backoff.delay_after_exit(
                Duration::from_millis(HOST_RUNTIME_RECONNECT_STABLE_CONNECTION_MS),
                0,
            ),
            Duration::from_millis(HOST_RUNTIME_RECONNECT_BASE_DELAY_MS)
        );
        assert_eq!(
            backoff.delay_after_exit(short_connection, 0),
            Duration::from_millis(HOST_RUNTIME_RECONNECT_BASE_DELAY_MS * 2)
        );
    }

    #[test]
    fn host_runtime_reconnect_wait_is_bounded_and_stop_interruptible() {
        let runtime = hbb_common::tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .expect("build reconnect wait runtime");
        runtime.block_on(async {
            let stop_requested = Arc::new(AtomicBool::new(false));
            let setter = stop_requested.clone();
            hbb_common::tokio::spawn(async move {
                hbb_common::tokio::time::sleep(Duration::from_millis(5)).await;
                setter.store(true, Ordering::Release);
            });
            let started = Instant::now();
            assert!(!wait_for_host_runtime_retry(&stop_requested, Duration::from_secs(5)).await);
            assert!(started.elapsed() < Duration::from_secs(1));

            stop_requested.store(false, Ordering::Release);
            assert!(wait_for_host_runtime_retry(&stop_requested, Duration::ZERO).await);
        });
    }

    #[test]
    fn host_recovery_epoch_is_strictly_sequential_and_exhaustion_safe() {
        assert!(is_next_recovery_epoch(0, 1));
        assert!(is_next_recovery_epoch(41, 42));
        assert!(!is_next_recovery_epoch(0, 0));
        assert!(!is_next_recovery_epoch(1, 1));
        assert!(!is_next_recovery_epoch(1, 3));
        assert!(!is_next_recovery_epoch(u64::MAX, 0));
        assert!(!is_next_recovery_epoch(u64::MAX, u64::MAX));
    }

    #[test]
    fn native_media_epoch_is_monotonic_and_exhaustion_safe() {
        let counter = AtomicU64::new(1);
        assert_eq!(next_native_media_epoch(&counter), Some(1));
        assert_eq!(next_native_media_epoch(&counter), Some(2));

        let last = AtomicU64::new(u64::MAX - 1);
        assert_eq!(next_native_media_epoch(&last), Some(u64::MAX - 1));
        assert_eq!(next_native_media_epoch(&last), None);
        assert_eq!(next_native_media_epoch(&last), None);

        let exhausted = AtomicU64::new(u64::MAX);
        assert_eq!(next_native_media_epoch(&exhausted), None);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_allows_first_start_without_writing() {
        let missing_root = std::env::temp_dir().join(format!(
            "farpane-host-storage-missing-{}-{}",
            std::process::id(),
            HOST_STORAGE_FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let identity = missing_root.join("FarPaneHost.toml");
        let options = missing_root.join("FarPaneHost2.toml");
        assert_eq!(preflight_host_storage_paths(&identity, &options), Ok(()));
        assert!(!missing_root.exists());

        let fixture = HostStorageFixture::new();
        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Ok(())
        );
        assert_eq!(fs::read_dir(&fixture.root).unwrap().count(), 0);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_accepts_valid_private_toml_without_mutation() {
        let fixture = HostStorageFixture::new();
        let (identity, options) = fixture.write_valid_documents();

        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_accepts_exact_start_projection_without_mutation() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "127.0.0.1:21117";
        let server_public_key = "synthetic-public-key";
        let (identity, options) =
            fixture.write_startup_documents(rendezvous_server, relay_server, server_public_key);

        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardPolicy::default(),
            ),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_accepts_explicit_clipboard_opt_in_only() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "";
        let server_public_key = "synthetic-public-key";
        let (identity, options) =
            fixture.write_startup_documents(rendezvous_server, relay_server, server_public_key);
        let mut config: config::Config2 =
            toml::from_str(std::str::from_utf8(&options).unwrap()).unwrap();
        config.options.insert(
            config::keys::OPTION_ENABLE_CLIPBOARD.to_owned(),
            "Y".to_owned(),
        );
        let enabled_options = toml::to_string(&config).unwrap().into_bytes();
        HostStorageFixture::write_private(&fixture.options, &enabled_options);

        for policy in [
            NativeClipboardPolicy::new(true, false),
            NativeClipboardPolicy::new(false, true),
            NativeClipboardPolicy::new(true, true),
        ] {
            assert_eq!(
                verify_host_start_storage_paths(
                    &fixture.identity,
                    &fixture.options,
                    rendezvous_server,
                    relay_server,
                    server_public_key,
                    policy,
                ),
                Ok(())
            );
        }
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardPolicy::default(),
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), enabled_options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_rejects_missing_or_stale_start_projection() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "";
        let server_public_key = "synthetic-public-key";
        let (identity, options) =
            fixture.write_startup_documents(rendezvous_server, relay_server, server_public_key);

        fs::remove_file(&fixture.identity).unwrap();
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardPolicy::default(),
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert!(!fixture.identity.exists());
        HostStorageFixture::write_private(&fixture.identity, &identity);

        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                "127.0.0.1:21118",
                relay_server,
                server_public_key,
                NativeClipboardPolicy::default(),
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);

        let mut config: config::Config2 =
            toml::from_str(std::str::from_utf8(&options).unwrap()).unwrap();
        config.options.remove(config::keys::OPTION_ENABLE_CLIPBOARD);
        HostStorageFixture::write_private(
            &fixture.options,
            toml::to_string(&config).unwrap().as_bytes(),
        );
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardPolicy::default(),
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
    }

    #[test]
    fn native_host_optional_data_capabilities_require_explicit_clipboard_policy() {
        assert_eq!(
            NATIVE_HOST_ALWAYS_DISABLED_OPTION_KEYS,
            [
                config::keys::OPTION_ENABLE_FILE_TRANSFER,
                config::keys::OPTION_ENABLE_AUDIO,
            ]
        );
        assert!(NATIVE_HOST_ALWAYS_DISABLED_OPTION_KEYS
            .iter()
            .all(|key| key.starts_with("enable-")));
        assert!(NATIVE_HOST_ALWAYS_DISABLED_OPTION_KEYS
            .iter()
            .all(|key| !config::option2bool(key, "N")));
        assert_eq!(
            native_host_clipboard_option(NativeClipboardPolicy::default()),
            "N"
        );
        assert_eq!(
            native_host_clipboard_option(NativeClipboardPolicy::new(true, false)),
            "Y"
        );
        assert_eq!(
            native_host_clipboard_option(NativeClipboardPolicy::new(false, true)),
            "Y"
        );
        assert_eq!(
            native_host_clipboard_option(NativeClipboardPolicy::new(true, true)),
            "Y"
        );
    }

    #[cfg(unix)]
    #[test]
    fn host_password_storage_readback_accepts_exact_set_and_clear_without_mutation() {
        let fixture = HostStorageFixture::new();
        let storage = "synthetic-verifier";
        let salt = "synthetic-salt";
        let (identity, options) = fixture.write_password_documents(storage, salt);

        assert_eq!(
            verify_host_password_storage_paths(&fixture.identity, &fixture.options, storage, salt,),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);

        let (cleared_identity, cleared_options) = fixture.write_password_documents("", salt);
        assert_eq!(
            verify_host_password_storage_paths(&fixture.identity, &fixture.options, "", salt,),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), cleared_identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), cleared_options);
    }

    #[cfg(unix)]
    #[test]
    fn host_password_storage_readback_rejects_stale_verifier_or_salt_without_mutation() {
        let fixture = HostStorageFixture::new();
        let (identity, options) =
            fixture.write_password_documents("persisted-verifier", "persisted-salt");

        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "new-verifier",
                "persisted-salt",
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "persisted-verifier",
                "new-salt",
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "",
                "persisted-salt",
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_password_storage_readback_rejects_wrong_typed_or_unknown_identity_fields() {
        let fixture = HostStorageFixture::new();
        let (_, options) = fixture.write_password_documents("persisted-verifier", "salt");
        let wrong_type = b"enc_id = \"opaque\"\npassword = 1\nsalt = \"salt\"\n";
        HostStorageFixture::write_private(&fixture.identity, wrong_type);
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "persisted-verifier",
                "salt",
            ),
            Err(HostStoragePreflightError::InvalidToml)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), wrong_type);

        let unknown = b"enc_id = \"opaque\"\npassword = \"persisted-verifier\"\nsalt = \"salt\"\nforeign = true\n";
        HostStorageFixture::write_private(&fixture.identity, unknown);
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "persisted-verifier",
                "salt",
            ),
            Err(HostStoragePreflightError::InvalidToml)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), unknown);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_preserves_malformed_documents() {
        let fixture = HostStorageFixture::new();
        let (valid_identity, _) = fixture.write_valid_documents();
        let malformed = b"not-toml = [";

        HostStorageFixture::write_private(&fixture.identity, malformed);
        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Err(HostStoragePreflightError::InvalidToml)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), malformed);

        HostStorageFixture::write_private(&fixture.identity, &valid_identity);
        HostStorageFixture::write_private(&fixture.options, malformed);
        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Err(HostStoragePreflightError::InvalidToml)
        );
        assert_eq!(fs::read(&fixture.options).unwrap(), malformed);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_rejects_unsafe_file_shapes() {
        let loose = HostStorageFixture::new();
        loose.write_valid_documents();
        fs::set_permissions(&loose.identity, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&loose.identity, &loose.options),
            Err(HostStoragePreflightError::UnsafeFile)
        );

        let linked = HostStorageFixture::new();
        let (_, options) = linked.write_valid_documents();
        fs::remove_file(&linked.identity).unwrap();
        let seed = linked.root.join("identity-seed.toml");
        HostStorageFixture::write_private(&seed, &options);
        fs::hard_link(&seed, &linked.identity).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&linked.identity, &linked.options),
            Err(HostStoragePreflightError::UnsafeFile)
        );

        let symbolic = HostStorageFixture::new();
        symbolic.write_valid_documents();
        let target = symbolic.root.join("identity-target.toml");
        HostStorageFixture::write_private(&target, b"id = \"safe\"\n");
        fs::remove_file(&symbolic.identity).unwrap();
        symlink(&target, &symbolic.identity).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&symbolic.identity, &symbolic.options),
            Err(HostStoragePreflightError::OpenFile)
        );

        let oversized = HostStorageFixture::new();
        oversized.write_valid_documents();
        HostStorageFixture::write_private(
            &oversized.identity,
            &vec![b'a'; MAX_HOST_CONFIG_BYTES + 1],
        );
        assert_eq!(
            preflight_host_storage_paths(&oversized.identity, &oversized.options),
            Err(HostStoragePreflightError::UnsafeFile)
        );

        let nonregular = HostStorageFixture::new();
        nonregular.write_valid_documents();
        fs::remove_file(&nonregular.identity).unwrap();
        fs::create_dir(&nonregular.identity).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&nonregular.identity, &nonregular.options),
            Err(HostStoragePreflightError::UnsafeFile)
        );
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_rejects_writable_directory() {
        let fixture = HostStorageFixture::new();
        fixture.write_valid_documents();
        fs::set_permissions(&fixture.root, fs::Permissions::from_mode(0o770)).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Err(HostStoragePreflightError::UnsafeDirectory)
        );
    }

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
            recovery_epoch: 0,
            recovery_state: HostRecoveryState::Running,
            network_path_generation: 0,
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
            clipboard_policy: NativeClipboardPolicy::default(),
            runtime: None,
        }
    }

    #[test]
    fn native_host_session_availability_tuple_is_exact_and_fail_closed() {
        assert_eq!(
            native_host_session_availability_payload(true),
            ("available", None)
        );
        assert_eq!(
            native_host_session_availability_payload(false),
            ("limited", Some("sessionUnavailable"))
        );

        let mut host = ready_test_host("session-availability-host");
        let snapshot = host.snapshot_json();
        match snapshot["sessionAvailability"].as_str() {
            Some("available") => assert!(snapshot["sessionUnavailableReason"].is_null()),
            Some("limited") => {
                assert_eq!(snapshot["sessionUnavailableReason"], "sessionUnavailable")
            }
            value => panic!("unexpected session availability: {value:?}"),
        }
    }

    #[test]
    fn network_path_recovery_admission_is_exact_generation_and_fail_closed() {
        assert!(!is_next_network_path_generation(0, 0));
        assert!(is_next_network_path_generation(0, 1));
        assert!(!is_next_network_path_generation(7, 7));
        assert!(!is_next_network_path_generation(7, 9));
        assert!(!is_next_network_path_generation(u64::MAX, 0));
        assert!(!is_next_network_path_generation(u64::MAX, u64::MAX));

        let mut host = ready_test_host("network-generation-host");
        host.network_path_generation = 7;
        host.runtime = Some(HostRuntime {
            stop_requested: Arc::new(AtomicBool::new(false)),
            finished: Arc::new(AtomicBool::new(false)),
            thread: None,
        });
        assert_eq!(
            unsafe { rdn_host_recover_network_path(std::ptr::null_mut(), 8) },
            RDN_HOST_ERR_INVALID_ARG
        );
        for generation in [0, 7, 9, u64::MAX] {
            assert_eq!(
                unsafe { rdn_host_recover_network_path(&mut host, generation) },
                RDN_HOST_ERR_STALE_GENERATION
            );
            assert_eq!(host.network_path_generation, 7);
            assert_eq!(state_name(host.state), "ready");
            assert_eq!(host.registration_status, "ready");
            assert!(host.runtime.is_some());
        }

        host.recovery_state = HostRecoveryState::Suspended;
        host.state = RdnHostState::Starting;
        assert_eq!(
            unsafe { rdn_host_recover_network_path(&mut host, 8) },
            RDN_HOST_ERR_BAD_STATE
        );
        assert_eq!(host.network_path_generation, 7);
        assert!(host.runtime.is_some());
    }

    #[test]
    fn network_path_recovery_failure_is_terminal_but_not_sleep_failure() {
        let mut host = ready_test_host("network-failure-host");
        assert_eq!(
            fail_host_network_recovery(
                &mut host,
                "registration.runtimeRestartFailedDuringNetworkRecovery",
            ),
            RDN_HOST_ERR_INTERNAL
        );
        assert_eq!(state_name(host.state), "error");
        assert_eq!(host.registration_status, "degraded");
        assert_eq!(host.recovery_state, HostRecoveryState::Running);
        assert_eq!(host.recovery_epoch, 0);
        assert_eq!(host.network_path_generation, 0);
        assert_eq!(
            host.last_error.as_deref(),
            Some("registration.runtimeRestartFailedDuringNetworkRecovery")
        );
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
                input_availability: if active_capabilities.control_keyboard_mouse {
                    NativeSessionInputAvailability::available()
                } else {
                    NativeSessionInputAvailability::disabled(
                        NativeSessionInputUnavailableReason::LocalPolicyDisabled,
                    )
                },
            },
            command_sender,
            disconnect_requested: false,
        }
    }

    #[test]
    fn native_clipboard_policy_represents_read_and_write_independently() {
        let disabled = NativeClipboardPolicy::new(false, false);
        let read_only = NativeClipboardPolicy::new(true, false);
        let write_only = NativeClipboardPolicy::new(false, true);
        let bidirectional = NativeClipboardPolicy::new(true, true);

        for (policy, expected_names) in [
            (disabled, vec!["viewDisplay"]),
            (read_only, vec!["viewDisplay", "readClipboard"]),
            (write_only, vec!["viewDisplay", "writeClipboard"]),
            (
                bidirectional,
                vec!["viewDisplay", "readClipboard", "writeClipboard"],
            ),
        ] {
            assert_eq!(
                NativeSessionCapabilities::with_clipboard_policy(false, policy, false).names(),
                expected_names
            );
        }

        assert!(disabled.is_subset_of(read_only));
        assert!(read_only.is_subset_of(bidirectional));
        assert!(write_only.is_subset_of(bidirectional));
        assert!(!read_only.is_subset_of(write_only));
        assert!(!write_only.is_subset_of(read_only));
        assert_eq!(
            NativeSessionCapabilities::new(false, true, false),
            NativeSessionCapabilities::with_clipboard_policy(false, bidirectional, false,)
        );
    }

    fn clipboard_fixture(content: Vec<u8>, compress: bool, format: ClipboardFormat) -> Clipboard {
        Clipboard {
            compress,
            content: content.into(),
            format: format.into(),
            ..Default::default()
        }
    }

    #[test]
    fn native_clipboard_data_plane_gates_read_and_write_independently() {
        let text = clipboard_fixture(b"small text".to_vec(), false, ClipboardFormat::Text);
        let clipboards = std::slice::from_ref(&text);
        let read_only = NativeClipboardPolicy::new(true, false);
        let write_only = NativeClipboardPolicy::new(false, true);

        let non_clipboard_message = Message::new();
        assert!(native_host_outgoing_clipboard_message_is_allowed(
            &non_clipboard_message,
            false,
        ));
        let mut clipboard_message = Message::new();
        clipboard_message.set_clipboard(text.clone());
        assert!(native_host_outgoing_clipboard_message_is_allowed(
            &clipboard_message,
            true,
        ));
        assert!(!native_host_outgoing_clipboard_message_is_allowed(
            &clipboard_message,
            false,
        ));

        assert!(native_host_clipboard_direction_allows(
            read_only,
            NativeClipboardDirection::RemoteRead,
            clipboards,
        ));
        assert!(!native_host_clipboard_direction_allows(
            read_only,
            NativeClipboardDirection::RemoteWrite,
            clipboards,
        ));
        assert!(!native_host_clipboard_direction_allows(
            write_only,
            NativeClipboardDirection::RemoteRead,
            clipboards,
        ));
        assert!(native_host_clipboard_direction_allows(
            write_only,
            NativeClipboardDirection::RemoteWrite,
            clipboards,
        ));
        assert!(!native_host_clipboard_direction_allows(
            NativeClipboardPolicy::new(true, true),
            NativeClipboardDirection::RemoteRead,
            &[text.clone(), text],
        ));
    }

    #[test]
    fn native_clipboard_data_plane_accepts_only_bounded_utf8_plain_text() {
        let at_limit = vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES];
        assert!(native_host_small_text_clipboard(&clipboard_fixture(
            at_limit.clone(),
            false,
            ClipboardFormat::Text,
        )));
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1],
            false,
            ClipboardFormat::Text,
        )));

        let compressed_at_limit = hbb_common::compress::compress(&at_limit);
        assert!(native_host_small_text_clipboard(&clipboard_fixture(
            compressed_at_limit,
            true,
            ClipboardFormat::Text,
        )));
        let compressed_over_limit =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1]);
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            compressed_over_limit,
            true,
            ClipboardFormat::Text,
        )));

        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            vec![0xff],
            false,
            ClipboardFormat::Text,
        )));
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            b"before\0after".to_vec(),
            false,
            ClipboardFormat::Text,
        )));
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            b"<b>rich</b>".to_vec(),
            false,
            ClipboardFormat::Html,
        )));
    }

    #[test]
    fn native_clipboard_payload_taxonomy_separates_inline_text_from_rich_transfer() {
        assert_eq!(
            native_host_clipboard_payload_disposition(&clipboard_fixture(
                b"small text".to_vec(),
                false,
                ClipboardFormat::Text,
            )),
            NativeClipboardPayloadDisposition::InlineSmallText
        );

        for format in [
            ClipboardFormat::Rtf,
            ClipboardFormat::Html,
            ClipboardFormat::ImagePng,
            ClipboardFormat::ImageSvg,
        ] {
            let rich = clipboard_fixture(b"rich payload".to_vec(), false, format);
            assert_eq!(
                native_host_clipboard_payload_disposition(&rich),
                NativeClipboardPayloadDisposition::IndependentTransferRequired
            );
            assert!(!native_host_clipboard_direction_allows(
                NativeClipboardPolicy::new(true, true),
                NativeClipboardDirection::RemoteRead,
                std::slice::from_ref(&rich),
            ));
            let mut message = Message::new();
            message.set_clipboard(rich);
            assert!(!native_host_outgoing_clipboard_message_is_allowed(
                &message, true,
            ));
        }

        let mut rgba = clipboard_fixture(vec![0, 0, 0, 255], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        assert_eq!(
            native_host_clipboard_payload_disposition(&rgba),
            NativeClipboardPayloadDisposition::IndependentTransferRequired
        );
        assert!(!native_host_clipboard_direction_allows(
            NativeClipboardPolicy::new(true, true),
            NativeClipboardDirection::RemoteWrite,
            std::slice::from_ref(&rgba),
        ));
        let mut rgba_message = Message::new();
        rgba_message.set_clipboard(rgba);
        assert!(!native_host_outgoing_clipboard_message_is_allowed(
            &rgba_message,
            true,
        ));

        let mut malformed_html =
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        malformed_html.width = 1;
        assert_eq!(
            native_host_clipboard_payload_disposition(&malformed_html),
            NativeClipboardPayloadDisposition::Reject
        );

        let mut special = clipboard_fixture(b"untrusted".to_vec(), false, ClipboardFormat::Special);
        special.special_name = "untrusted.remote.uti".to_owned();
        assert_eq!(
            native_host_clipboard_payload_disposition(&special),
            NativeClipboardPayloadDisposition::Reject
        );

        let mut unknown = clipboard_fixture(b"unknown".to_vec(), false, ClipboardFormat::Text);
        unknown.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert_eq!(
            native_host_clipboard_payload_disposition(&unknown),
            NativeClipboardPayloadDisposition::Reject
        );
    }

    #[test]
    fn native_rich_text_transfer_envelope_is_owned_bounded_and_strict() {
        for (format, expected) in [
            (ClipboardFormat::Rtf, NativeRichTextFormat::Rtf),
            (ClipboardFormat::Html, NativeRichTextFormat::Html),
        ] {
            let mut source = clipboard_fixture(b"rich text".to_vec(), false, format);
            let envelope = NativeRichTextTransferEnvelope::from_clipboard(&source).unwrap();
            source.content.clear();
            assert_eq!(envelope.format, expected);
            assert_eq!(envelope.payload, "rich text");
        }

        let at_limit = vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES];
        let envelope = NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
            at_limit.clone(),
            false,
            ClipboardFormat::Rtf,
        ))
        .unwrap();
        assert_eq!(envelope.payload.len(), MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES);

        let compressed_at_limit = hbb_common::compress::compress(&at_limit);
        let envelope = NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
            compressed_at_limit,
            true,
            ClipboardFormat::Html,
        ))
        .unwrap();
        assert_eq!(envelope.payload.len(), MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES);

        let compressed_over_limit =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES + 1]);
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                compressed_over_limit,
                true,
                ClipboardFormat::Rtf,
            ))
            .is_none()
        );
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES + 1],
                false,
                ClipboardFormat::Html,
            ))
            .is_none()
        );

        for content in [vec![0xff], b"before\0after".to_vec()] {
            assert!(
                NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                    content,
                    false,
                    ClipboardFormat::Html,
                ))
                .is_none()
            );
        }

        let mut wrong_metadata =
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        wrong_metadata.special_name = "public.html".to_owned();
        assert!(NativeRichTextTransferEnvelope::from_clipboard(&wrong_metadata).is_none());

        for (width, height) in [(1, 0), (0, 1)] {
            let mut wrong_dimensions =
                clipboard_fixture(b"{\\rtf1}".to_vec(), false, ClipboardFormat::Rtf);
            wrong_dimensions.width = width;
            wrong_dimensions.height = height;
            assert!(NativeRichTextTransferEnvelope::from_clipboard(&wrong_dimensions).is_none());
        }
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                Vec::new(),
                false,
                ClipboardFormat::Rtf,
            ))
            .is_none()
        );

        let mut unknown_format = clipboard_fixture(b"rich".to_vec(), false, ClipboardFormat::Rtf);
        unknown_format.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert!(NativeRichTextTransferEnvelope::from_clipboard(&unknown_format).is_none());
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                b"plain".to_vec(),
                false,
                ClipboardFormat::Text,
            ))
            .is_none()
        );
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
        let unavailable = NativeSessionInputAvailability::limited(
            NativeSessionInputUnavailableReason::SessionUnavailable,
        );
        assert!(broker
            .update_capabilities(9, revoked, unavailable)
            .is_none());
        assert_eq!(
            broker
                .update_capabilities(1, revoked, unavailable)
                .unwrap()
                .input_availability,
            unavailable
        );
        assert_eq!(broker.snapshot().unwrap().active_capabilities, revoked);
        let accessibility_denied = NativeSessionInputAvailability::limited(
            NativeSessionInputUnavailableReason::AccessibilityDenied,
        );
        assert_eq!(
            broker
                .update_capabilities(1, revoked, accessibility_denied)
                .unwrap()
                .input_availability,
            accessibility_denied
        );
        assert!(broker
            .update_capabilities(1, revoked, accessibility_denied)
            .is_none());
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
            NativeSessionInputAvailability::available(),
            first_sender,
        ));
        let active_snapshot = host.snapshot_json();
        assert_eq!(active_snapshot["schemaVersion"], SNAPSHOT_SCHEMA_VERSION);
        assert_eq!(active_snapshot["recoveryEpoch"], 0);
        assert_eq!(active_snapshot["recoveryStatus"], "running");
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
            active_snapshot["activeSession"]["inputAvailability"],
            "available"
        );
        assert!(active_snapshot["activeSession"]["inputUnavailableReason"].is_null());
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
            NativeSessionInputAvailability::limited(
                NativeSessionInputUnavailableReason::SessionUnavailable,
            ),
        );
        assert_eq!(
            host.snapshot_json()["activeSession"]["activeCapabilities"],
            json!(["viewDisplay", "readClipboard", "writeClipboard"])
        );
        assert_eq!(
            host.snapshot_json()["activeSession"]["inputAvailability"],
            "limited"
        );
        assert_eq!(
            host.snapshot_json()["activeSession"]["inputUnavailableReason"],
            "sessionUnavailable"
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
            NativeSessionInputAvailability::available(),
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
    fn native_active_session_commands_are_exact_scoped_and_fail_closed() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let events = Mutex::new(Vec::new());
        let mut host = ready_test_host("session-command-host");
        host.callbacks = RdnHostCallbacks {
            abi_version: HOST_ABI_VERSION,
            on_event: Some(collect_test_event),
            context: &events as *const Mutex<Vec<Value>> as *mut c_void,
        };
        bind_media_host(&host);
        let _guard = BoundMediaTestGuard;

        let initial = NativeSessionCapabilities::new(true, true, true);
        let (command_sender, mut command_receiver) = tokio::sync::mpsc::unbounded_channel();
        assert!(native_host_begin_session(
            17,
            "remote-id".to_owned(),
            "Remote Mac".to_owned(),
            "macOS".to_owned(),
            initial,
            initial,
            NativeSessionInputAvailability::available(),
            command_sender,
        ));

        let malformed = json!({
            "commandId": "session-malformed",
            "name": "disableInputForActiveSession",
            "connectionId": "session-command-host:17",
            "ignored": true,
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-malformed",
                "disableInputForActiveSession",
                &malformed,
            ),
            RDN_HOST_ERR_VALIDATION
        );
        assert!(command_receiver.try_recv().is_err());

        for (command_id, name, expected) in [
            (
                "session-input",
                "disableInputForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "keyboard".to_owned(),
                    enabled: false,
                },
            ),
            (
                "session-clipboard-read",
                "disableClipboardReadForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-read".to_owned(),
                    enabled: false,
                },
            ),
            (
                "session-clipboard-write",
                "disableClipboardWriteForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-write".to_owned(),
                    enabled: false,
                },
            ),
            (
                "session-clipboard",
                "disableClipboardForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard".to_owned(),
                    enabled: false,
                },
            ),
            (
                "session-audio",
                "disableAudioForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "audio".to_owned(),
                    enabled: false,
                },
            ),
        ] {
            let envelope = json!({
                "commandId": command_id,
                "name": name,
                "connectionId": "session-command-host:17",
            });
            assert_eq!(
                handle_command(&mut host, command_id, name, &envelope),
                RDN_HOST_OK
            );
            match (command_receiver.try_recv().unwrap(), expected) {
                (
                    crate::ipc::Data::SwitchPermission { name, enabled },
                    crate::ipc::Data::SwitchPermission {
                        name: expected_name,
                        enabled: expected_enabled,
                    },
                ) => {
                    assert_eq!(name, expected_name);
                    assert_eq!(enabled, expected_enabled);
                }
                _ => panic!("unexpected session permission command"),
            }
        }

        native_host_update_session_capabilities(
            17,
            NativeSessionCapabilities::with_clipboard_policy(
                true,
                NativeClipboardPolicy::new(false, true),
                true,
            ),
            NativeSessionInputAvailability::available(),
        );
        let read_already_disabled = json!({
            "commandId": "session-clipboard-read-already-disabled",
            "name": "disableClipboardReadForActiveSession",
            "connectionId": "session-command-host:17",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-clipboard-read-already-disabled",
                "disableClipboardReadForActiveSession",
                &read_already_disabled,
            ),
            RDN_HOST_OK
        );
        assert!(command_receiver.try_recv().is_err());

        let write_still_enabled = json!({
            "commandId": "session-clipboard-write-enabled",
            "name": "disableClipboardWriteForActiveSession",
            "connectionId": "session-command-host:17",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-clipboard-write-enabled",
                "disableClipboardWriteForActiveSession",
                &write_still_enabled,
            ),
            RDN_HOST_OK
        );
        assert!(matches!(
            command_receiver.try_recv(),
            Ok(crate::ipc::Data::SwitchPermission { name, enabled })
                if name == "clipboard-write" && !enabled
        ));

        native_host_update_session_capabilities(
            17,
            NativeSessionCapabilities::new(false, false, false),
            NativeSessionInputAvailability::disabled(
                NativeSessionInputUnavailableReason::LocalPolicyDisabled,
            ),
        );
        let already_disabled = json!({
            "commandId": "session-input-already-disabled",
            "name": "disableInputForActiveSession",
            "connectionId": "session-command-host:17",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-input-already-disabled",
                "disableInputForActiveSession",
                &already_disabled,
            ),
            RDN_HOST_OK
        );
        assert!(command_receiver.try_recv().is_err());

        let stale = json!({
            "commandId": "session-stale",
            "name": "disconnectSession",
            "connectionId": "session-command-host:18",
        });
        assert_eq!(
            handle_command(&mut host, "session-stale", "disconnectSession", &stale),
            RDN_HOST_ERR_SESSION_STALE
        );
        let foreign = json!({
            "commandId": "session-foreign",
            "name": "disconnectSession",
            "connectionId": "other-host:17",
        });
        assert_eq!(
            handle_command(&mut host, "session-foreign", "disconnectSession", &foreign),
            RDN_HOST_ERR_SESSION_NOT_FOUND
        );

        let disconnect = json!({
            "commandId": "session-disconnect",
            "name": "disconnectSession",
            "connectionId": "session-command-host:17",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-disconnect",
                "disconnectSession",
                &disconnect,
            ),
            RDN_HOST_OK
        );
        assert!(matches!(
            command_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));
        assert_eq!(
            handle_command(
                &mut host,
                "session-disconnect-again",
                "disconnectSession",
                &disconnect,
            ),
            RDN_HOST_OK
        );
        assert!(command_receiver.try_recv().is_err());

        native_host_end_session(17);
        assert_eq!(
            handle_command(&mut host, "session-ended", "disconnectSession", &disconnect,),
            RDN_HOST_ERR_SESSION_NOT_FOUND
        );

        let (dead_sender, dead_receiver) = tokio::sync::mpsc::unbounded_channel();
        drop(dead_receiver);
        assert!(native_host_begin_session(
            19,
            "remote-id".to_owned(),
            "Remote Mac".to_owned(),
            "macOS".to_owned(),
            initial,
            initial,
            NativeSessionInputAvailability::available(),
            dead_sender,
        ));
        let unavailable = json!({
            "commandId": "session-unavailable",
            "name": "disableInputForActiveSession",
            "connectionId": "session-command-host:19",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-unavailable",
                "disableInputForActiveSession",
                &unavailable,
            ),
            RDN_HOST_ERR_SESSION_COMMAND_UNAVAILABLE
        );
        native_host_end_session(19);
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
        assert_eq!(snapshot["authenticatedConnectionCount"], 0);
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
        let route = native_media_begin_route(0, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
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
        let route = native_media_begin_route(0, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
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

    #[test]
    fn display_reconfigure_provenance_is_exact_and_consumed_once() {
        let _serial = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        let events = Mutex::new(Vec::<Value>::new());
        let mut host = ready_test_host("display-provenance-host");
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

        let previous = native_media_begin_route(0, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
            .expect("initial route");
        assert_eq!(previous.display_revision, 1);
        native_media_mark_display_reconfigure(&previous).expect("display marker");
        assert!(native_media_mark_display_reconfigure(&previous).is_err());
        native_media_end_route(&previous);

        let replacement = native_media_begin_route(0, MEDIA_CODEC_H264, 1_280, 720, 30, 3_000_000)
            .expect("display replacement route");
        assert_eq!(replacement.display_revision, 2);
        assert!(replacement.connection_epoch > previous.connection_epoch);
        assert!(replacement.codec_epoch > previous.codec_epoch);

        native_media_end_route(&replacement);
        let generic_retry =
            native_media_begin_route(0, MEDIA_CODEC_H264, 1_280, 720, 30, 3_000_000)
                .expect("generic retry route");
        assert_eq!(generic_retry.display_revision, 2);

        let events = events.lock().unwrap();
        let started = events
            .iter()
            .filter(|event| event["eventType"] == "mediaDisplayReconfigureStarted")
            .collect::<Vec<_>>();
        assert_eq!(started.len(), 1);
        let marker = &started[0]["payload"];
        assert_eq!(marker["displayId"], 0);
        assert_eq!(marker["previousDisplayRevision"], 1);
        assert_eq!(marker["previousConnectionEpoch"], previous.connection_epoch);
        assert_eq!(marker["previousCodecEpoch"], previous.codec_epoch);
        assert!(marker["displayReconfigureGeneration"].as_u64().unwrap() > 0);

        let replacement_controls = events
            .iter()
            .filter(|event| {
                event["eventType"] == "mediaControl"
                    && event["payload"]["connectionEpoch"] == replacement.connection_epoch
                    && matches!(
                        event["payload"]["command"].as_str(),
                        Some("startCapture" | "reconfigure")
                    )
            })
            .collect::<Vec<_>>();
        assert_eq!(replacement_controls.len(), 2);
        for control in replacement_controls {
            assert_eq!(control["payload"]["displayRevision"], 2);
            assert_eq!(
                control["payload"]["displayReconfigure"]["displayReconfigureGeneration"],
                marker["displayReconfigureGeneration"]
            );
            assert_eq!(
                control["payload"]["displayReconfigure"]["previousDisplayRevision"],
                1
            );
            assert_eq!(
                control["payload"]["displayReconfigure"]["previousConnectionEpoch"],
                previous.connection_epoch
            );
            assert_eq!(
                control["payload"]["displayReconfigure"]["previousCodecEpoch"],
                previous.codec_epoch
            );
        }

        let generic_controls = events
            .iter()
            .filter(|event| {
                event["eventType"] == "mediaControl"
                    && event["payload"]["connectionEpoch"] == generic_retry.connection_epoch
            })
            .collect::<Vec<_>>();
        assert_eq!(generic_controls.len(), 2);
        assert!(generic_controls
            .iter()
            .all(|event| { event["payload"].get("displayReconfigure").is_none() }));
    }
}
