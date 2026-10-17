//! Small, versioned GUI/core contract. No UI, media, or network-core dependency.
pub mod clipboard;
pub mod clipboard_link;
pub mod clipboard_socket;
pub mod devices;
pub mod event_queue;
pub mod frame;
pub mod frame_socket;
pub mod sealed;
pub mod supervision;
pub mod telemetry;
pub mod transport;

use serde::{Deserialize, Serialize};
use std::fmt;

pub const VERSION: u32 = 1;
pub const MAX_MESSAGE: usize = 64 * 1024;
pub const MAX_EVENTS: usize = 128;

/// Serializes only onto the protected channel. Debug output never contains it.
#[derive(Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(transparent)]
pub struct Secret(pub String);
impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("[REDACTED]")
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Gui,
    Agent,
    Viewer,
    Config,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hello {
    pub version: u32,
    pub role: Role,
    pub release: String,
    pub session: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub id: u64,
    pub session: u64,
    pub generation: u64,
    pub command: Command,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConfigResponse {
    pub request: u64,
    pub snapshot: Option<Snapshot>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub enum Command {
    Snapshot,
    Subscribe,
    SetHost {
        enabled: bool,
        revision: u64,
    },
    SetServer {
        settings: ServerSettings,
        revision: u64,
    },
    SetAuthentication {
        mode: Authentication,
        password: Option<Secret>,
        revision: u64,
    },
    SetHostAudio {
        enabled: bool,
        source: String,
        microphone: bool,
        revision: u64,
    },
    SetHostFiles {
        enabled: bool,
        directory: String,
        confirm: bool,
        revision: u64,
    },
    SetHostClipboard {
        policy: clipboard::Policy,
        revision: u64,
    },
    RememberDevice {
        peer: String,
        server: ServerSettings,
        #[serde(default)]
        name: String,
        revision: u64,
    },
    SetDevice {
        peer: String,
        alias: String,
        favorite: bool,
        revision: u64,
    },
    ForgetDevice {
        peer: String,
        revision: u64,
    },
    SetGpu {
        enabled: bool,
        retry: bool,
        revision: u64,
    },
    Approve {
        connection: i32,
        permissions: Permissions,
    },
    Reject {
        connection: i32,
    },
    Revoke {
        connection: i32,
        permission: Permission,
    },
    DisconnectInbound {
        connection: i32,
    },
    Connect {
        peer: String,
        #[serde(default)]
        file_only: bool,
        password: Secret,
        receive_audio: bool,
        force_relay: bool,
        configuration: ViewerConfiguration,
        renderer: Renderer,
    },
    Password {
        password: Secret,
    },
    ConfirmInsecure {
        accept: bool,
    },
    TwoFactor {
        code: Secret,
    },
    Disconnect,
    Retry,
    SelectDisplay {
        index: i32,
    },
    RefreshFrame,
    Input(Input),
    SetClipboard {
        policy: clipboard::Policy,
    },
    SetAudio {
        enabled: bool,
    },
    Metrics {
        enabled: bool,
    },
    ListDirectory {
        path: String,
        page: u32,
        remote: bool,
    },
    Transfer {
        local: String,
        remote: String,
        upload: bool,
        overwrite: bool,
        #[serde(default)]
        directory: bool,
    },
    TransferFiles {
        local: Vec<String>,
        remote: String,
    },
    CancelTransfer {
        job: i32,
    },
    ConfirmTransfer {
        job: i32,
        accept: bool,
        #[serde(default)]
        overwrite: bool,
    },
}

impl Command {
    pub fn allowed_for(&self, role: Role) -> bool {
        match self {
            Self::Snapshot => matches!(role, Role::Agent | Role::Viewer | Role::Config),
            Self::Subscribe => matches!(role, Role::Agent | Role::Viewer),
            Self::SetHost { .. }
            | Self::SetServer { .. }
            | Self::SetAuthentication { .. }
            | Self::SetHostAudio { .. }
            | Self::SetHostFiles { .. }
            | Self::SetHostClipboard { .. }
            | Self::RememberDevice { .. }
            | Self::SetDevice { .. }
            | Self::ForgetDevice { .. }
            | Self::SetGpu { .. } => matches!(role, Role::Agent | Role::Config),
            Self::Approve { .. }
            | Self::Reject { .. }
            | Self::Revoke { .. }
            | Self::DisconnectInbound { .. } => role == Role::Agent,
            Self::ConfirmTransfer { .. } | Self::CancelTransfer { .. } => {
                matches!(role, Role::Agent | Role::Viewer)
            }
            _ => role == Role::Viewer,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ServerSettings {
    pub rendezvous: String,
    pub relay: String,
    pub public_key: String,
    pub force_relay: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ViewerConfiguration {
    pub local_id: String,
    pub server: ServerSettings,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Renderer {
    /// Empty means explicit software compatibility. Never assume DMA-BUF import.
    pub formats: Vec<ImportFormat>,
    pub software: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ImportFormat {
    pub format: u32,
    pub modifier: u64,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Authentication {
    #[default]
    Permanent,
    Temporary,
    Both,
    Approval,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Permissions {
    pub keyboard: bool,
    pub clipboard: bool,
    pub audio: bool,
    pub file: bool,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Permission {
    Keyboard,
    Clipboard,
    Audio,
    File,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SharingSettings {
    pub permissions: Permissions,
    pub clipboard: clipboard::Policy,
    pub receive_directory: String,
    pub confirm_files: bool,
    pub audio_source: String,
    pub microphone: bool,
    pub background: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub enum Input {
    Pointer {
        x: i32,
        y: i32,
        /// One changed button: left=1, right=2, middle=4, back=8, forward=16; motion=0.
        buttons: u8,
        action: PointerAction,
        modifiers: u32,
    },
    Scroll {
        x: f64,
        y: f64,
        precise: bool,
        modifiers: u32,
    },
    Key {
        keyval: u32,
        hardware_code: u32,
        pressed: bool,
        /// Shift=1, Control=2, Alt=4, Meta=8, CapsLock=16, NumLock=32.
        modifiers: u32,
    },
    Text {
        text: String,
    },
    ReleaseAll,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PointerAction {
    Move,
    Press,
    Release,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Event {
    pub sequence: u64,
    pub session: u64,
    pub generation: u64,
    pub event: EventKind,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub enum EventKind {
    ConnectionEnded {
        retryable: bool,
    },
    Peer {
        name: String,
    },
    Snapshot(Snapshot),
    Reply {
        request: u64,
        revision: u64,
        error: Option<String>,
    },
    Phase {
        phase: Phase,
        detail: String,
    },
    Permissions(Permissions),
    AuthenticationChallenge {
        two_factor: bool,
        insecure: bool,
        detail: String,
    },
    Audio {
        status: String,
        detail: String,
        dropped: u64,
    },
    Media {
        backend: String,
        detail: String,
    },
    Cursor {
        id: u64,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        hot_x: i32,
        hot_y: i32,
        rgba: String,
        premultiplied: bool,
    },
    CursorPosition {
        x: i32,
        y: i32,
    },
    Displays {
        displays: Vec<Display>,
        selected: i32,
    },
    ClipboardPolicy {
        policy: clipboard::Policy,
        revision: u64,
    },
    ClipboardStatus {
        available: bool,
        detail: String,
    },
    Metrics(Metrics),
    Directory {
        path: String,
        page: u32,
        more: bool,
        entries: Vec<FileEntry>,
    },
    Transfer {
        job: i32,
        name: String,
        done: u64,
        total: u64,
        status: String,
        needs_confirmation: bool,
    },
    Log {
        level: String,
        message: String,
    },
    ResyncRequired,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    #[default]
    Home,
    Resolving,
    Connecting,
    Authenticating,
    PasswordRequired,
    AwaitingFrame,
    FilesReady,
    Streaming,
    Recovering,
    Ended,
    Failed,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub revision: u64,
    pub role: Option<Role>,
    pub local_id: String,
    pub host_enabled: bool,
    pub registered: bool,
    pub authentication: Authentication,
    pub permanent_password_set: bool,
    pub temporary_password: Option<Secret>,
    pub server: ServerSettings,
    pub sharing: SharingSettings,
    pub gpu_enabled: bool,
    pub media_backend: String,
    pub media_reason: String,
    pub inbound: Vec<Inbound>,
    pub capabilities: Vec<String>,
    pub unavailable: Vec<String>,
    #[serde(default)]
    pub devices: Vec<devices::Device>,
    #[serde(default)]
    pub audio_sources: Vec<AudioSource>,
    #[serde(default)]
    pub audio_error: String,
    #[serde(default)]
    pub clipboard_detail: String,
    #[serde(default)]
    pub desktop: DesktopStatus,
    #[serde(default)]
    pub audio_capture: String,
    #[serde(default)]
    pub audio_needs_selection: bool,
    #[serde(default)]
    pub file_tasks: Vec<FileTask>,
    #[serde(default)]
    pub recovery: RecoveryStatus,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryPhase {
    #[default]
    Unavailable,
    Disabled,
    Monitoring,
    Suspended,
    WaitingNetwork,
    Waiting,
    Registering,
    Ready,
    WaitingServer,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecoveryStatus {
    pub phase: RecoveryPhase,
    pub sleep_monitor: bool,
    pub network_monitor: bool,
    pub epoch: u64,
    pub attempt: u8,
    pub detail: String,
}
impl Default for RecoveryStatus {
    fn default() -> Self {
        Self {
            phase: RecoveryPhase::Unavailable,
            sleep_monitor: false,
            network_monitor: false,
            epoch: 0,
            attempt: 0,
            detail: "系统事件监听不可用，核心仍会自行重试连接".into(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopStatus {
    pub connected: bool,
    pub tray_registered: bool,
    pub notifications_available: bool,
    pub notification_actions: bool,
    pub detail: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileTask {
    pub job: i32,
    pub connection: i32,
    pub name: String,
    pub upload: bool,
    pub done: u64,
    pub total: u64,
    pub status: String,
    pub detail: String,
    pub needs_confirmation: bool,
    pub overwrite_required: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Inbound {
    pub id: i32,
    pub peer: String,
    pub name: String,
    pub authorized: bool,
    pub permissions: Permissions,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Display {
    pub index: i32,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub name: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct Metrics {
    pub received_packets: u64,
    pub received_bytes: u64,
    pub decoded_frames: u64,
    pub decode_call_ns: u64,
    pub packet_rate: Option<f32>,
    pub decode_fps: Option<f32>,
    pub receive_kib_per_sec: Option<f32>,
    pub decode_ms: Option<f32>,
    pub delay_ms: Option<u32>,
    pub delay_age_ms: Option<u64>,
    pub queue_bytes: u64,
    pub queued_groups: u32,
    pub leases: u32,
    pub skipped_display_groups: u64,
    pub channel_rejected_groups: u64,
    pub resources: Option<telemetry::Resources>,
    pub backend: String,
    pub codec: String,
    pub relay: Option<bool>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileEntry {
    pub name: String,
    pub directory: bool,
    pub size: u64,
    pub modified: i64,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn secrets_are_redacted_inside_nested_messages() {
        let request = Request {
            id: 1,
            session: 7,
            generation: 1,
            command: Command::Password {
                password: Secret("do-not-log-me".into()),
            },
        };
        assert!(!format!("{request:?}").contains("do-not-log-me"));
        let bytes = serde_json::to_vec(&request).unwrap();
        let parsed: Request = serde_json::from_slice(&bytes).unwrap();
        assert!(
            matches!(parsed.command, Command::Password { password } if password.0 == "do-not-log-me")
        );
    }
    #[test]
    fn worker_cannot_manage_host() {
        assert!(!Command::SetHost {
            enabled: true,
            revision: 0
        }
        .allowed_for(Role::Viewer));
        assert!(!Command::Input(Input::ReleaseAll).allowed_for(Role::Agent));
        assert!(!Command::Approve {
            connection: 3,
            permissions: Permissions::default()
        }
        .allowed_for(Role::Config));
        assert!(Command::Snapshot.allowed_for(Role::Config));
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AudioSource {
    pub id: String,
    pub name: String,
    pub microphone: bool,
}
