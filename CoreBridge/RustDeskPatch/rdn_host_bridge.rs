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

#[cfg(target_os = "macos")]
#[path = "rdn_host_file_transfer.rs"]
mod rdn_host_file_transfer;

use hbb_common::{
    config,
    message_proto::{message, Clipboard, ClipboardFormat, Message, MultiClipboards},
    password_security, tokio, toml,
};
#[cfg(target_os = "macos")]
use hbb_common::{
    libc,
    sha2::{Digest, Sha256},
};
use serde_json::{json, Map, Value};
use std::{
    collections::{HashMap, HashSet},
    ffi::{c_char, c_void, CStr},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{sync_channel, Receiver, SyncSender, TrySendError},
        Arc, Mutex,
    },
    thread::JoinHandle,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
#[cfg(target_os = "macos")]
use std::{
    fs::File,
    io::{Read, Seek},
    os::unix::{ffi::OsStrExt, io::AsRawFd},
    path::{Component, Path, PathBuf},
};

const HOST_ABI_VERSION: u32 = 19;
const AUDIO_INPUT_DEVICE_MAX_UTF8_BYTES: usize = 512;
const HOST_MEDIA_ABI_VERSION: u32 = 1;
const EVENT_SCHEMA_VERSION: u32 = 1;
const SNAPSHOT_SCHEMA_VERSION: u32 = 8;
const UPSTREAM_COMMIT: &[u8] = b"6c578292e8ebbbec708b76986ba8c4bc7c509747\0";
const MAX_ENVELOPE_BYTES: usize = 64 * 1024;
const MAX_CLIPBOARD_TEXT_UTF8_BYTES: usize = 64 * 1024;
const MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES: usize = 1024 * 1024;
const MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES: usize = 1024 * 1024;
const MAX_CLIPBOARD_IMAGE_WIRE_BYTES: usize = 128 * 1024 * 1024;
const MAX_CLIPBOARD_IMAGE_DECODED_BYTES: usize = 128 * 1024 * 1024;
const MAX_CLIPBOARD_SVG_WIRE_BYTES: usize = 4 * 1024 * 1024;
const MAX_CLIPBOARD_SVG_UTF8_BYTES: usize = 4 * 1024 * 1024;
const MAX_CLIPBOARD_IMAGE_DIMENSION: i32 = 8192;
const MAX_CLIPBOARD_IMAGE_PIXELS: usize = 7680 * 4320;
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

include!("rdn_host_bridge/state.rs");
include!("rdn_host_bridge/file_types.rs");
include!("rdn_host_bridge/file_resume.rs");
include!("rdn_host_bridge/file_write_job.rs");
include!("rdn_host_bridge/file_read_job.rs");
include!("rdn_host_bridge/file_service.rs");
include!("rdn_host_bridge/file_mutations.rs");
include!("rdn_host_bridge/abi_types.rs");
include!("rdn_host_bridge/runtime_state.rs");
include!("rdn_host_bridge/media_state.rs");
include!("rdn_host_bridge/approval.rs");
include!("rdn_host_bridge/clipboard.rs");
include!("rdn_host_bridge/sessions.rs");
include!("rdn_host_bridge/media_telemetry.rs");
include!("rdn_host_bridge/session_lifecycle.rs");
include!("rdn_host_bridge/media_routes.rs");
include!("rdn_host_bridge/media_reports.rs");
include!("rdn_host_bridge/runtime.rs");
include!("rdn_host_bridge/configuration.rs");
include!("rdn_host_bridge/storage.rs");
include!("rdn_host_bridge/lifecycle.rs");
include!("rdn_host_bridge/commands.rs");
include!("rdn_host_bridge/media_abi.rs");
#[cfg(test)]
mod tests {
include!("rdn_host_bridge/tests/runtime_and_storage.rs");
include!("rdn_host_bridge/tests/file_write_jobs.rs");
include!("rdn_host_bridge/tests/file_resume_and_read.rs");
include!("rdn_host_bridge/tests/storage_security.rs");
include!("rdn_host_bridge/tests/clipboard_envelopes.rs");
include!("rdn_host_bridge/tests/session_permissions.rs");
include!("rdn_host_bridge/tests/approval_and_media.rs");
include!("rdn_host_bridge/tests/display_reconfigure.rs");
}
