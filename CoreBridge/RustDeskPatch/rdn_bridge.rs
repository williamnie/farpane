// RustDesk Native Viewer bridge.
//
// This file is compiled inside RustDesk 1.4.9 at commit
// 6c578292e8ebbbec708b76986ba8c4bc7c509747. The surrounding RustDesk-derived
// build is AGPL-3.0; see CoreBridge/README.md and the repository root LICENSE.

use crate::client::{
    native_viewer_audio_disabled, native_viewer_audio_is_active, Data, QualityStatus,
};
use crate::common::input::{
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_WHEEL, MOUSE_TYPE_DOWN, MOUSE_TYPE_MOVE,
    MOUSE_TYPE_TRACKPAD, MOUSE_TYPE_UP, MOUSE_TYPE_WHEEL,
};
use crate::ui_session_interface::{io_loop, InvokeUiSession, Session};
use hbb_common::{message_proto::*, rendezvous_proto::ConnType};
use std::{
    collections::{HashMap, HashSet},
    ffi::{c_char, c_void, CStr, CString},
    ptr, slice,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, RwLock,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

const ABI_VERSION: u32 = 18;
const TERMINAL_NO_RETRY_CODE: i32 = 15;
const MAX_TEXT_BYTES: usize = 4_096;
const MAX_CLIPBOARD_TEXT_UTF8_BYTES: usize = 64 * 1024;
const MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES: usize = 1024 * 1024;
const MAX_CLIPBOARD_IMAGE_BYTES: usize = 128 * 1024 * 1024;
const MAX_CLIPBOARD_SVG_UTF8_BYTES: usize = 4 * 1024 * 1024;
const MAX_CLIPBOARD_IMAGE_DIMENSION: i32 = 8192;
const MAX_CLIPBOARD_IMAGE_PIXELS: usize = 7680 * 4320;
const MAX_FILE_TRANSFER_LIST_ENTRIES: usize = 1_024;
const MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES: usize = 1_024 * 1_024;
const MAX_DISPLAY_CATALOG_ENTRIES: usize = 64;
const MAX_DISPLAY_NAME_UTF8_BYTES: usize = 512;
const DISPLAY_CATALOG_STATUS_AVAILABLE: u32 = 1;
const DISPLAY_CATALOG_STATUS_UNAVAILABLE: u32 = 2;
const DISPLAY_INDEX_UNKNOWN: u32 = u32::MAX;
const DISPLAY_SELECTION_RESULT_SELECTED: u32 = 1;
const DISPLAY_SELECTION_RESULT_ALREADY_SELECTED: u32 = 2;
const DISPLAY_SELECTION_RESULT_FAILED: u32 = 3;
const DISPLAY_SELECTION_FAILURE_NONE: u32 = 0;
const DISPLAY_SELECTION_FAILURE_CATALOG_CHANGED: u32 = 1;
const DISPLAY_SELECTION_FAILURE_CONNECTION_CLOSED: u32 = 2;
const DISPLAY_SELECTION_FAILURE_REMOTE_SELECTION_DRIFT: u32 = 3;
static NEXT_VIEWER_CONNECTION_EPOCH: AtomicU64 = AtomicU64::new(1);

fn next_viewer_connection_epoch() -> Option<u64> {
    NEXT_VIEWER_CONNECTION_EPOCH
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
            value.checked_add(1)
        })
        .ok()
}
const FILE_TRANSFER_PRIVATE_STAGING_SUFFIX: &str = ".farpane-part";
const FILE_TRANSFER_LIST_SUCCESS: u32 = 1;
const FILE_TRANSFER_LIST_REJECTED: u32 = 2;
const FILE_TRANSFER_LIST_UNAVAILABLE: u32 = 3;
const FILE_TRANSFER_LIST_ENTRY_DIRECTORY: u32 = 1;
const FILE_TRANSFER_LIST_ENTRY_FILE: u32 = 2;
const FILE_TRANSFER_MANIFEST_PART_FILES: u32 = 1;
const FILE_TRANSFER_MANIFEST_PART_EMPTY_DIRECTORIES: u32 = 2;
const MAX_VIEWER_DOWNLOAD_JOBS: usize = 8;
const MAX_VIEWER_UPLOAD_JOBS: usize = 8;
const FILE_TRANSFER_EVENT_PROGRESS: u32 = 1;
const FILE_TRANSFER_EVENT_COMPLETED: u32 = 3;
const FILE_TRANSFER_EVENT_CANCELLED: u32 = 4;
const FILE_TRANSFER_EVENT_FAILED: u32 = 5;
const FILE_TRANSFER_FAILURE_NONE: u32 = 0;
const FILE_TRANSFER_FAILURE_REJECTED: u32 = 1;
const FILE_TRANSFER_FAILURE_UNAVAILABLE: u32 = 2;
const FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION: u32 = 3;
const FILE_TRANSFER_FAILURE_LOCAL_IO: u32 = 4;
const FILE_TRANSFER_FAILURE_CONNECTION_CLOSED: u32 = 5;
const VIEWER_UPLOAD_ACTIVE_POLL_INTERVAL_MS: u64 = 1;
const VIEWER_UPLOAD_WAITING_POLL_INTERVAL_MS: u64 = 100;
const VIEWER_UPLOAD_WIRE_TIMEOUT: Duration = Duration::from_secs(30);
const CLIPBOARD_IMAGE_FORMAT_RGBA: u32 = 1;
const CLIPBOARD_IMAGE_FORMAT_PNG: u32 = 2;
const CLIPBOARD_IMAGE_FORMAT_SVG: u32 = 3;
// Pinned RustDesk advertises a disabled clipboard with PermissionInfo(false),
// but omits PermissionInfo entirely when clipboard access is allowed. Match
// that wire default and let an explicit false revoke it for the session.
const REMOTE_CLIPBOARD_ENABLED_BY_DEFAULT: bool = true;
const UPSTREAM_COMMIT: &[u8] = b"6c578292e8ebbbec708b76986ba8c4bc7c509747\0";

include!("rdn_bridge/abi_types.rs");
include!("rdn_bridge/file_jobs.rs");
include!("rdn_bridge/callbacks_and_input_types.rs");
include!("rdn_bridge/display_state.rs");
include!("rdn_bridge/shared_state.rs");
include!("rdn_bridge/upstream_callbacks.rs");
include!("rdn_bridge/client.rs");
include!("rdn_bridge/clipboard.rs");
include!("rdn_bridge/file_protocol.rs");
include!("rdn_bridge/lifecycle.rs");
include!("rdn_bridge/input.rs");
include!("rdn_bridge/clipboard_abi.rs");
include!("rdn_bridge/file_abi.rs");
include!("rdn_bridge/video.rs");
#[cfg(test)]
mod tests {
include!("rdn_bridge/tests/connection_and_display.rs");
include!("rdn_bridge/tests/display_and_listing.rs");
include!("rdn_bridge/tests/clipboard.rs");
include!("rdn_bridge/tests/manifests_and_receive.rs");
include!("rdn_bridge/tests/upload_and_download_admission.rs");
include!("rdn_bridge/tests/transfer_progress.rs");
}
