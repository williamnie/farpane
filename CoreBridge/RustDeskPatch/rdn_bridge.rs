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

#[repr(C)]
#[derive(Clone, Copy)]
pub enum RDNState {
    Idle = 0,
    Connecting = 1,
    TransportReady = 2,
    Authenticated = 3,
    Streaming = 4,
    PasswordRequired = 5,
    AuthenticationFailed = 6,
    Disconnected = 7,
    Error = 8,
    ControlReady = 9,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub enum RDNCodec {
    Unknown = 0,
    H264 = 1,
    H265 = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RDNPacketFormat {
    Unknown = 0,
    AnnexB = 1,
    Avcc = 2,
    Mixed = 3,
}

const FLAG_KEYFRAME: u32 = 1 << 0;
const FLAG_VPS: u32 = 1 << 1;
const FLAG_SPS: u32 = 1 << 2;
const FLAG_PPS: u32 = 1 << 3;

#[repr(C)]
pub struct RDNEncodedVideoFrame {
    abi_version: u32,
    codec: RDNCodec,
    packet_format: RDNPacketFormat,
    data: *const u8,
    length: usize,
    sequence: u64,
    timestamp_us: u64,
    flags: u32,
    width: u32,
    height: u32,
    display: u32,
    connection_epoch: u64,
    display_catalog_revision: u64,
}

#[repr(C)]
pub struct RDNDisplayCatalogEntry {
    display_index: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    online: bool,
    scale: f64,
    name_utf8: *const u8,
    name_length: usize,
}

#[repr(C)]
pub struct RDNDisplayCatalogEvent {
    abi_version: u32,
    connection_epoch: u64,
    catalog_revision: u64,
    status: u32,
    selected_display_index: u32,
    selected_display_known: bool,
    entries: *const RDNDisplayCatalogEntry,
    entry_count: usize,
}

#[repr(C)]
pub struct RDNDisplaySelectionRequest {
    abi_version: u32,
    connection_epoch: u64,
    command_id: u64,
    catalog_revision: u64,
    display_index: u32,
}

#[repr(C)]
pub struct RDNDisplaySelectionEvent {
    abi_version: u32,
    connection_epoch: u64,
    command_id: u64,
    catalog_revision: u64,
    display_index: u32,
    result: u32,
    failure: u32,
}

#[repr(C)]
pub struct RDNCoreMetrics {
    abi_version: u32,
    remote_fps: f64,
    network_delay_ms: i32,
    target_bitrate: u64,
}

const REMOTE_PERMISSION_AUDIO: u32 = 1;

#[repr(C)]
pub struct RDNRemotePermissionEvent {
    abi_version: u32,
    connection_epoch: u64,
    permission: u32,
    enabled: bool,
}

fn native_remote_audio_permission_event(
    connection_epoch: u64,
    enabled: bool,
) -> Option<RDNRemotePermissionEvent> {
    (connection_epoch > 0).then_some(RDNRemotePermissionEvent {
        abi_version: ABI_VERSION,
        connection_epoch,
        permission: REMOTE_PERMISSION_AUDIO,
        enabled,
    })
}

type StateCallback = unsafe extern "C" fn(*mut c_void, RDNState, i32, *const c_char);
type RemotePermissionCallback =
    unsafe extern "C" fn(*mut c_void, *const RDNRemotePermissionEvent);
type VideoCallback = unsafe extern "C" fn(*mut c_void, *const RDNEncodedVideoFrame);
type DisplayCatalogCallback = unsafe extern "C" fn(*mut c_void, *const RDNDisplayCatalogEvent);
type DisplaySelectionCallback = unsafe extern "C" fn(*mut c_void, *const RDNDisplaySelectionEvent);
type MetricsCallback = unsafe extern "C" fn(*mut c_void, *const RDNCoreMetrics);
type ClipboardTextCallback = unsafe extern "C" fn(*mut c_void, *const u8, usize);
type ClipboardRichTextCallback =
    unsafe extern "C" fn(*mut c_void, *const RDNClipboardRichTextPayload);
type ClipboardImageCallback = unsafe extern "C" fn(*mut c_void, *const RDNClipboardImagePayload);
type FileTransferEventCallback = unsafe extern "C" fn(*mut c_void, *const RDNFileTransferEvent);
type FileTransferListCallback = unsafe extern "C" fn(*mut c_void, *const RDNFileTransferListEvent);
type FileTransferManifestCallback =
    unsafe extern "C" fn(*mut c_void, *const RDNFileTransferManifestEvent);
type FileTransferReceiveBlockCallback =
    unsafe extern "C" fn(*mut c_void, *const RDNFileTransferReceiveBlock);
type FileTransferUploadReadCallback =
    unsafe extern "C" fn(*mut c_void, *const RDNFileTransferUploadReadRequest, *mut usize) -> i32;

#[repr(C)]
pub struct RDNClipboardRichTextPayload {
    abi_version: u32,
    plain_utf8: *const u8,
    plain_length: usize,
    rtf_utf8: *const u8,
    rtf_length: usize,
    html_utf8: *const u8,
    html_length: usize,
}

#[repr(C)]
pub struct RDNClipboardImagePayload {
    abi_version: u32,
    format: u32,
    data: *const u8,
    length: usize,
    width: u32,
    height: u32,
}

#[repr(C)]
pub struct RDNFileTransferEvent {
    abi_version: u32,
    session_epoch: u64,
    transfer_id: i32,
    sequence: u64,
    kind: u32,
    failure: u32,
    current_file_number: i32,
    files_completed: u32,
    total_files: u32,
    bytes_completed: u64,
    total_bytes: u64,
    bytes_per_second: f64,
}

#[repr(C)]
pub struct RDNFileTransferDownloadStart {
    abi_version: u32,
    session_epoch: u64,
    manifest_request_id: i32,
    transfer_id: i32,
    total_files: u32,
    total_bytes: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RDNFileTransferListEntry {
    kind: u32,
    relative_path_utf8: *const u8,
    relative_path_length: usize,
    size: u64,
    modified_time: u64,
}

#[repr(C)]
struct RDNFileTransferListEvent {
    abi_version: u32,
    session_epoch: u64,
    request_id: i32,
    status: u32,
    entries: *const RDNFileTransferListEntry,
    entry_count: usize,
}

#[repr(C)]
struct RDNFileTransferManifestEvent {
    abi_version: u32,
    session_epoch: u64,
    request_id: i32,
    status: u32,
    part: u32,
    entries: *const RDNFileTransferListEntry,
    entry_count: usize,
}

#[repr(C)]
struct RDNFileTransferReceiveBlock {
    abi_version: u32,
    session_epoch: u64,
    transfer_id: i32,
    file_number: u32,
    data: *const u8,
    length: usize,
}

#[repr(C)]
pub struct RDNFileTransferUploadStart {
    abi_version: u32,
    session_epoch: u64,
    transfer_id: i32,
    source_token: u64,
    entries: *const RDNFileTransferListEntry,
    entry_count: usize,
    total_bytes: u64,
}

#[repr(C)]
pub struct RDNFileTransferUploadReadRequest {
    abi_version: u32,
    session_epoch: u64,
    transfer_id: i32,
    source_token: u64,
    file_number: u32,
    offset: u64,
    buffer: *mut u8,
    length: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeViewerRemoteListEntryKind {
    Directory,
    File,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerRemoteListEntry {
    kind: NativeViewerRemoteListEntryKind,
    relative_path: String,
    size: u64,
    modified_time: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct NativeViewerListRequest {
    session_epoch: u64,
    request_id: i32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerManifestRequest {
    session_epoch: u64,
    request_id: i32,
    files_delivered: bool,
    empty_directories_delivered: bool,
    total_files: Option<u32>,
    total_bytes: Option<u64>,
    files: Option<Vec<NativeViewerManifestFileAuthority>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct NativeViewerManifestFileAuthority {
    size: u64,
    modified_time: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerCompletedManifest {
    session_epoch: u64,
    request_id: i32,
    total_files: u32,
    total_bytes: u64,
    files: Arc<[NativeViewerManifestFileAuthority]>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerUploadFileAuthority {
    relative_path: String,
    size: u64,
    modified_time: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerUploadJob {
    session_epoch: u64,
    transfer_id: i32,
    source_token: u64,
    files: Arc<[NativeViewerUploadFileAuthority]>,
    empty_directories: Arc<[String]>,
    total_bytes: u64,
    stage: NativeViewerUploadStage,
    stage_started: Instant,
    sequence: u64,
    files_completed: u32,
    bytes_completed: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeViewerUploadStage {
    AwaitingCreate { directory_number: usize },
    ReadyDigest { file_number: u32 },
    AwaitingConfirmation { file_number: u32 },
    Sending { file_number: u32, offset: u64 },
    ReadyDone,
    AwaitingDone,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerDownloadJob {
    session_epoch: u64,
    manifest_request_id: i32,
    transfer_id: i32,
    total_files: u32,
    total_bytes: u64,
    manifest_files: Arc<[NativeViewerManifestFileAuthority]>,
    next_digest_file_number: u32,
    sequence: u64,
    files_completed: u32,
    bytes_completed: u64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct NativeViewerDownloadEvent {
    session_epoch: u64,
    transfer_id: i32,
    sequence: u64,
    kind: u32,
    failure: u32,
    current_file_number: i32,
    files_completed: u32,
    total_files: u32,
    bytes_completed: u64,
    total_bytes: u64,
    bytes_per_second: f64,
}

#[derive(Debug, Eq, PartialEq)]
struct NativeViewerReceiveBlock {
    session_epoch: u64,
    transfer_id: i32,
    file_number: u32,
    payload: Vec<u8>,
}

impl NativeViewerDownloadJob {
    fn confirm_digest(
        &mut self,
        digest: &FileTransferDigest,
    ) -> Option<FileTransferSendConfirmRequest> {
        if digest.id != self.transfer_id
            || digest.is_upload
            || digest.is_resume
            || digest.is_identical
            || digest.transferred_size != 0
        {
            return None;
        }
        let file_number = u32::try_from(digest.file_num).ok()?;
        if file_number != self.next_digest_file_number {
            return None;
        }
        let authority = self.manifest_files.get(file_number as usize)?;
        if digest.file_size != authority.size || digest.last_modified != authority.modified_time {
            return None;
        }
        self.next_digest_file_number = file_number.checked_add(1)?;
        Some(FileTransferSendConfirmRequest {
            id: self.transfer_id,
            file_num: digest.file_num,
            union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
            ..Default::default()
        })
    }

    fn receive_block(&self, block: &FileTransferBlock) -> Option<NativeViewerReceiveBlock> {
        if block.id != self.transfer_id
            || block.data.is_empty()
            || block.data.len() > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES
        {
            return None;
        }
        let file_number = u32::try_from(block.file_num).ok()?;
        if file_number >= self.total_files || file_number >= self.next_digest_file_number {
            return None;
        }
        let payload = if block.compressed {
            hbb_common::compress::decompress_with_limit(
                &block.data,
                hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES,
            )
            .ok()?
        } else {
            block.data.to_vec()
        };
        if payload.is_empty() || payload.len() > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES {
            return None;
        }
        Some(NativeViewerReceiveBlock {
            session_epoch: self.session_epoch,
            transfer_id: self.transfer_id,
            file_number,
            payload,
        })
    }

    fn progress(
        &mut self,
        completed_file_number: i32,
        bytes_per_second: f64,
        finished_size: f64,
    ) -> Option<NativeViewerDownloadEvent> {
        if completed_file_number < -1
            || !bytes_per_second.is_finite()
            || bytes_per_second < 0.0
            || !finished_size.is_finite()
            || finished_size < 0.0
            || finished_size.fract() != 0.0
            || finished_size > self.total_bytes as f64
        {
            return None;
        }
        let files_completed = u32::try_from(completed_file_number.checked_add(1)?).ok()?;
        let bytes_completed = finished_size as u64;
        if files_completed > self.total_files
            || files_completed < self.files_completed
            || bytes_completed > self.total_bytes
            || bytes_completed < self.bytes_completed
        {
            return None;
        }
        let sequence = self.sequence.checked_add(1)?;
        self.sequence = sequence;
        self.files_completed = files_completed;
        self.bytes_completed = bytes_completed;
        Some(self.event(
            sequence,
            FILE_TRANSFER_EVENT_PROGRESS,
            FILE_TRANSFER_FAILURE_NONE,
            if files_completed < self.total_files {
                files_completed as i32
            } else {
                -1
            },
            files_completed,
            bytes_completed,
            bytes_per_second,
        ))
    }

    fn terminal(self, kind: u32, failure: u32) -> Option<NativeViewerDownloadEvent> {
        let sequence = self.sequence.checked_add(1)?;
        let (files_completed, bytes_completed) = if kind == FILE_TRANSFER_EVENT_COMPLETED {
            (self.total_files, self.total_bytes)
        } else {
            (self.files_completed, self.bytes_completed)
        };
        Some(self.event(
            sequence,
            kind,
            failure,
            -1,
            files_completed,
            bytes_completed,
            0.0,
        ))
    }

    fn event(
        &self,
        sequence: u64,
        kind: u32,
        failure: u32,
        current_file_number: i32,
        files_completed: u32,
        bytes_completed: u64,
        bytes_per_second: f64,
    ) -> NativeViewerDownloadEvent {
        NativeViewerDownloadEvent {
            session_epoch: self.session_epoch,
            transfer_id: self.transfer_id,
            sequence,
            kind,
            failure,
            current_file_number,
            files_completed,
            total_files: self.total_files,
            bytes_completed,
            total_bytes: self.total_bytes,
            bytes_per_second,
        }
    }
}

impl NativeViewerUploadJob {
    fn poll_interval_ms(&self) -> u64 {
        match self.stage {
            NativeViewerUploadStage::ReadyDigest { .. }
            | NativeViewerUploadStage::Sending { .. }
            | NativeViewerUploadStage::ReadyDone => VIEWER_UPLOAD_ACTIVE_POLL_INTERVAL_MS,
            NativeViewerUploadStage::AwaitingCreate { .. }
            | NativeViewerUploadStage::AwaitingConfirmation { .. }
            | NativeViewerUploadStage::AwaitingDone => VIEWER_UPLOAD_WAITING_POLL_INTERVAL_MS,
        }
    }

    fn timed_out(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.stage_started) >= VIEWER_UPLOAD_WIRE_TIMEOUT
    }

    fn transition(&mut self, stage: NativeViewerUploadStage) {
        self.stage = stage;
        self.stage_started = Instant::now();
    }

    fn initial_message(&self) -> Option<Message> {
        match self.stage {
            NativeViewerUploadStage::AwaitingCreate {
                directory_number: 0,
            } => native_viewer_upload_create_message(
                self.transfer_id,
                self.empty_directories.first()?.clone(),
            ),
            NativeViewerUploadStage::ReadyDigest { file_number: 0 } => {
                native_viewer_upload_receive_message(self)
            }
            _ => None,
        }
    }

    fn next_digest_message(&mut self, file_number: u32) -> Option<Message> {
        let file = self.files.get(file_number as usize)?;
        let message = native_viewer_upload_digest_message(
            self.transfer_id,
            file_number,
            file.size,
            file.modified_time,
        );
        self.transition(NativeViewerUploadStage::AwaitingConfirmation { file_number });
        Some(message)
    }

    fn next_done_message(&mut self) -> Option<Message> {
        let file_number = i32::try_from(self.files.len()).ok()?;
        self.transition(NativeViewerUploadStage::AwaitingDone);
        Some(hbb_common::fs::new_done(self.transfer_id, file_number))
    }

    fn advance_file(&mut self, file_number: u32, count_remaining_bytes: bool) -> bool {
        let Some(file) = self.files.get(file_number as usize) else {
            return false;
        };
        if count_remaining_bytes {
            let Some(bytes_completed) = self.bytes_completed.checked_add(file.size) else {
                return false;
            };
            if bytes_completed > self.total_bytes {
                return false;
            }
            self.bytes_completed = bytes_completed;
        }
        let Some(files_completed) = self.files_completed.checked_add(1) else {
            return false;
        };
        if files_completed as usize > self.files.len() {
            return false;
        }
        self.files_completed = files_completed;
        if files_completed as usize == self.files.len() {
            self.transition(NativeViewerUploadStage::ReadyDone);
        } else {
            self.transition(NativeViewerUploadStage::ReadyDigest {
                file_number: files_completed,
            });
        }
        true
    }

    fn progress_event(&mut self, current_file_number: i32) -> Option<NativeViewerDownloadEvent> {
        let sequence = self.sequence.checked_add(1)?;
        self.sequence = sequence;
        Some(self.event(
            sequence,
            FILE_TRANSFER_EVENT_PROGRESS,
            FILE_TRANSFER_FAILURE_NONE,
            current_file_number,
            self.files_completed,
            self.bytes_completed,
        ))
    }

    fn read_source(
        &self,
        callback: FileTransferUploadReadCallback,
        context: usize,
        file_number: u32,
        offset: u64,
        length: usize,
    ) -> Option<Vec<u8>> {
        if length == 0 || length > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES {
            return None;
        }
        let file = self.files.get(file_number as usize)?;
        let end = offset.checked_add(length as u64)?;
        if offset >= file.size || end > file.size {
            return None;
        }
        let mut payload = vec![0; length];
        let request = RDNFileTransferUploadReadRequest {
            abi_version: ABI_VERSION,
            session_epoch: self.session_epoch,
            transfer_id: self.transfer_id,
            source_token: self.source_token,
            file_number,
            offset,
            buffer: payload.as_mut_ptr(),
            length,
        };
        let mut bytes_written = 0usize;
        let result = unsafe { callback(context as *mut c_void, &request, &mut bytes_written) };
        if result != 0 || bytes_written != length {
            payload.fill(0);
            return None;
        }
        Some(payload)
    }

    fn terminal(self, kind: u32, failure: u32) -> Option<NativeViewerDownloadEvent> {
        let sequence = self.sequence.checked_add(1)?;
        let (files_completed, bytes_completed) = if kind == FILE_TRANSFER_EVENT_COMPLETED {
            (u32::try_from(self.files.len()).ok()?, self.total_bytes)
        } else {
            (self.files_completed, self.bytes_completed)
        };
        Some(self.event(
            sequence,
            kind,
            failure,
            -1,
            files_completed,
            bytes_completed,
        ))
    }

    fn event(
        &self,
        sequence: u64,
        kind: u32,
        failure: u32,
        current_file_number: i32,
        files_completed: u32,
        bytes_completed: u64,
    ) -> NativeViewerDownloadEvent {
        NativeViewerDownloadEvent {
            session_epoch: self.session_epoch,
            transfer_id: self.transfer_id,
            sequence,
            kind,
            failure,
            current_file_number,
            files_completed,
            total_files: self.files.len() as u32,
            bytes_completed,
            total_bytes: self.total_bytes,
            bytes_per_second: 0.0,
        }
    }
}

fn native_viewer_upload_create_message(transfer_id: i32, path: String) -> Option<Message> {
    if transfer_id <= 0 || path.is_empty() {
        return None;
    }
    let mut action = FileAction::new();
    action.set_create(FileDirCreate {
        id: transfer_id,
        path,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_file_action(action);
    Some(message)
}

fn native_viewer_upload_receive_message(job: &NativeViewerUploadJob) -> Option<Message> {
    if job.files.is_empty() {
        return None;
    }
    let files = job
        .files
        .iter()
        .map(|file| FileEntry {
            entry_type: FileType::File.into(),
            name: file.relative_path.clone(),
            size: file.size,
            modified_time: file.modified_time,
            ..Default::default()
        })
        .collect();
    Some(hbb_common::fs::new_receive(
        job.transfer_id,
        String::new(),
        0,
        files,
        job.total_bytes,
    ))
}

fn native_viewer_upload_digest_message(
    transfer_id: i32,
    file_number: u32,
    file_size: u64,
    modified_time: u64,
) -> Message {
    let mut response = FileResponse::new();
    response.set_digest(FileTransferDigest {
        id: transfer_id,
        file_num: i32::try_from(file_number).unwrap_or(-1),
        last_modified: modified_time,
        file_size,
        is_resume: false,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_file_response(response);
    message
}

fn native_viewer_upload_cancel_message(transfer_id: i32) -> Message {
    let mut action = FileAction::new();
    action.set_cancel(FileTransferCancel {
        id: transfer_id,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_file_action(action);
    message
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RDNCallbacks {
    abi_version: u32,
    on_state: Option<StateCallback>,
    on_remote_permission: Option<RemotePermissionCallback>,
    on_video: Option<VideoCallback>,
    on_display_catalog: Option<DisplayCatalogCallback>,
    on_display_selection: Option<DisplaySelectionCallback>,
    on_metrics: Option<MetricsCallback>,
    on_clipboard_text: Option<ClipboardTextCallback>,
    on_clipboard_rich_text: Option<ClipboardRichTextCallback>,
    on_clipboard_image: Option<ClipboardImageCallback>,
    on_file_transfer_event: Option<FileTransferEventCallback>,
    on_file_transfer_list: Option<FileTransferListCallback>,
    on_file_transfer_manifest: Option<FileTransferManifestCallback>,
    on_file_transfer_receive_block: Option<FileTransferReceiveBlockCallback>,
    on_file_transfer_upload_read: Option<FileTransferUploadReadCallback>,
}

#[repr(C)]
pub struct RDNConnectionConfig {
    abi_version: u32,
    rendezvous_server: *const c_char,
    server_public_key: *const c_char,
    peer_id: *const c_char,
    password: *const c_char,
    force_relay: bool,
    receive_audio: bool,
    receive_clipboard_text: bool,
    send_clipboard_text: bool,
    receive_clipboard_rich_text: bool,
    send_clipboard_rich_text: bool,
    receive_clipboard_image: bool,
    send_clipboard_image: bool,
    enable_file_transfer: bool,
    file_transfer_session_epoch: u64,
}

const MODIFIER_SHIFT: u32 = 1 << 0;
const MODIFIER_CONTROL: u32 = 1 << 1;
const MODIFIER_OPTION: u32 = 1 << 2;
const MODIFIER_COMMAND: u32 = 1 << 3;
const VALID_MODIFIERS: u32 = MODIFIER_SHIFT | MODIFIER_CONTROL | MODIFIER_OPTION | MODIFIER_COMMAND;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RDNPointerKind {
    Move = 0,
    Down = 1,
    Up = 2,
    Scroll = 3,
    PreciseScroll = 4,
}

const POINTER_BUTTON_LEFT: u32 = 1 << 0;
const POINTER_BUTTON_RIGHT: u32 = 1 << 1;
const POINTER_BUTTON_MIDDLE: u32 = 1 << 2;
const VALID_POINTER_BUTTONS: u32 =
    POINTER_BUTTON_LEFT | POINTER_BUTTON_RIGHT | POINTER_BUTTON_MIDDLE;

#[repr(C)]
pub struct RDNPointerEvent {
    abi_version: u32,
    kind: RDNPointerKind,
    x: i32,
    y: i32,
    scroll_x: i32,
    scroll_y: i32,
    buttons: u32,
    modifiers: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RDNKeyCode {
    Character = 0,
    Escape = 1,
    Return = 2,
    Tab = 3,
    Backspace = 4,
    DeleteForward = 5,
    Left = 6,
    Right = 7,
    Up = 8,
    Down = 9,
    Space = 10,
    Shift = 11,
    Control = 12,
    Option = 13,
    Command = 14,
    Home = 15,
    End = 16,
    PageUp = 17,
    PageDown = 18,
    Physical = 19,
}

#[repr(C)]
pub struct RDNKeyEvent {
    abi_version: u32,
    code: RDNKeyCode,
    unicode_scalar: u32,
    hardware_keycode: u32,
    down: bool,
    modifiers: u32,
}

#[derive(Clone, Debug, PartialEq)]
struct NativeViewerDisplayCatalogEntry {
    display_index: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    online: bool,
    scale: f64,
    name: Vec<u8>,
}

#[derive(Clone, Default)]
struct NativeViewerDisplayCatalogState {
    initialized: bool,
    revision: u64,
    entries: Option<Arc<[NativeViewerDisplayCatalogEntry]>>,
    selected_display_index: Option<u32>,
    last_selection_command_id: u64,
    pending_selection: Option<NativeViewerDisplaySelectionPending>,
}

#[derive(Clone, Copy)]
struct NativeViewerDisplaySelectionPending {
    connection_epoch: u64,
    command_id: u64,
    catalog_revision: u64,
    display_index: u32,
}

#[derive(Clone, Copy)]
struct NativeViewerDisplaySelectionSnapshot {
    pending: NativeViewerDisplaySelectionPending,
    result: u32,
    failure: u32,
}

#[derive(Clone)]
struct NativeViewerDisplayCatalogSnapshot {
    connection_epoch: u64,
    revision: u64,
    entries: Option<Arc<[NativeViewerDisplayCatalogEntry]>>,
    selected_display_index: Option<u32>,
}

#[derive(Clone, Copy)]
enum NativeViewerDisplaySelectionIngress {
    RemoteFollow,
    SwitchEcho,
}

fn normalized_native_viewer_display_catalog(
    displays: &[DisplayInfo],
) -> Option<Vec<NativeViewerDisplayCatalogEntry>> {
    if displays.len() > MAX_DISPLAY_CATALOG_ENTRIES {
        return None;
    }
    displays
        .iter()
        .enumerate()
        .map(|(index, display)| {
            let name = display.name.as_bytes();
            let valid_geometry = if display.online {
                display.width > 0 && display.height > 0
            } else {
                display.width >= 0 && display.height >= 0
            };
            if !valid_geometry
                || !display.scale.is_finite()
                || display.scale <= 0.0
                || display.scale > 16.0
                || name.len() > MAX_DISPLAY_NAME_UTF8_BYTES
                || display.name.chars().any(char::is_control)
            {
                return None;
            }
            Some(NativeViewerDisplayCatalogEntry {
                display_index: u32::try_from(index).ok()?,
                x: display.x,
                y: display.y,
                width: display.width,
                height: display.height,
                online: display.online,
                scale: display.scale,
                name: name.to_vec(),
            })
        })
        .collect()
}

struct BridgeShared {
    callbacks: RDNCallbacks,
    context: usize,
    active: AtomicBool,
    terminal_retry_allowed: AtomicBool,
    sequence: AtomicU64,
    dimensions: RwLock<(u32, u32)>,
    connection_epoch: AtomicU64,
    display_catalog: Mutex<NativeViewerDisplayCatalogState>,
    display_catalog_delivery: Mutex<()>,
    authenticated: AtomicBool,
    remote_keyboard_enabled: AtomicBool,
    remote_audio_enabled: AtomicBool,
    input_allowed: AtomicBool,
    receive_clipboard_text: AtomicBool,
    send_clipboard_text: AtomicBool,
    receive_clipboard_rich_text: AtomicBool,
    send_clipboard_rich_text: AtomicBool,
    receive_clipboard_image: AtomicBool,
    send_clipboard_image: AtomicBool,
    remote_clipboard_enabled: AtomicBool,
    remote_file_transfer_enabled: AtomicBool,
    file_transfer_enabled: AtomicBool,
    file_transfer_session_epoch: AtomicU64,
    pending_file_list_request: Mutex<Option<NativeViewerListRequest>>,
    file_manifest_request_epoch: AtomicU64,
    pending_file_manifest_request: Mutex<Option<NativeViewerManifestRequest>>,
    completed_file_manifest_request: Mutex<Option<NativeViewerCompletedManifest>>,
    active_file_download_jobs: Mutex<HashMap<i32, NativeViewerDownloadJob>>,
    active_file_upload_jobs: Mutex<HashMap<i32, NativeViewerUploadJob>>,
    file_upload_poll_cursor: AtomicU64,
}

impl BridgeShared {
    fn emit_file_transfer_ready_if_available(&self) {
        if self.active.load(Ordering::Acquire)
            && self.authenticated.load(Ordering::Acquire)
            && self.file_transfer_enabled.load(Ordering::Acquire)
            && self.remote_file_transfer_enabled.load(Ordering::Acquire)
        {
            self.emit_state(RDNState::Streaming, 0, "file-transfer-ready");
        }
    }

    fn read_file_transfer_upload_source(
        &self,
        transfer_id: i32,
        file_number: u32,
        offset: u64,
        length: usize,
    ) -> Option<Vec<u8>> {
        let job = self
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .get(&transfer_id)
            .cloned()?;
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != job.session_epoch
        {
            return None;
        }
        let callback = self.callbacks.on_file_transfer_upload_read?;
        let mut payload = job.read_source(callback, self.context, file_number, offset, length)?;
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != job.session_epoch
            || self
                .active_file_upload_jobs
                .lock()
                .unwrap()
                .get(&transfer_id)
                != Some(&job)
        {
            payload.fill(0);
            return None;
        }
        Some(payload)
    }

    fn file_transfer_upload_poll_interval_ms(&self) -> u64 {
        self.active_file_upload_jobs
            .lock()
            .unwrap()
            .values()
            .map(NativeViewerUploadJob::poll_interval_ms)
            .min()
            .unwrap_or(0)
    }

    fn file_transfer_upload_poll(&self) -> Option<Message> {
        let now = Instant::now();
        let cursor = self.file_upload_poll_cursor.load(Ordering::Acquire) as i32;
        let candidate = {
            let jobs = self.active_file_upload_jobs.lock().unwrap();
            let mut ids: Vec<_> = jobs.keys().copied().collect();
            ids.sort_unstable();
            let split = ids.iter().position(|id| *id > cursor).unwrap_or(0);
            ids.rotate_left(split);
            ids.into_iter().find_map(|id| {
                let job = jobs.get(&id)?;
                let ready = matches!(
                    job.stage,
                    NativeViewerUploadStage::ReadyDigest { .. }
                        | NativeViewerUploadStage::Sending { .. }
                        | NativeViewerUploadStage::ReadyDone
                );
                (ready || job.timed_out(now)).then(|| (id, job.clone()))
            })
        }?;
        self.file_upload_poll_cursor
            .store(candidate.0 as u64, Ordering::Release);
        let (transfer_id, snapshot) = candidate;

        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != snapshot.session_epoch
        {
            self.active_file_upload_jobs
                .lock()
                .unwrap()
                .remove(&transfer_id);
            return None;
        }
        if snapshot.timed_out(now) {
            let event = self
                .active_file_upload_jobs
                .lock()
                .unwrap()
                .remove(&transfer_id)
                .filter(|job| job == &snapshot)
                .and_then(|job| {
                    job.terminal(
                        FILE_TRANSFER_EVENT_FAILED,
                        FILE_TRANSFER_FAILURE_UNAVAILABLE,
                    )
                });
            if let Some(event) = event {
                self.emit_file_transfer_event(event);
                return Some(native_viewer_upload_cancel_message(transfer_id));
            }
            return None;
        }

        match snapshot.stage {
            NativeViewerUploadStage::ReadyDigest { file_number } => {
                let message = {
                    let mut jobs = self.active_file_upload_jobs.lock().unwrap();
                    let job = jobs.get_mut(&transfer_id)?;
                    if job != &snapshot {
                        return None;
                    }
                    job.next_digest_message(file_number)
                };
                message
            }
            NativeViewerUploadStage::ReadyDone => {
                let message = {
                    let mut jobs = self.active_file_upload_jobs.lock().unwrap();
                    let job = jobs.get_mut(&transfer_id)?;
                    if job != &snapshot {
                        return None;
                    }
                    job.next_done_message()
                };
                message
            }
            NativeViewerUploadStage::Sending {
                file_number,
                offset,
            } => {
                let file = snapshot.files.get(file_number as usize)?;
                if offset == file.size {
                    let event = {
                        let mut jobs = self.active_file_upload_jobs.lock().unwrap();
                        let job = jobs.get_mut(&transfer_id)?;
                        if job != &snapshot || !job.advance_file(file_number, false) {
                            return None;
                        }
                        job.progress_event(-1)
                    };
                    if let Some(event) = event {
                        self.emit_file_transfer_event(event);
                    }
                    return None;
                }
                let remaining = file.size.checked_sub(offset)?;
                let length = usize::try_from(
                    remaining.min(hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES as u64),
                )
                .ok()?;
                let Some(mut payload) =
                    self.read_file_transfer_upload_source(transfer_id, file_number, offset, length)
                else {
                    let event = self
                        .active_file_upload_jobs
                        .lock()
                        .unwrap()
                        .remove(&transfer_id)
                        .filter(|job| job == &snapshot)
                        .and_then(|job| {
                            job.terminal(FILE_TRANSFER_EVENT_FAILED, FILE_TRANSFER_FAILURE_LOCAL_IO)
                        });
                    if let Some(event) = event {
                        self.emit_file_transfer_event(event);
                        return Some(native_viewer_upload_cancel_message(transfer_id));
                    }
                    return None;
                };
                let encoded = hbb_common::compress::compress(&payload);
                let (mut data, compressed) = if encoded.len() < payload.len() {
                    payload.fill(0);
                    (encoded, true)
                } else {
                    (payload, false)
                };
                let next_offset = offset.checked_add(length as u64)?;
                let event = {
                    let mut jobs = self.active_file_upload_jobs.lock().unwrap();
                    let job = jobs.get_mut(&transfer_id)?;
                    if job != &snapshot || next_offset > file.size {
                        data.fill(0);
                        return None;
                    }
                    job.bytes_completed = job.bytes_completed.checked_add(length as u64)?;
                    if job.bytes_completed > job.total_bytes {
                        return None;
                    }
                    job.transition(NativeViewerUploadStage::Sending {
                        file_number,
                        offset: next_offset,
                    });
                    job.progress_event(file_number as i32)
                };
                if let Some(event) = event {
                    self.emit_file_transfer_event(event);
                }
                Some(hbb_common::fs::new_block(FileTransferBlock {
                    id: transfer_id,
                    file_num: file_number as i32,
                    data: data.into(),
                    compressed,
                    ..Default::default()
                }))
            }
            NativeViewerUploadStage::AwaitingCreate { .. }
            | NativeViewerUploadStage::AwaitingConfirmation { .. }
            | NativeViewerUploadStage::AwaitingDone => None,
        }
    }

    fn file_transfer_upload_confirmation(
        &self,
        request: &FileTransferSendConfirmRequest,
    ) -> (bool, Vec<Message>) {
        let mut event = None;
        let mut failed = false;
        {
            let mut jobs = self.active_file_upload_jobs.lock().unwrap();
            let Some(job) = jobs.get_mut(&request.id) else {
                return (false, Vec::new());
            };
            let NativeViewerUploadStage::AwaitingConfirmation { file_number } = job.stage else {
                drop(jobs);
                return self.fail_file_transfer_upload(
                    request.id,
                    FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                    true,
                );
            };
            if request.file_num != file_number as i32 {
                failed = true;
            } else {
                match request.union {
                    Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)) => {
                        let Some(file) = job.files.get(file_number as usize) else {
                            drop(jobs);
                            return self.fail_file_transfer_upload(
                                request.id,
                                FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                                true,
                            );
                        };
                        if file.size == 0 {
                            if !job.advance_file(file_number, false) {
                                failed = true;
                            } else {
                                event = job.progress_event(-1);
                            }
                        } else {
                            job.transition(NativeViewerUploadStage::Sending {
                                file_number,
                                offset: 0,
                            });
                        }
                    }
                    Some(file_transfer_send_confirm_request::Union::Skip(true)) => {
                        if !job.advance_file(file_number, true) {
                            failed = true;
                        } else {
                            event = job.progress_event(-1);
                        }
                    }
                    _ => failed = true,
                }
            }
        }
        if failed {
            return self.fail_file_transfer_upload(
                request.id,
                FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                true,
            );
        }
        if let Some(event) = event {
            self.emit_file_transfer_event(event);
        }
        (true, Vec::new())
    }

    fn file_transfer_upload_existing_target(
        &self,
        digest: &FileTransferDigest,
    ) -> (bool, Vec<Message>) {
        let mut event = None;
        let mut failed = false;
        {
            let mut jobs = self.active_file_upload_jobs.lock().unwrap();
            let Some(job) = jobs.get_mut(&digest.id) else {
                return (false, Vec::new());
            };
            let NativeViewerUploadStage::AwaitingConfirmation { file_number } = job.stage else {
                drop(jobs);
                return self.fail_file_transfer_upload(
                    digest.id,
                    FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                    true,
                );
            };
            if !digest.is_upload
                || digest.is_resume
                || digest.transferred_size != 0
                || digest.file_num != file_number as i32
                || !job.advance_file(file_number, true)
            {
                failed = true;
            } else {
                event = job.progress_event(-1);
            }
        }
        if failed {
            return self.fail_file_transfer_upload(
                digest.id,
                FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                true,
            );
        }
        if let Some(event) = event {
            self.emit_file_transfer_event(event);
        }
        let confirmation = FileTransferSendConfirmRequest {
            id: digest.id,
            file_num: digest.file_num,
            union: Some(file_transfer_send_confirm_request::Union::Skip(true)),
            ..Default::default()
        };
        (true, vec![hbb_common::fs::new_send_confirm(confirmation)])
    }

    fn file_transfer_upload_done(&self, done: &FileTransferDone) -> (bool, Vec<Message>) {
        let mut messages = Vec::new();
        let mut terminal = None;
        let mut failed = false;
        {
            let mut jobs = self.active_file_upload_jobs.lock().unwrap();
            let Some(job) = jobs.get_mut(&done.id) else {
                return (false, messages);
            };
            match job.stage {
                NativeViewerUploadStage::AwaitingCreate { directory_number }
                    if done.file_num == 0 =>
                {
                    let next = directory_number + 1;
                    if next < job.empty_directories.len() {
                        job.transition(NativeViewerUploadStage::AwaitingCreate {
                            directory_number: next,
                        });
                        if let Some(message) = native_viewer_upload_create_message(
                            job.transfer_id,
                            job.empty_directories[next].clone(),
                        ) {
                            messages.push(message);
                        } else {
                            failed = true;
                        }
                    } else if job.files.is_empty() {
                        let job = jobs
                            .remove(&done.id)
                            .expect("upload job remains registered");
                        terminal =
                            job.terminal(FILE_TRANSFER_EVENT_COMPLETED, FILE_TRANSFER_FAILURE_NONE);
                    } else {
                        job.transition(NativeViewerUploadStage::ReadyDigest { file_number: 0 });
                        if let Some(message) = native_viewer_upload_receive_message(job) {
                            messages.push(message);
                        } else {
                            failed = true;
                        }
                    }
                }
                NativeViewerUploadStage::AwaitingDone
                    if done.file_num == job.files.len() as i32 =>
                {
                    let job = jobs
                        .remove(&done.id)
                        .expect("upload job remains registered");
                    terminal =
                        job.terminal(FILE_TRANSFER_EVENT_COMPLETED, FILE_TRANSFER_FAILURE_NONE);
                }
                _ => failed = true,
            }
        }
        if failed {
            return self.fail_file_transfer_upload(
                done.id,
                FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                true,
            );
        }
        if let Some(event) = terminal {
            self.emit_file_transfer_event(event);
        }
        (true, messages)
    }

    fn file_transfer_upload_error(&self, error: &FileTransferError) -> (bool, Vec<Message>) {
        if !self
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .contains_key(&error.id)
        {
            return (false, Vec::new());
        }
        self.fail_file_transfer_upload(error.id, FILE_TRANSFER_FAILURE_REJECTED, false)
    }

    fn fail_file_transfer_upload(
        &self,
        transfer_id: i32,
        failure: u32,
        send_cancel: bool,
    ) -> (bool, Vec<Message>) {
        let event = self
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .remove(&transfer_id)
            .and_then(|job| job.terminal(FILE_TRANSFER_EVENT_FAILED, failure));
        if let Some(event) = event {
            self.emit_file_transfer_event(event);
        }
        let messages = if send_cancel {
            vec![native_viewer_upload_cancel_message(transfer_id)]
        } else {
            Vec::new()
        };
        (true, messages)
    }

    fn emit_file_transfer_event(&self, event: NativeViewerDownloadEvent) {
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != event.session_epoch
        {
            return;
        }
        let Some(callback) = self.callbacks.on_file_transfer_event else {
            return;
        };
        let raw = RDNFileTransferEvent {
            abi_version: ABI_VERSION,
            session_epoch: event.session_epoch,
            transfer_id: event.transfer_id,
            sequence: event.sequence,
            kind: event.kind,
            failure: event.failure,
            current_file_number: event.current_file_number,
            files_completed: event.files_completed,
            total_files: event.total_files,
            bytes_completed: event.bytes_completed,
            total_bytes: event.total_bytes,
            bytes_per_second: event.bytes_per_second,
        };
        unsafe { callback(self.context as *mut c_void, &raw) };
    }

    fn emit_state(&self, state: RDNState, code: i32, message: &'static str) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        self.emit_state_unchecked(state, code, message);
    }

    fn emit_state_unchecked(&self, state: RDNState, code: i32, message: &'static str) {
        let Some(callback) = self.callbacks.on_state else {
            return;
        };
        let message = CString::new(message).expect("static bridge message contains no NUL");
        unsafe { callback(self.context as *mut c_void, state, code, message.as_ptr()) };
    }

    fn emit_remote_audio_permission(&self) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        let connection_epoch = self.connection_epoch.load(Ordering::Acquire);
        let Some(callback) = self.callbacks.on_remote_permission else {
            return;
        };
        let Some(event) = native_remote_audio_permission_event(
            connection_epoch,
            self.remote_audio_enabled.load(Ordering::Acquire),
        ) else { return };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn emit_metrics(&self, status: QualityStatus) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        let Some(callback) = self.callbacks.on_metrics else {
            return;
        };
        let metrics = RDNCoreMetrics {
            abi_version: ABI_VERSION,
            remote_fps: status.fps.values().copied().max().unwrap_or_default() as f64,
            network_delay_ms: status.delay.unwrap_or(-1),
            target_bitrate: status.target_bitrate.unwrap_or_default().max(0) as u64,
        };
        unsafe { callback(self.context as *mut c_void, &metrics) };
    }

    fn emit_clipboard_text(&self, text: &str) {
        if !clipboard_receive_allowed(
            self.active.load(Ordering::Acquire),
            self.authenticated.load(Ordering::Acquire),
            self.receive_clipboard_text.load(Ordering::Acquire),
            self.remote_clipboard_enabled.load(Ordering::Acquire),
        ) {
            return;
        }
        let Some(callback) = self.callbacks.on_clipboard_text else {
            return;
        };
        unsafe {
            callback(
                self.context as *mut c_void,
                text.as_bytes().as_ptr(),
                text.len(),
            )
        };
    }

    fn emit_clipboard_rich_text(&self, rich: NativeViewerRichTextBundle) {
        if !clipboard_receive_allowed(
            self.active.load(Ordering::Acquire),
            self.authenticated.load(Ordering::Acquire),
            self.receive_clipboard_rich_text.load(Ordering::Acquire),
            self.remote_clipboard_enabled.load(Ordering::Acquire),
        ) {
            return;
        }
        let Some(callback) = self.callbacks.on_clipboard_rich_text else {
            return;
        };
        let (plain_utf8, plain_length) = optional_string_bytes(&rich.plain_text);
        let (rtf_utf8, rtf_length) = optional_string_bytes(&rich.rtf);
        let (html_utf8, html_length) = optional_string_bytes(&rich.html);
        let payload = RDNClipboardRichTextPayload {
            abi_version: ABI_VERSION,
            plain_utf8,
            plain_length,
            rtf_utf8,
            rtf_length,
            html_utf8,
            html_length,
        };
        unsafe { callback(self.context as *mut c_void, &payload) };
    }

    fn emit_clipboard_image(&self, image: NativeViewerClipboardImage) {
        if !clipboard_receive_allowed(
            self.active.load(Ordering::Acquire),
            self.authenticated.load(Ordering::Acquire),
            self.receive_clipboard_image.load(Ordering::Acquire),
            self.remote_clipboard_enabled.load(Ordering::Acquire),
        ) {
            return;
        }
        let Some(callback) = self.callbacks.on_clipboard_image else {
            return;
        };
        let (format, width, height) = match image.kind {
            NativeViewerClipboardImageKind::Rgba { width, height } => {
                (CLIPBOARD_IMAGE_FORMAT_RGBA, width, height)
            }
            NativeViewerClipboardImageKind::Png => (CLIPBOARD_IMAGE_FORMAT_PNG, 0, 0),
            NativeViewerClipboardImageKind::Svg => (CLIPBOARD_IMAGE_FORMAT_SVG, 0, 0),
        };
        let payload = RDNClipboardImagePayload {
            abi_version: ABI_VERSION,
            format,
            data: image.payload.as_ptr(),
            length: image.payload.len(),
            width,
            height,
        };
        unsafe { callback(self.context as *mut c_void, &payload) };
    }

    fn emit_file_transfer_list(
        &self,
        request: NativeViewerListRequest,
        status: u32,
        listing: &[NativeViewerRemoteListEntry],
    ) {
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != request.session_epoch
        {
            return;
        }
        let Some(callback) = self.callbacks.on_file_transfer_list else {
            return;
        };
        let entries: Vec<_> = listing
            .iter()
            .map(|entry| RDNFileTransferListEntry {
                kind: match entry.kind {
                    NativeViewerRemoteListEntryKind::Directory => {
                        FILE_TRANSFER_LIST_ENTRY_DIRECTORY
                    }
                    NativeViewerRemoteListEntryKind::File => FILE_TRANSFER_LIST_ENTRY_FILE,
                },
                relative_path_utf8: entry.relative_path.as_bytes().as_ptr(),
                relative_path_length: entry.relative_path.len(),
                size: entry.size,
                modified_time: entry.modified_time,
            })
            .collect();
        let event = RDNFileTransferListEvent {
            abi_version: ABI_VERSION,
            session_epoch: request.session_epoch,
            request_id: request.request_id,
            status,
            entries: if entries.is_empty() {
                ptr::null()
            } else {
                entries.as_ptr()
            },
            entry_count: entries.len(),
        };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn emit_file_transfer_manifest(
        &self,
        request: NativeViewerManifestRequest,
        status: u32,
        part: u32,
        listing: &[NativeViewerRemoteListEntry],
    ) {
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != request.session_epoch
        {
            return;
        }
        let Some(callback) = self.callbacks.on_file_transfer_manifest else {
            return;
        };
        let entries: Vec<_> = listing
            .iter()
            .map(|entry| RDNFileTransferListEntry {
                kind: match entry.kind {
                    NativeViewerRemoteListEntryKind::Directory => {
                        FILE_TRANSFER_LIST_ENTRY_DIRECTORY
                    }
                    NativeViewerRemoteListEntryKind::File => FILE_TRANSFER_LIST_ENTRY_FILE,
                },
                relative_path_utf8: entry.relative_path.as_bytes().as_ptr(),
                relative_path_length: entry.relative_path.len(),
                size: entry.size,
                modified_time: entry.modified_time,
            })
            .collect();
        let event = RDNFileTransferManifestEvent {
            abi_version: ABI_VERSION,
            session_epoch: request.session_epoch,
            request_id: request.request_id,
            status,
            part,
            entries: if entries.is_empty() {
                ptr::null()
            } else {
                entries.as_ptr()
            },
            entry_count: entries.len(),
        };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn emit_file_transfer_receive_block(&self, block: &NativeViewerReceiveBlock) -> bool {
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || block.session_epoch == 0
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != block.session_epoch
            || block.transfer_id <= 0
            || block.file_number as usize >= MAX_FILE_TRANSFER_LIST_ENTRIES
            || block.payload.is_empty()
            || block.payload.len() > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES
        {
            return false;
        }
        let Some(callback) = self.callbacks.on_file_transfer_receive_block else {
            return false;
        };
        let raw = RDNFileTransferReceiveBlock {
            abi_version: ABI_VERSION,
            session_epoch: block.session_epoch,
            transfer_id: block.transfer_id,
            file_number: block.file_number,
            data: block.payload.as_ptr(),
            length: block.payload.len(),
        };
        unsafe { callback(self.context as *mut c_void, &raw) };
        true
    }

    fn emit_display_catalog(&self, snapshot: NativeViewerDisplayCatalogSnapshot) {
        let Some(callback) = self.callbacks.on_display_catalog else {
            return;
        };
        let raw_entries: Vec<RDNDisplayCatalogEntry> = snapshot
            .entries
            .as_deref()
            .unwrap_or(&[])
            .iter()
            .map(|entry| RDNDisplayCatalogEntry {
                display_index: entry.display_index,
                x: entry.x,
                y: entry.y,
                width: entry.width,
                height: entry.height,
                online: entry.online,
                scale: entry.scale,
                name_utf8: if entry.name.is_empty() {
                    ptr::null()
                } else {
                    entry.name.as_ptr()
                },
                name_length: entry.name.len(),
            })
            .collect();
        let event = RDNDisplayCatalogEvent {
            abi_version: ABI_VERSION,
            connection_epoch: snapshot.connection_epoch,
            catalog_revision: snapshot.revision,
            status: if snapshot.entries.is_some() {
                DISPLAY_CATALOG_STATUS_AVAILABLE
            } else {
                DISPLAY_CATALOG_STATUS_UNAVAILABLE
            },
            selected_display_index: snapshot
                .selected_display_index
                .unwrap_or(DISPLAY_INDEX_UNKNOWN),
            selected_display_known: snapshot.selected_display_index.is_some(),
            entries: if raw_entries.is_empty() {
                ptr::null()
            } else {
                raw_entries.as_ptr()
            },
            entry_count: raw_entries.len(),
        };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn emit_display_selection(&self, snapshot: NativeViewerDisplaySelectionSnapshot) {
        let Some(callback) = self.callbacks.on_display_selection else {
            return;
        };
        let event = RDNDisplaySelectionEvent {
            abi_version: ABI_VERSION,
            connection_epoch: snapshot.pending.connection_epoch,
            command_id: snapshot.pending.command_id,
            catalog_revision: snapshot.pending.catalog_revision,
            display_index: snapshot.pending.display_index,
            result: snapshot.result,
            failure: snapshot.failure,
        };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn publish_display_catalog(&self, displays: &[DisplayInfo], selected: Option<Option<u32>>) {
        if !self.active.load(Ordering::Acquire)
            || self.file_transfer_enabled.load(Ordering::Acquire)
        {
            return;
        }
        let connection_epoch = self.connection_epoch.load(Ordering::Acquire);
        if connection_epoch == 0 {
            return;
        }
        let delivery = self.display_catalog_delivery.lock().unwrap();
        let normalized = normalized_native_viewer_display_catalog(displays).map(Arc::from);
        let mut state = self.display_catalog.lock().unwrap();
        let catalog_changed =
            !state.initialized || state.entries.as_deref() != normalized.as_deref();
        let selection_terminal = catalog_changed
            .then(|| {
                state
                    .pending_selection
                    .take()
                    .map(|pending| NativeViewerDisplaySelectionSnapshot {
                        pending,
                        result: DISPLAY_SELECTION_RESULT_FAILED,
                        failure: DISPLAY_SELECTION_FAILURE_CATALOG_CHANGED,
                    })
            })
            .flatten();
        if catalog_changed {
            state.initialized = true;
            state.revision = state.revision.saturating_add(1).max(1);
            state.entries = normalized;
        }
        let candidate = selected.unwrap_or(state.selected_display_index);
        let validated = state.entries.as_deref().and_then(|entries| {
            candidate.and_then(|index| {
                entries
                    .get(index as usize)
                    .filter(|entry| entry.display_index == index && entry.online)
                    .map(|_| index)
            })
        });
        let selection_changed = state.selected_display_index != validated;
        state.selected_display_index = validated;
        if !catalog_changed && !selection_changed {
            return;
        }
        let snapshot = NativeViewerDisplayCatalogSnapshot {
            connection_epoch,
            revision: state.revision,
            entries: state.entries.clone(),
            selected_display_index: state.selected_display_index,
        };
        drop(state);
        if let Some(terminal) = selection_terminal {
            self.emit_display_selection(terminal);
        }
        self.emit_display_catalog(snapshot);
        drop(delivery);
    }

    fn publish_selected_display(&self, display: i32, ingress: NativeViewerDisplaySelectionIngress) {
        if !self.active.load(Ordering::Acquire)
            || self.file_transfer_enabled.load(Ordering::Acquire)
        {
            return;
        }
        let connection_epoch = self.connection_epoch.load(Ordering::Acquire);
        if connection_epoch == 0 {
            return;
        }
        let delivery = self.display_catalog_delivery.lock().unwrap();
        let mut state = self.display_catalog.lock().unwrap();
        if !state.initialized {
            return;
        }
        let index = u32::try_from(display).ok();
        let valid_index = index.filter(|index| {
            state.entries.as_deref().is_some_and(|entries| {
                entries
                    .get(*index as usize)
                    .is_some_and(|entry| entry.display_index == *index && entry.online)
            })
        });
        let terminal = state.pending_selection.take().map(|pending| {
            let selected = matches!(ingress, NativeViewerDisplaySelectionIngress::SwitchEcho)
                && valid_index == Some(pending.display_index)
                && pending.connection_epoch == connection_epoch
                && pending.catalog_revision == state.revision;
            NativeViewerDisplaySelectionSnapshot {
                pending,
                result: if selected {
                    DISPLAY_SELECTION_RESULT_SELECTED
                } else {
                    DISPLAY_SELECTION_RESULT_FAILED
                },
                failure: if selected {
                    DISPLAY_SELECTION_FAILURE_NONE
                } else {
                    DISPLAY_SELECTION_FAILURE_REMOTE_SELECTION_DRIFT
                },
            }
        });
        let catalog_snapshot =
            if valid_index.is_some() && state.selected_display_index != valid_index {
                state.selected_display_index = valid_index;
                Some(NativeViewerDisplayCatalogSnapshot {
                    connection_epoch,
                    revision: state.revision,
                    entries: state.entries.clone(),
                    selected_display_index: state.selected_display_index,
                })
            } else {
                None
            };
        drop(state);
        if let Some(snapshot) = catalog_snapshot {
            self.emit_display_catalog(snapshot);
        }
        if let Some(terminal) = terminal {
            self.emit_display_selection(terminal);
        }
        drop(delivery);
    }

    fn terminate_display_selection(&self, failure: u32) {
        let delivery = self.display_catalog_delivery.lock().unwrap();
        let terminal = self
            .display_catalog
            .lock()
            .unwrap()
            .pending_selection
            .take()
            .map(|pending| NativeViewerDisplaySelectionSnapshot {
                pending,
                result: DISPLAY_SELECTION_RESULT_FAILED,
                failure,
            });
        if let Some(terminal) = terminal {
            self.emit_display_selection(terminal);
        }
        drop(delivery);
    }

    fn video_catalog_binding(&self, display: u32) -> Option<(u64, u64)> {
        if !self.active.load(Ordering::Acquire)
            || self.file_transfer_enabled.load(Ordering::Acquire)
        {
            return None;
        }
        let connection_epoch = self.connection_epoch.load(Ordering::Acquire);
        let state = self.display_catalog.lock().unwrap();
        (connection_epoch > 0
            && state.initialized
            && state.revision > 0
            && state.entries.is_some()
            && state.selected_display_index == Some(display))
        .then_some((connection_epoch, state.revision))
    }

    fn emit_video(&self, frame: &VideoFrame) -> bool {
        if !self.active.load(Ordering::Acquire) {
            return true;
        }
        let Some(callback) = self.callbacks.on_video else {
            return false;
        };
        let (codec, encoded_frames) = match frame.union.as_ref() {
            Some(video_frame::Union::H265s(frames)) => (RDNCodec::H265, frames),
            Some(video_frame::Union::H264s(frames)) => (RDNCodec::H264, frames),
            _ => return false,
        };
        let (width, height) = *self.dimensions.read().unwrap();
        let display = frame.display.max(0) as u32;
        let Some((connection_epoch, display_catalog_revision)) =
            self.video_catalog_binding(display)
        else {
            return true;
        };
        for encoded in encoded_frames.frames.iter() {
            let inspection = inspect_packet(&encoded.data);
            let mut flags = inspection.flags;
            if encoded.key {
                flags |= FLAG_KEYFRAME;
            }
            let packet = RDNEncodedVideoFrame {
                abi_version: ABI_VERSION,
                codec,
                packet_format: inspection.format,
                data: encoded.data.as_ptr(),
                length: encoded.data.len(),
                sequence: self.sequence.fetch_add(1, Ordering::Relaxed),
                timestamp_us: encoded.pts.max(0) as u64 * 1_000,
                flags,
                width,
                height,
                display,
                connection_epoch,
                display_catalog_revision,
            };
            // encoded.data is owned by the protobuf frame and remains valid only
            // for this synchronous callback. The Swift side copies compressed bytes.
            unsafe { callback(self.context as *mut c_void, &packet) };
        }
        true
    }
}

#[derive(Clone)]
struct BridgeUi {
    shared: Arc<BridgeShared>,
}

impl Default for BridgeUi {
    fn default() -> Self {
        Self {
            shared: Arc::new(BridgeShared {
                callbacks: RDNCallbacks {
                    abi_version: ABI_VERSION,
                    on_state: None,
                    on_remote_permission: None,
                    on_video: None,
                    on_display_catalog: None,
                    on_display_selection: None,
                    on_metrics: None,
                    on_clipboard_text: None,
                    on_clipboard_rich_text: None,
                    on_clipboard_image: None,
                    on_file_transfer_event: None,
                    on_file_transfer_list: None,
                    on_file_transfer_manifest: None,
                    on_file_transfer_receive_block: None,
                    on_file_transfer_upload_read: None,
                },
                context: 0,
                active: AtomicBool::new(false),
                terminal_retry_allowed: AtomicBool::new(true),
                sequence: AtomicU64::new(0),
                dimensions: RwLock::new((0, 0)),
                connection_epoch: AtomicU64::new(0),
                display_catalog: Mutex::new(NativeViewerDisplayCatalogState::default()),
                display_catalog_delivery: Mutex::new(()),
                authenticated: AtomicBool::new(false),
                remote_keyboard_enabled: AtomicBool::new(true),
                remote_audio_enabled: AtomicBool::new(true),
                input_allowed: AtomicBool::new(false),
                receive_clipboard_text: AtomicBool::new(false),
                send_clipboard_text: AtomicBool::new(false),
                receive_clipboard_rich_text: AtomicBool::new(false),
                send_clipboard_rich_text: AtomicBool::new(false),
                receive_clipboard_image: AtomicBool::new(false),
                send_clipboard_image: AtomicBool::new(false),
                remote_clipboard_enabled: AtomicBool::new(REMOTE_CLIPBOARD_ENABLED_BY_DEFAULT),
                remote_file_transfer_enabled: AtomicBool::new(false),
                file_transfer_enabled: AtomicBool::new(false),
                file_transfer_session_epoch: AtomicU64::new(0),
                pending_file_list_request: Mutex::new(None),
                file_manifest_request_epoch: AtomicU64::new(0),
                pending_file_manifest_request: Mutex::new(None),
                completed_file_manifest_request: Mutex::new(None),
                active_file_download_jobs: Mutex::new(HashMap::new()),
                active_file_upload_jobs: Mutex::new(HashMap::new()),
                file_upload_poll_cursor: AtomicU64::new(0),
            }),
        }
    }
}

fn viewer_terminal_error_state(text: &str, retry: bool) -> (i32, &'static str) {
    if !retry {
        return (TERMINAL_NO_RETRY_CODE, "connection-no-retry");
    }
    let lower = text.to_ascii_lowercase();
    if lower == "timeout" {
        (10, "connection-timeout")
    } else if lower.contains("reset by the peer") || lower.contains("connection reset") {
        (11, "connection-reset")
    } else if lower.contains("deadline") {
        (12, "connection-deadline")
    } else if lower.contains("broken pipe") {
        (13, "connection-broken-pipe")
    } else if lower.contains("closed") || lower.contains("eof") {
        (14, "connection-closed")
    } else {
        (3, "rustdesk-session-error")
    }
}

impl InvokeUiSession for BridgeUi {
    fn set_cursor_data(&self, _value: CursorData) {}
    fn set_cursor_id(&self, _value: String) {}
    fn set_cursor_position(&self, _value: CursorPosition) {}

    fn set_display(
        &self,
        _x: i32,
        _y: i32,
        width: i32,
        height: i32,
        _cursor_embedded: bool,
        _scale: f64,
    ) {
        *self.shared.dimensions.write().unwrap() = (width.max(0) as u32, height.max(0) as u32);
    }

    fn switch_display(&self, display: &SwitchDisplay) {
        *self.shared.dimensions.write().unwrap() =
            (display.width.max(0) as u32, display.height.max(0) as u32);
        self.shared.publish_selected_display(
            display.display,
            NativeViewerDisplaySelectionIngress::SwitchEcho,
        );
    }

    fn set_peer_info(&self, peer_info: &PeerInfo) {
        let selected = u32::try_from(peer_info.current_display).ok();
        self.shared
            .publish_display_catalog(&peer_info.displays, Some(selected));
    }
    fn set_displays(&self, displays: &Vec<DisplayInfo>) {
        self.shared.publish_display_catalog(displays, None);
    }
    fn set_platform_additions(&self, _data: &str) {}

    fn on_connected(&self, _conn_type: ConnType) {
        self.shared.authenticated.store(true, Ordering::Release);
        self.shared.emit_remote_audio_permission();
        let file_transfer = self.shared.file_transfer_enabled.load(Ordering::Acquire);
        let allowed = !file_transfer
            && input_is_allowed(
                true,
                self.shared.remote_keyboard_enabled.load(Ordering::Acquire),
            );
        self.shared.input_allowed.store(allowed, Ordering::Release);
        self.shared
            .emit_state(RDNState::Authenticated, 0, "authenticated");
        if file_transfer {
            self.shared.emit_file_transfer_ready_if_available();
        } else if allowed {
            self.shared
                .emit_state(RDNState::ControlReady, 0, "control-ready");
        }
    }

    fn update_privacy_mode(&self) {}
    fn set_permission(&self, name: &str, value: bool) {
        if name == "keyboard" {
            self.shared
                .remote_keyboard_enabled
                .store(value, Ordering::Release);
            let allowed = !self.shared.file_transfer_enabled.load(Ordering::Acquire)
                && input_is_allowed(self.shared.authenticated.load(Ordering::Acquire), value);
            self.shared.input_allowed.store(allowed, Ordering::Release);
            if allowed {
                self.shared
                    .emit_state(RDNState::ControlReady, 0, "control-ready");
            }
        } else if name == "clipboard" {
            self.shared
                .remote_clipboard_enabled
                .store(value, Ordering::Release);
        } else if name == "audio" {
            self.shared
                .remote_audio_enabled
                .store(value, Ordering::Release);
            self.shared.emit_remote_audio_permission();
        } else if name == "file" {
            let changed = self
                .shared
                .remote_file_transfer_enabled
                .swap(value, Ordering::AcqRel)
                != value;
            if value && changed {
                self.shared.emit_file_transfer_ready_if_available();
            }
        }
    }

    fn close_success(&self) {
        if !self.shared.file_transfer_enabled.load(Ordering::Acquire) {
            self.shared.emit_state(RDNState::Streaming, 0, "streaming");
        }
    }

    fn update_quality_status(&self, status: QualityStatus) {
        self.shared.emit_metrics(status);
    }

    fn set_connection_type(&self, secured: bool, direct: bool, _stream_type: &str) {
        let code = i32::from(secured) | (i32::from(direct) << 1);
        let message = match (secured, direct) {
            (true, true) => "transport-ready-secure-direct",
            (true, false) => "transport-ready-secure-relay",
            (false, true) => "transport-ready-insecure-direct",
            (false, false) => "transport-ready-insecure-relay",
        };
        self.shared
            .emit_state(RDNState::TransportReady, code, message);
    }

    fn set_fingerprint(&self, _fingerprint: String) {}
    fn job_error(&self, id: i32, _error: String, _file_num: i32) {
        let request = if id == 0 {
            self.shared.pending_file_list_request.lock().unwrap().take()
        } else {
            None
        };
        if let Some(request) = request {
            self.shared
                .emit_file_transfer_list(request, FILE_TRANSFER_LIST_UNAVAILABLE, &[]);
        }
        let manifest_request = {
            let mut pending = self.shared.pending_file_manifest_request.lock().unwrap();
            if pending
                .as_ref()
                .is_some_and(|request| id == 0 || request.request_id == id)
            {
                pending.take()
            } else {
                None
            }
        };
        if let Some(request) = manifest_request {
            client_clear_completed_manifest(&self.shared, request.session_epoch);
            self.shared.emit_file_transfer_manifest(
                request,
                FILE_TRANSFER_LIST_UNAVAILABLE,
                FILE_TRANSFER_MANIFEST_PART_FILES,
                &[],
            );
        }
        let event = self
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .remove(&id)
            .and_then(|job| {
                job.terminal(
                    FILE_TRANSFER_EVENT_FAILED,
                    FILE_TRANSFER_FAILURE_UNAVAILABLE,
                )
            });
        if let Some(event) = event {
            self.shared.emit_file_transfer_event(event);
        }
    }
    fn job_done(&self, id: i32, _file_num: i32) {
        let event = self
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .remove(&id)
            .and_then(|job| {
                job.terminal(FILE_TRANSFER_EVENT_COMPLETED, FILE_TRANSFER_FAILURE_NONE)
            });
        if let Some(event) = event {
            self.shared.emit_file_transfer_event(event);
        }
    }
    fn clear_all_jobs(&self) {
        self.shared.pending_file_list_request.lock().unwrap().take();
        self.shared
            .pending_file_manifest_request
            .lock()
            .unwrap()
            .take();
        self.shared
            .completed_file_manifest_request
            .lock()
            .unwrap()
            .take();
        self.shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .clear();
        self.shared.active_file_upload_jobs.lock().unwrap().clear();
    }
    fn new_message(&self, _message: String) {}
    fn update_transfer_list(&self) {}
    fn load_last_job(&self, _count: i32, _json: &str, _auto_start: bool) {}

    fn update_folder_files(
        &self,
        id: i32,
        entries: &Vec<FileEntry>,
        path: String,
        is_local: bool,
        only_count: bool,
    ) {
        if id > 0 {
            let request = {
                let pending = self.shared.pending_file_manifest_request.lock().unwrap();
                pending
                    .as_ref()
                    .filter(|request| request.request_id == id)
                    .cloned()
            };
            let Some(request) = request else { return };
            if is_local || only_count || path != "/" {
                self.shared
                    .pending_file_manifest_request
                    .lock()
                    .unwrap()
                    .take();
                client_clear_completed_manifest(&self.shared, request.session_epoch);
                self.shared.emit_file_transfer_manifest(
                    request,
                    FILE_TRANSFER_LIST_REJECTED,
                    FILE_TRANSFER_MANIFEST_PART_FILES,
                    &[],
                );
                return;
            }
            let Some(listing) = native_viewer_remote_manifest_files(entries) else {
                self.shared
                    .pending_file_manifest_request
                    .lock()
                    .unwrap()
                    .take();
                client_clear_completed_manifest(&self.shared, request.session_epoch);
                self.shared.emit_file_transfer_manifest(
                    request,
                    FILE_TRANSFER_LIST_REJECTED,
                    FILE_TRANSFER_MANIFEST_PART_FILES,
                    &[],
                );
                return;
            };
            let Some(total_bytes) = listing
                .iter()
                .try_fold(0u64, |total, entry| total.checked_add(entry.size))
            else {
                self.shared
                    .pending_file_manifest_request
                    .lock()
                    .unwrap()
                    .take();
                client_clear_completed_manifest(&self.shared, request.session_epoch);
                self.shared.emit_file_transfer_manifest(
                    request,
                    FILE_TRANSFER_LIST_REJECTED,
                    FILE_TRANSFER_MANIFEST_PART_FILES,
                    &[],
                );
                return;
            };
            let total_files = listing.len() as u32;
            let files = listing
                .iter()
                .map(|entry| NativeViewerManifestFileAuthority {
                    size: entry.size,
                    modified_time: entry.modified_time,
                })
                .collect();
            let (duplicate, completed) = {
                let mut pending = self.shared.pending_file_manifest_request.lock().unwrap();
                let Some(active) = pending.as_mut() else {
                    return;
                };
                if active.request_id != id || active.files_delivered {
                    pending.take();
                    (true, None)
                } else {
                    active.files_delivered = true;
                    active.total_files = Some(total_files);
                    active.total_bytes = Some(total_bytes);
                    active.files = Some(files);
                    if active.empty_directories_delivered {
                        let completed = pending.take().and_then(|request| {
                            Some(NativeViewerCompletedManifest {
                                session_epoch: request.session_epoch,
                                request_id: request.request_id,
                                total_files: request.total_files?,
                                total_bytes: request.total_bytes?,
                                files: request.files?.into(),
                            })
                        });
                        (false, completed)
                    } else {
                        (false, None)
                    }
                }
            };
            if let Some(completed) = completed {
                *self.shared.completed_file_manifest_request.lock().unwrap() = Some(completed);
            } else if duplicate {
                client_clear_completed_manifest(&self.shared, request.session_epoch);
            }
            self.shared.emit_file_transfer_manifest(
                request,
                if duplicate {
                    FILE_TRANSFER_LIST_REJECTED
                } else {
                    FILE_TRANSFER_LIST_SUCCESS
                },
                FILE_TRANSFER_MANIFEST_PART_FILES,
                if duplicate { &[] } else { &listing },
            );
            return;
        }
        let request = self.shared.pending_file_list_request.lock().unwrap().take();
        let Some(request) = request else { return };
        if is_local || only_count || path != "/" {
            self.shared
                .emit_file_transfer_list(request, FILE_TRANSFER_LIST_REJECTED, &[]);
            return;
        }
        match native_viewer_remote_listing(entries) {
            Some(listing) => {
                self.shared
                    .emit_file_transfer_list(request, FILE_TRANSFER_LIST_SUCCESS, &listing)
            }
            None => self
                .shared
                .emit_file_transfer_list(request, FILE_TRANSFER_LIST_REJECTED, &[]),
        }
    }

    fn update_empty_dirs(&self, response: ReadEmptyDirsResponse) {
        let request = {
            let pending = self.shared.pending_file_manifest_request.lock().unwrap();
            pending.as_ref().cloned()
        };
        let Some(request) = request else { return };
        let Some(listing) = native_viewer_remote_manifest_empty_directories(&response) else {
            self.shared
                .pending_file_manifest_request
                .lock()
                .unwrap()
                .take();
            client_clear_completed_manifest(&self.shared, request.session_epoch);
            self.shared.emit_file_transfer_manifest(
                request,
                FILE_TRANSFER_LIST_REJECTED,
                FILE_TRANSFER_MANIFEST_PART_EMPTY_DIRECTORIES,
                &[],
            );
            return;
        };
        let (duplicate, completed) = {
            let mut pending = self.shared.pending_file_manifest_request.lock().unwrap();
            let Some(active) = pending.as_mut() else {
                return;
            };
            if active.empty_directories_delivered {
                pending.take();
                (true, None)
            } else {
                active.empty_directories_delivered = true;
                if active.files_delivered {
                    let completed = pending.take().and_then(|request| {
                        Some(NativeViewerCompletedManifest {
                            session_epoch: request.session_epoch,
                            request_id: request.request_id,
                            total_files: request.total_files?,
                            total_bytes: request.total_bytes?,
                            files: request.files?.into(),
                        })
                    });
                    (false, completed)
                } else {
                    (false, None)
                }
            }
        };
        if let Some(completed) = completed {
            *self.shared.completed_file_manifest_request.lock().unwrap() = Some(completed);
        } else if duplicate {
            client_clear_completed_manifest(&self.shared, request.session_epoch);
        }
        self.shared.emit_file_transfer_manifest(
            request,
            if duplicate {
                FILE_TRANSFER_LIST_REJECTED
            } else {
                FILE_TRANSFER_LIST_SUCCESS
            },
            FILE_TRANSFER_MANIFEST_PART_EMPTY_DIRECTORIES,
            if duplicate { &[] } else { &listing },
        );
    }

    fn confirm_delete_files(&self, _id: i32, _index: i32, _name: String) {}

    fn override_file_confirm(
        &self,
        _id: i32,
        _file_num: i32,
        _path: String,
        _is_upload: bool,
        _is_identical: bool,
    ) {
    }

    fn update_block_input_state(&self, _on: bool) {}
    fn job_progress(&self, id: i32, file_num: i32, speed: f64, finished_size: f64) {
        let event = self
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .get_mut(&id)
            .and_then(|job| job.progress(file_num, speed, finished_size));
        if let Some(event) = event {
            self.shared.emit_file_transfer_event(event);
        }
    }
    fn adapt_size(&self) {}
    fn on_rgba(&self, _display: usize, _rgba: &mut scrap::ImageRgb) {}

    fn msgbox(&self, message_type: &str, _title: &str, text: &str, _link: &str, retry: bool) {
        match message_type {
            "input-password" => {
                self.shared
                    .emit_state(RDNState::PasswordRequired, 1, "password-required")
            }
            "re-input-password" | "input-2fa" => {
                self.shared
                    .emit_state(RDNState::AuthenticationFailed, 2, "authentication-failed")
            }
            "success" => {}
            _ => {
                if !retry {
                    self.shared
                        .terminal_retry_allowed
                        .store(false, Ordering::Release);
                }
                let (code, message) = viewer_terminal_error_state(text, retry);
                self.shared.emit_state(RDNState::Error, code, message)
            }
        }
    }

    fn cancel_msgbox(&self, _tag: &str) {}
    fn switch_back(&self, _id: &str) {}
    fn portable_service_running(&self, _running: bool) {}
    fn on_voice_call_started(&self) {}
    fn on_voice_call_closed(&self, _reason: &str) {}
    fn on_voice_call_waiting(&self) {}
    fn on_voice_call_incoming(&self) {}
    fn get_rgba(&self, _display: usize) -> *const u8 {
        ptr::null()
    }
    fn next_rgba(&self, _display: usize) {}
    fn set_multiple_windows_session(&self, _sessions: Vec<WindowsSession>) {}
    fn set_current_display(&self, display: i32) {
        self.shared
            .publish_selected_display(display, NativeViewerDisplaySelectionIngress::RemoteFollow);
    }
    fn update_record_status(&self, _start: bool) {}
    fn printer_request(&self, _id: i32, _path: String) {}
    fn handle_screenshot_resp(&self, _sid: String, _message: String) {}
    fn handle_terminal_response(&self, _response: TerminalResponse) {}

    fn on_encoded_video(&self, frame: &VideoFrame) -> bool {
        self.shared.emit_video(frame)
    }

    fn native_clipboard_text(&self, text: String) {
        self.shared.emit_clipboard_text(&text);
    }

    fn native_clipboard_rich_text_enabled(&self) -> bool {
        clipboard_receive_allowed(
            self.shared.active.load(Ordering::Acquire),
            self.shared.authenticated.load(Ordering::Acquire),
            self.shared
                .receive_clipboard_rich_text
                .load(Ordering::Acquire),
            self.shared.remote_clipboard_enabled.load(Ordering::Acquire),
        )
    }

    fn native_clipboard_rich_text(
        &self,
        plain_text: Option<String>,
        rtf: Option<String>,
        html: Option<String>,
    ) {
        self.shared
            .emit_clipboard_rich_text(NativeViewerRichTextBundle {
                plain_text,
                rtf,
                html,
            });
    }

    fn native_clipboard_image_enabled(&self) -> bool {
        clipboard_receive_allowed(
            self.shared.active.load(Ordering::Acquire),
            self.shared.authenticated.load(Ordering::Acquire),
            self.shared.receive_clipboard_image.load(Ordering::Acquire),
            self.shared.remote_clipboard_enabled.load(Ordering::Acquire),
        )
    }

    fn native_clipboard_image(&self, image: NativeViewerClipboardImage) {
        self.shared.emit_clipboard_image(image);
    }

    fn native_file_transfer_download_digest_confirmation(
        &self,
        digest: &FileTransferDigest,
    ) -> (bool, Option<FileTransferSendConfirmRequest>) {
        let mut jobs = self.shared.active_file_download_jobs.lock().unwrap();
        let Some(job) = jobs.get_mut(&digest.id) else {
            return (false, None);
        };
        (true, job.confirm_digest(digest))
    }

    fn native_file_transfer_receive_block(&self, block: &FileTransferBlock) -> bool {
        let job = {
            let jobs = self.shared.active_file_download_jobs.lock().unwrap();
            let Some(job) = jobs.get(&block.id) else {
                return false;
            };
            job.clone()
        };
        let semantic = job.receive_block(block);
        if let Some(block) = semantic {
            self.shared.emit_file_transfer_receive_block(&block);
        }
        true
    }

    fn native_file_transfer_upload_poll_interval_ms(&self) -> u64 {
        self.shared.file_transfer_upload_poll_interval_ms()
    }

    fn native_file_transfer_upload_poll(&self) -> Option<Message> {
        self.shared.file_transfer_upload_poll()
    }

    fn native_file_transfer_upload_confirmation(
        &self,
        request: &FileTransferSendConfirmRequest,
    ) -> (bool, Vec<Message>) {
        self.shared.file_transfer_upload_confirmation(request)
    }

    fn native_file_transfer_upload_existing_target(
        &self,
        digest: &FileTransferDigest,
    ) -> (bool, Vec<Message>) {
        self.shared.file_transfer_upload_existing_target(digest)
    }

    fn native_file_transfer_upload_done(&self, done: &FileTransferDone) -> (bool, Vec<Message>) {
        self.shared.file_transfer_upload_done(done)
    }

    fn native_file_transfer_upload_error(&self, error: &FileTransferError) -> (bool, Vec<Message>) {
        self.shared.file_transfer_upload_error(error)
    }
}

pub struct RDNClient {
    shared: Arc<BridgeShared>,
    session: Mutex<Option<Session<BridgeUi>>>,
    worker: Mutex<Option<JoinHandle<()>>>,
    housekeeping: Mutex<Option<JoinHandle<()>>>,
}

impl RDNClient {
    fn disconnect(&self, emit_state: bool) {
        self.shared
            .terminate_display_selection(DISPLAY_SELECTION_FAILURE_CONNECTION_CLOSED);
        self.shared.authenticated.store(false, Ordering::Release);
        self.shared.input_allowed.store(false, Ordering::Release);
        self.shared
            .receive_clipboard_text
            .store(false, Ordering::Release);
        self.shared
            .send_clipboard_text
            .store(false, Ordering::Release);
        self.shared
            .receive_clipboard_rich_text
            .store(false, Ordering::Release);
        self.shared
            .send_clipboard_rich_text
            .store(false, Ordering::Release);
        self.shared
            .receive_clipboard_image
            .store(false, Ordering::Release);
        self.shared
            .send_clipboard_image
            .store(false, Ordering::Release);
        self.shared
            .remote_clipboard_enabled
            .store(false, Ordering::Release);
        self.shared
            .remote_file_transfer_enabled
            .store(false, Ordering::Release);
        self.shared
            .file_transfer_enabled
            .store(false, Ordering::Release);
        self.shared
            .file_transfer_session_epoch
            .store(0, Ordering::Release);
        self.shared.connection_epoch.store(0, Ordering::Release);
        *self.shared.display_catalog.lock().unwrap() = NativeViewerDisplayCatalogState::default();
        self.shared.pending_file_list_request.lock().unwrap().take();
        self.shared
            .file_manifest_request_epoch
            .store(0, Ordering::Release);
        self.shared
            .pending_file_manifest_request
            .lock()
            .unwrap()
            .take();
        self.shared
            .completed_file_manifest_request
            .lock()
            .unwrap()
            .take();
        self.shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .clear();
        self.shared.active_file_upload_jobs.lock().unwrap().clear();
        self.shared.active.store(false, Ordering::Release);
        if let Some(session) = self.session.lock().unwrap().as_ref() {
            if let Some(sender) = session.sender.read().unwrap().as_ref() {
                let _ = sender.send(Data::Close);
            }
        }
        if let Some(worker) = self.worker.lock().unwrap().take() {
            let _ = worker.join();
        }
        if let Some(housekeeping) = self.housekeeping.lock().unwrap().take() {
            let _ = housekeeping.join();
        }
        self.session.lock().unwrap().take();
        if emit_state {
            self.shared
                .emit_state_unchecked(RDNState::Disconnected, 0, "disconnected");
        }
    }
}

fn housekeeping_message() -> Message {
    let mut delay = TestDelay::new();
    delay.from_client = true;
    let mut message = Message::new();
    message.set_test_delay(delay);
    message
}

fn native_stream_fps(force_relay: bool) -> i32 {
    // RustDesk's own adaptive controller leaves more scheduling margin on a
    // relay (4/5 of decoder rate) than on a direct connection (9/10).
    if force_relay {
        38
    } else {
        36
    }
}

fn input_is_allowed(authenticated: bool, remote_keyboard_enabled: bool) -> bool {
    authenticated && remote_keyboard_enabled
}

fn clipboard_receive_allowed(
    active: bool,
    authenticated: bool,
    local_receive_enabled: bool,
    remote_clipboard_enabled: bool,
) -> bool {
    active && authenticated && local_receive_enabled && remote_clipboard_enabled
}

fn optional_string_bytes(value: &Option<String>) -> (*const u8, usize) {
    value.as_ref().map_or((ptr::null(), 0), |text| {
        (text.as_bytes().as_ptr(), text.len())
    })
}

fn decoded_clipboard_utf8(clipboard: &Clipboard, max_bytes: usize) -> Option<String> {
    if !clipboard.special_name.is_empty()
        || clipboard.width != 0
        || clipboard.height != 0
        || clipboard.content.is_empty()
        || clipboard.content.len() > max_bytes
    {
        return None;
    }
    let bytes = if clipboard.compress {
        hbb_common::compress::decompress_with_limit(&clipboard.content, max_bytes).ok()?
    } else {
        clipboard.content.to_vec()
    };
    let text = String::from_utf8(bytes).ok()?;
    (!text.is_empty() && text.len() <= max_bytes && !text.contains('\0')).then_some(text)
}

pub(crate) fn native_viewer_clipboard_text(clipboards: &[Clipboard]) -> Option<String> {
    let clipboard = match clipboards {
        [clipboard] => clipboard,
        _ => return None,
    };
    if clipboard.format.enum_value() != Ok(ClipboardFormat::Text) {
        return None;
    }
    decoded_clipboard_utf8(clipboard, MAX_CLIPBOARD_TEXT_UTF8_BYTES)
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct NativeViewerRichTextBundle {
    pub(crate) plain_text: Option<String>,
    pub(crate) rtf: Option<String>,
    pub(crate) html: Option<String>,
}

pub(crate) fn native_viewer_clipboard_rich_text(
    clipboards: &[Clipboard],
) -> Option<NativeViewerRichTextBundle> {
    if clipboards.is_empty() || clipboards.len() > 3 {
        return None;
    }
    let mut bundle = NativeViewerRichTextBundle::default();
    for clipboard in clipboards {
        match clipboard.format.enum_value().ok()? {
            ClipboardFormat::Text => {
                if bundle.plain_text.is_some() {
                    return None;
                }
                bundle.plain_text = Some(decoded_clipboard_utf8(
                    clipboard,
                    MAX_CLIPBOARD_TEXT_UTF8_BYTES,
                )?);
            }
            ClipboardFormat::Rtf => {
                if bundle.rtf.is_some() {
                    return None;
                }
                bundle.rtf = Some(decoded_clipboard_utf8(
                    clipboard,
                    MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
                )?);
            }
            ClipboardFormat::Html => {
                if bundle.html.is_some() {
                    return None;
                }
                bundle.html = Some(decoded_clipboard_utf8(
                    clipboard,
                    MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
                )?);
            }
            _ => return None,
        }
    }
    (bundle.rtf.is_some() || bundle.html.is_some()).then_some(bundle)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeViewerClipboardImageKind {
    Rgba { width: u32, height: u32 },
    Png,
    Svg,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NativeViewerClipboardImage {
    pub(crate) kind: NativeViewerClipboardImageKind,
    pub(crate) payload: Vec<u8>,
}

pub(crate) fn native_viewer_clipboard_image(
    clipboards: &[Clipboard],
) -> Option<NativeViewerClipboardImage> {
    let clipboard = match clipboards {
        [clipboard] if clipboard.special_name.is_empty() => clipboard,
        _ => return None,
    };
    match clipboard.format.enum_value().ok()? {
        ClipboardFormat::ImageRgba => {
            let width = u32::try_from(clipboard.width).ok()?;
            let height = u32::try_from(clipboard.height).ok()?;
            let pixel_count = native_viewer_image_pixel_count(width, height)?;
            let expected_bytes = pixel_count.checked_mul(4)?;
            let payload = native_viewer_image_payload_bytes(
                clipboard,
                MAX_CLIPBOARD_IMAGE_BYTES,
                MAX_CLIPBOARD_IMAGE_BYTES,
                true,
            )?;
            (payload.len() == expected_bytes).then_some(NativeViewerClipboardImage {
                kind: NativeViewerClipboardImageKind::Rgba { width, height },
                payload,
            })
        }
        ClipboardFormat::ImagePng => {
            if clipboard.compress || clipboard.width != 0 || clipboard.height != 0 {
                return None;
            }
            let payload = native_viewer_image_payload_bytes(
                clipboard,
                MAX_CLIPBOARD_IMAGE_BYTES,
                MAX_CLIPBOARD_IMAGE_BYTES,
                false,
            )?;
            native_viewer_png_dimensions(&payload)?;
            Some(NativeViewerClipboardImage {
                kind: NativeViewerClipboardImageKind::Png,
                payload,
            })
        }
        ClipboardFormat::ImageSvg => {
            if clipboard.width != 0 || clipboard.height != 0 {
                return None;
            }
            let payload = native_viewer_image_payload_bytes(
                clipboard,
                MAX_CLIPBOARD_SVG_UTF8_BYTES,
                MAX_CLIPBOARD_SVG_UTF8_BYTES,
                true,
            )?;
            native_viewer_svg_has_canonical_root(&payload)?;
            Some(NativeViewerClipboardImage {
                kind: NativeViewerClipboardImageKind::Svg,
                payload,
            })
        }
        _ => None,
    }
}

fn native_viewer_image_payload_bytes(
    clipboard: &Clipboard,
    wire_limit: usize,
    decoded_limit: usize,
    allow_compressed: bool,
) -> Option<Vec<u8>> {
    if clipboard.content.is_empty() || clipboard.content.len() > wire_limit {
        return None;
    }
    let payload = if clipboard.compress {
        if !allow_compressed {
            return None;
        }
        hbb_common::compress::decompress_with_limit(&clipboard.content, decoded_limit).ok()?
    } else {
        clipboard.content.to_vec()
    };
    (!payload.is_empty() && payload.len() <= decoded_limit).then_some(payload)
}

fn native_viewer_image_pixel_count(width: u32, height: u32) -> Option<usize> {
    if width == 0
        || height == 0
        || width > MAX_CLIPBOARD_IMAGE_DIMENSION as u32
        || height > MAX_CLIPBOARD_IMAGE_DIMENSION as u32
    {
        return None;
    }
    let pixels = usize::try_from(width)
        .ok()?
        .checked_mul(usize::try_from(height).ok()?)?;
    (pixels <= MAX_CLIPBOARD_IMAGE_PIXELS).then_some(pixels)
}

fn native_viewer_png_dimensions(payload: &[u8]) -> Option<(u32, u32)> {
    const SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
    if payload.len() < 33 || payload.get(..8)? != SIGNATURE {
        return None;
    }

    let mut offset = 8usize;
    let mut dimensions = None;
    let mut has_image_data = false;
    loop {
        let header_end = offset.checked_add(8)?;
        if header_end > payload.len() {
            return None;
        }
        let length = u32::from_be_bytes(payload[offset..offset + 4].try_into().ok()?) as usize;
        let chunk_type = &payload[offset + 4..header_end];
        let chunk_end = header_end.checked_add(length)?.checked_add(4)?;
        if chunk_end > payload.len() {
            return None;
        }
        let data = &payload[header_end..header_end + length];
        match chunk_type {
            b"IHDR" if offset == 8 && length == 13 && dimensions.is_none() => {
                let width = u32::from_be_bytes(data[0..4].try_into().ok()?);
                let height = u32::from_be_bytes(data[4..8].try_into().ok()?);
                native_viewer_image_pixel_count(width, height)?;
                let bit_depth = data[8];
                let color_type = data[9];
                let valid_depth = match color_type {
                    0 => matches!(bit_depth, 1 | 2 | 4 | 8 | 16),
                    2 | 4 | 6 => matches!(bit_depth, 8 | 16),
                    3 => matches!(bit_depth, 1 | 2 | 4 | 8),
                    _ => false,
                };
                if !valid_depth || data[10] != 0 || data[11] != 0 || data[12] > 1 {
                    return None;
                }
                dimensions = Some((width, height));
            }
            b"IHDR" => return None,
            b"IDAT" if dimensions.is_some() && length > 0 => has_image_data = true,
            b"IEND" if length == 0 => {
                return (chunk_end == payload.len() && has_image_data).then_some(dimensions?)
            }
            _ if dimensions.is_none() => return None,
            _ => {}
        }
        offset = chunk_end;
    }
}

fn native_viewer_svg_has_canonical_root(payload: &[u8]) -> Option<()> {
    let svg = std::str::from_utf8(payload).ok()?;
    if svg.contains('\0') {
        return None;
    }
    let mut remainder = svg.trim_start_matches(['\u{feff}', ' ', '\t', '\r', '\n']);
    if remainder.starts_with("<?xml") {
        let end = remainder.get(..1024.min(remainder.len()))?.find("?>")?;
        remainder = remainder[end + 2..].trim_start();
    }
    if remainder
        .as_bytes()
        .windows(9)
        .any(|window| window.eq_ignore_ascii_case(b"<!doctype"))
    {
        return None;
    }
    let after_root = remainder.strip_prefix("<svg")?;
    (after_root
        .as_bytes()
        .first()
        .is_some_and(|byte| byte.is_ascii_whitespace() || *byte == b'>')
        && after_root.contains('>'))
    .then_some(())
}

unsafe fn native_viewer_clipboard_image_message(
    payload: &RDNClipboardImagePayload,
) -> Option<Message> {
    if payload.abi_version != ABI_VERSION || payload.data.is_null() || payload.length == 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload.data, payload.length) };
    let (format, width, height) = match payload.format {
        CLIPBOARD_IMAGE_FORMAT_RGBA => {
            let pixel_count = native_viewer_image_pixel_count(payload.width, payload.height)?;
            let expected_bytes = pixel_count.checked_mul(4)?;
            if bytes.len() > MAX_CLIPBOARD_IMAGE_BYTES || bytes.len() != expected_bytes {
                return None;
            }
            (
                ClipboardFormat::ImageRgba,
                i32::try_from(payload.width).ok()?,
                i32::try_from(payload.height).ok()?,
            )
        }
        CLIPBOARD_IMAGE_FORMAT_PNG => {
            if payload.width != 0 || payload.height != 0 || bytes.len() > MAX_CLIPBOARD_IMAGE_BYTES
            {
                return None;
            }
            native_viewer_png_dimensions(bytes)?;
            (ClipboardFormat::ImagePng, 0, 0)
        }
        CLIPBOARD_IMAGE_FORMAT_SVG => {
            if payload.width != 0
                || payload.height != 0
                || bytes.len() > MAX_CLIPBOARD_SVG_UTF8_BYTES
            {
                return None;
            }
            native_viewer_svg_has_canonical_root(bytes)?;
            (ClipboardFormat::ImageSvg, 0, 0)
        }
        _ => return None,
    };
    let mut message = Message::new();
    message.set_clipboard(Clipboard {
        content: bytes.to_vec().into(),
        format: format.into(),
        width,
        height,
        ..Default::default()
    });
    Some(message)
}

fn native_viewer_clipboard_message(bytes: &[u8]) -> Option<Message> {
    let text = validated_clipboard_text(bytes)?;
    let mut message = Message::new();
    message.set_clipboard(Clipboard {
        content: text.as_bytes().to_vec().into(),
        format: ClipboardFormat::Text.into(),
        ..Default::default()
    });
    Some(message)
}

fn validated_clipboard_text(bytes: &[u8]) -> Option<&str> {
    if bytes.is_empty() || bytes.len() > MAX_CLIPBOARD_TEXT_UTF8_BYTES {
        return None;
    }
    std::str::from_utf8(bytes)
        .ok()
        .filter(|text| !text.contains('\0'))
}

unsafe fn optional_clipboard_utf8(
    utf8: *const u8,
    length: usize,
    max_bytes: usize,
) -> Option<Option<String>> {
    if utf8.is_null() {
        return (length == 0).then_some(None);
    }
    if length == 0 || length > max_bytes {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(utf8, length) };
    let text = String::from_utf8(bytes.to_vec()).ok()?;
    (!text.contains('\0')).then_some(Some(text))
}

unsafe fn native_viewer_clipboard_rich_text_message(
    payload: &RDNClipboardRichTextPayload,
) -> Option<Message> {
    if payload.abi_version != ABI_VERSION {
        return None;
    }
    let plain_text = unsafe {
        optional_clipboard_utf8(
            payload.plain_utf8,
            payload.plain_length,
            MAX_CLIPBOARD_TEXT_UTF8_BYTES,
        )?
    };
    let rtf = unsafe {
        optional_clipboard_utf8(
            payload.rtf_utf8,
            payload.rtf_length,
            MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
        )?
    };
    let html = unsafe {
        optional_clipboard_utf8(
            payload.html_utf8,
            payload.html_length,
            MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
        )?
    };
    if rtf.is_none() && html.is_none() {
        return None;
    }

    let mut clipboards = Vec::with_capacity(3);
    for (format, text) in [
        (ClipboardFormat::Text, plain_text),
        (ClipboardFormat::Rtf, rtf),
        (ClipboardFormat::Html, html),
    ] {
        if let Some(text) = text {
            clipboards.push(Clipboard {
                content: text.into_bytes().into(),
                format: format.into(),
                ..Default::default()
            });
        }
    }
    let mut message = Message::new();
    if clipboards.len() == 1 {
        message.set_clipboard(clipboards.remove(0));
    } else {
        message.set_multi_clipboards(MultiClipboards {
            clipboards,
            ..Default::default()
        });
    }
    Some(message)
}

fn native_stream_configuration_message(custom_fps: i32) -> Message {
    let mut misc = Misc::new();
    misc.set_option(OptionMessage {
        // The native bridge consumes encoded frames before RustDesk creates its
        // decoder thread, so upstream fps_control has no decode rate from which
        // to publish an automatic cap. The Swift/VideoToolbox path is validated
        // for the normal desktop maximum and reports its own backpressure. A
        // 36 FPS capture ceiling leaves scheduling headroom for a 30 Hz source;
        // the host still only emits frames when the display content changes.
        custom_fps,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_misc(misc);
    message
}

unsafe fn required_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        return Err(-3);
    }
    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| -3)
}

unsafe fn optional_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        Ok(String::new())
    } else {
        required_string(pointer)
    }
}

fn native_viewer_remote_listing(entries: &[FileEntry]) -> Option<Vec<NativeViewerRemoteListEntry>> {
    if entries.len() > MAX_FILE_TRANSFER_LIST_ENTRIES {
        return None;
    }
    let mut metadata_utf8_bytes = 0usize;
    let mut collision_keys = HashSet::with_capacity(entries.len());
    let mut normalized = Vec::with_capacity(entries.len());
    for entry in entries {
        let name = entry.name.as_str();
        if name.is_empty()
            || name == "."
            || name == ".."
            || name.starts_with('/')
            || name.ends_with('/')
            || name.contains('/')
            || name.contains('\\')
            || name.chars().any(char::is_control)
            || name
                .to_ascii_lowercase()
                .ends_with(FILE_TRANSFER_PRIVATE_STAGING_SUFFIX)
        {
            return None;
        }
        metadata_utf8_bytes = metadata_utf8_bytes.checked_add(name.len())?;
        if metadata_utf8_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES {
            return None;
        }
        if !collision_keys.insert(name.to_ascii_lowercase()) {
            return None;
        }
        if entry.is_hidden {
            return None;
        }
        let kind = match entry.entry_type.enum_value() {
            Ok(FileType::Dir) if entry.size == 0 => NativeViewerRemoteListEntryKind::Directory,
            Ok(FileType::File) => NativeViewerRemoteListEntryKind::File,
            _ => return None,
        };
        normalized.push(NativeViewerRemoteListEntry {
            kind,
            relative_path: name.to_owned(),
            size: entry.size,
            modified_time: entry.modified_time,
        });
    }
    Some(normalized)
}

fn native_viewer_manifest_relative_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.ends_with('/')
        && !path.contains('\\')
        && !path.chars().any(char::is_control)
        && path.split('/').all(|component| {
            !component.is_empty()
                && component != "."
                && component != ".."
                && !component
                    .to_ascii_lowercase()
                    .ends_with(FILE_TRANSFER_PRIVATE_STAGING_SUFFIX)
        })
}

fn native_viewer_remote_manifest_files(
    entries: &[FileEntry],
) -> Option<Vec<NativeViewerRemoteListEntry>> {
    if entries.len() > MAX_FILE_TRANSFER_LIST_ENTRIES {
        return None;
    }
    let mut metadata_utf8_bytes = 0usize;
    let mut collision_keys = HashSet::with_capacity(entries.len());
    let mut normalized = Vec::with_capacity(entries.len());
    for entry in entries {
        let path = entry.name.as_str();
        if entry.is_hidden
            || entry.entry_type.enum_value() != Ok(FileType::File)
            || !native_viewer_manifest_relative_path(path)
        {
            return None;
        }
        metadata_utf8_bytes = metadata_utf8_bytes.checked_add(path.len())?;
        if metadata_utf8_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES
            || !collision_keys.insert(path.to_ascii_lowercase())
        {
            return None;
        }
        normalized.push(NativeViewerRemoteListEntry {
            kind: NativeViewerRemoteListEntryKind::File,
            relative_path: path.to_owned(),
            size: entry.size,
            modified_time: entry.modified_time,
        });
    }
    Some(normalized)
}

fn native_viewer_remote_manifest_empty_directories(
    response: &ReadEmptyDirsResponse,
) -> Option<Vec<NativeViewerRemoteListEntry>> {
    if response.path != "/" || response.empty_dirs.len() > MAX_FILE_TRANSFER_LIST_ENTRIES {
        return None;
    }
    let mut metadata_utf8_bytes = 0usize;
    let mut collision_keys = HashSet::with_capacity(response.empty_dirs.len());
    let mut normalized = Vec::with_capacity(response.empty_dirs.len());
    for directory in &response.empty_dirs {
        let wire_path = directory.path.as_str();
        let path = wire_path.strip_prefix('/')?;
        if directory.id != 0
            || !directory.entries.is_empty()
            || !native_viewer_manifest_relative_path(path)
        {
            return None;
        }
        metadata_utf8_bytes = metadata_utf8_bytes.checked_add(path.len())?;
        if metadata_utf8_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES
            || !collision_keys.insert(path.to_ascii_lowercase())
        {
            return None;
        }
        normalized.push(NativeViewerRemoteListEntry {
            kind: NativeViewerRemoteListEntryKind::Directory,
            relative_path: path.to_owned(),
            size: 0,
            modified_time: 0,
        });
    }
    Some(normalized)
}

fn native_viewer_upload_directory_projection(leaves: &[String]) -> Option<Vec<String>> {
    let mut projected = HashSet::new();
    for leaf in leaves {
        let mut path = String::new();
        for component in leaf.split('/') {
            if !path.is_empty() {
                path.push('/');
            }
            path.push_str(component);
            projected.insert(path.clone());
        }
    }
    if projected.len() > MAX_FILE_TRANSFER_LIST_ENTRIES {
        return None;
    }
    let metadata_bytes = projected
        .iter()
        .try_fold(0usize, |total, path| total.checked_add(path.len()))?;
    if metadata_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES {
        return None;
    }
    let mut projected: Vec<_> = projected.into_iter().collect();
    projected.sort_by(|left, right| {
        left.matches('/')
            .count()
            .cmp(&right.matches('/').count())
            .then_with(|| left.as_bytes().cmp(right.as_bytes()))
    });
    Some(projected)
}

unsafe fn native_viewer_upload_manifest(
    request: &RDNFileTransferUploadStart,
) -> Option<(Vec<NativeViewerUploadFileAuthority>, Vec<String>)> {
    if request.entry_count == 0
        || request.entry_count > MAX_FILE_TRANSFER_LIST_ENTRIES
        || request.entries.is_null()
    {
        return None;
    }
    let entries = slice::from_raw_parts(request.entries, request.entry_count);
    let mut metadata_utf8_bytes = 0usize;
    let mut collision_keys = HashSet::with_capacity(entries.len());
    let mut all_collision_keys = Vec::with_capacity(entries.len());
    let mut files = Vec::new();
    let mut empty_directories = Vec::new();
    let mut total_bytes = 0u64;
    for entry in entries {
        if entry.relative_path_utf8.is_null() || entry.relative_path_length == 0 {
            return None;
        }
        metadata_utf8_bytes = metadata_utf8_bytes.checked_add(entry.relative_path_length)?;
        if metadata_utf8_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES {
            return None;
        }
        let bytes = slice::from_raw_parts(entry.relative_path_utf8, entry.relative_path_length);
        let path = std::str::from_utf8(bytes).ok()?;
        if !native_viewer_manifest_relative_path(path) {
            return None;
        }
        let collision_key = path.to_ascii_lowercase();
        if !collision_keys.insert(collision_key.clone()) {
            return None;
        }
        all_collision_keys.push(collision_key);
        match entry.kind {
            FILE_TRANSFER_LIST_ENTRY_FILE => {
                total_bytes = total_bytes.checked_add(entry.size)?;
                files.push(NativeViewerUploadFileAuthority {
                    relative_path: path.to_owned(),
                    size: entry.size,
                    modified_time: entry.modified_time,
                });
            }
            FILE_TRANSFER_LIST_ENTRY_DIRECTORY if entry.size == 0 && entry.modified_time == 0 => {
                empty_directories.push(path.to_owned());
            }
            _ => return None,
        }
    }
    if total_bytes != request.total_bytes {
        return None;
    }
    for path in &all_collision_keys {
        let components: Vec<_> = path.split('/').collect();
        let mut ancestor = String::new();
        for component in components.iter().take(components.len().saturating_sub(1)) {
            if !ancestor.is_empty() {
                ancestor.push('/');
            }
            ancestor.push_str(component);
            if collision_keys.contains(&ancestor) {
                return None;
            }
        }
    }
    let empty_directories = native_viewer_upload_directory_projection(&empty_directories)?;
    Some((files, empty_directories))
}

fn native_viewer_file_list_root_message() -> Message {
    let mut action = FileAction::new();
    action.set_read_dir(ReadDir {
        path: "/".to_owned(),
        include_hidden: false,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_file_action(action);
    message
}

fn native_viewer_file_manifest_root_messages(request_id: i32) -> (Message, Message) {
    let mut files_action = FileAction::new();
    files_action.set_all_files(ReadAllFiles {
        id: request_id,
        path: "/".to_owned(),
        include_hidden: false,
        ..Default::default()
    });
    let mut files_message = Message::new();
    files_message.set_file_action(files_action);

    let mut directories_action = FileAction::new();
    directories_action.set_read_empty_dirs(ReadEmptyDirs {
        path: "/".to_owned(),
        include_hidden: false,
        ..Default::default()
    });
    let mut directories_message = Message::new();
    directories_message.set_file_action(directories_action);
    (files_message, directories_message)
}

fn native_viewer_file_download_root_message(transfer_id: i32) -> Message {
    hbb_common::fs::new_send(
        transfer_id,
        hbb_common::fs::JobType::Generic,
        "/".to_owned(),
        0,
        false,
    )
}

fn client_clear_completed_manifest(shared: &BridgeShared, session_epoch: u64) {
    let mut completed = shared.completed_file_manifest_request.lock().unwrap();
    if completed
        .as_ref()
        .is_some_and(|request| request.session_epoch == session_epoch)
    {
        completed.take();
    }
}

fn viewer_file_transfer_mode_admission(
    enabled: bool,
    session_epoch: u64,
    desktop_capability_requested: bool,
) -> i32 {
    if enabled != (session_epoch > 0) {
        -5
    } else if enabled && desktop_capability_requested {
        -5
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn rdn_core_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn rdn_core_upstream_commit() -> *const c_char {
    UPSTREAM_COMMIT.as_ptr() as *const c_char
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_create(
    callbacks: *const RDNCallbacks,
    context: *mut c_void,
) -> *mut RDNClient {
    if callbacks.is_null() || (*callbacks).abi_version != ABI_VERSION {
        return ptr::null_mut();
    }
    let shared = Arc::new(BridgeShared {
        callbacks: *callbacks,
        context: context as usize,
        active: AtomicBool::new(true),
        terminal_retry_allowed: AtomicBool::new(true),
        sequence: AtomicU64::new(0),
        dimensions: RwLock::new((0, 0)),
        connection_epoch: AtomicU64::new(0),
        display_catalog: Mutex::new(NativeViewerDisplayCatalogState::default()),
        display_catalog_delivery: Mutex::new(()),
        authenticated: AtomicBool::new(false),
        remote_keyboard_enabled: AtomicBool::new(true),
        remote_audio_enabled: AtomicBool::new(true),
        input_allowed: AtomicBool::new(false),
        receive_clipboard_text: AtomicBool::new(false),
        send_clipboard_text: AtomicBool::new(false),
        receive_clipboard_rich_text: AtomicBool::new(false),
        send_clipboard_rich_text: AtomicBool::new(false),
        receive_clipboard_image: AtomicBool::new(false),
        send_clipboard_image: AtomicBool::new(false),
        remote_clipboard_enabled: AtomicBool::new(REMOTE_CLIPBOARD_ENABLED_BY_DEFAULT),
        remote_file_transfer_enabled: AtomicBool::new(false),
        file_transfer_enabled: AtomicBool::new(false),
        file_transfer_session_epoch: AtomicU64::new(0),
        pending_file_list_request: Mutex::new(None),
        file_manifest_request_epoch: AtomicU64::new(0),
        pending_file_manifest_request: Mutex::new(None),
        completed_file_manifest_request: Mutex::new(None),
        active_file_download_jobs: Mutex::new(HashMap::new()),
        active_file_upload_jobs: Mutex::new(HashMap::new()),
        file_upload_poll_cursor: AtomicU64::new(0),
    });
    Box::into_raw(Box::new(RDNClient {
        shared,
        session: Mutex::new(None),
        worker: Mutex::new(None),
        housekeeping: Mutex::new(None),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_destroy(client: *mut RDNClient) {
    if client.is_null() {
        return;
    }
    let client = Box::from_raw(client);
    client.disconnect(false);
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_connect(
    client: *mut RDNClient,
    config: *const RDNConnectionConfig,
) -> i32 {
    if client.is_null() || config.is_null() {
        return -1;
    }
    if (*config).abi_version != ABI_VERSION {
        return -2;
    }
    let desktop_clipboard_requested = (*config).receive_clipboard_text
        || (*config).send_clipboard_text
        || (*config).receive_clipboard_rich_text
        || (*config).send_clipboard_rich_text
        || (*config).receive_clipboard_image
        || (*config).send_clipboard_image;
    let receive_audio = (*config).receive_audio;
    let file_transfer_admission = viewer_file_transfer_mode_admission(
        (*config).enable_file_transfer,
        (*config).file_transfer_session_epoch,
        desktop_clipboard_requested || receive_audio,
    );
    if file_transfer_admission != 0 {
        return file_transfer_admission;
    }
    let file_transfer_mode = (*config).enable_file_transfer;
    let client = &*client;
    if client.worker.lock().unwrap().is_some() {
        return -4;
    }
    let server = match required_string((*config).rendezvous_server) {
        Ok(value) if !value.is_empty() => value,
        _ => return -5,
    };
    let key = match required_string((*config).server_public_key) {
        Ok(value) if !value.is_empty() => value,
        _ => return -5,
    };
    let peer_id = match required_string((*config).peer_id) {
        Ok(value) if !value.is_empty() => value,
        _ => return -5,
    };
    let password = match optional_string((*config).password) {
        Ok(value) => value,
        Err(code) => return code,
    };
    if server.contains('@') || peer_id.contains('@') || key.contains('&') {
        return -5;
    }

    let Some(connection_epoch) = next_viewer_connection_epoch() else {
        return -3;
    };

    client.shared.active.store(true, Ordering::Release);
    client
        .shared
        .connection_epoch
        .store(connection_epoch, Ordering::Release);
    *client.shared.display_catalog.lock().unwrap() = NativeViewerDisplayCatalogState::default();
    client.shared.authenticated.store(false, Ordering::Release);
    client
        .shared
        .remote_keyboard_enabled
        .store(true, Ordering::Release);
    client
        .shared
        .remote_audio_enabled
        .store(true, Ordering::Release);
    client.shared.input_allowed.store(false, Ordering::Release);
    client
        .shared
        .receive_clipboard_text
        .store((*config).receive_clipboard_text, Ordering::Release);
    client
        .shared
        .send_clipboard_text
        .store((*config).send_clipboard_text, Ordering::Release);
    client
        .shared
        .receive_clipboard_rich_text
        .store((*config).receive_clipboard_rich_text, Ordering::Release);
    client
        .shared
        .send_clipboard_rich_text
        .store((*config).send_clipboard_rich_text, Ordering::Release);
    client
        .shared
        .receive_clipboard_image
        .store((*config).receive_clipboard_image, Ordering::Release);
    client
        .shared
        .send_clipboard_image
        .store((*config).send_clipboard_image, Ordering::Release);
    client
        .shared
        .remote_clipboard_enabled
        .store(REMOTE_CLIPBOARD_ENABLED_BY_DEFAULT, Ordering::Release);
    client
        .shared
        .remote_file_transfer_enabled
        .store(false, Ordering::Release);
    client
        .shared
        .file_transfer_enabled
        .store(file_transfer_mode, Ordering::Release);
    client
        .shared
        .file_transfer_session_epoch
        .store((*config).file_transfer_session_epoch, Ordering::Release);
    client
        .shared
        .pending_file_list_request
        .lock()
        .unwrap()
        .take();
    client
        .shared
        .file_manifest_request_epoch
        .store(0, Ordering::Release);
    client
        .shared
        .pending_file_manifest_request
        .lock()
        .unwrap()
        .take();
    client
        .shared
        .completed_file_manifest_request
        .lock()
        .unwrap()
        .take();
    client
        .shared
        .active_file_download_jobs
        .lock()
        .unwrap()
        .clear();
    client
        .shared
        .active_file_upload_jobs
        .lock()
        .unwrap()
        .clear();
    client.shared.sequence.store(0, Ordering::Relaxed);
    *client.shared.dimensions.write().unwrap() = (0, 0);
    client
        .shared
        .emit_state(RDNState::Connecting, 0, "connecting");

    let target = format!("{peer_id}@{server}?key={key}");
    let ui = BridgeUi {
        shared: client.shared.clone(),
    };
    let session: Session<BridgeUi> = Session {
        password,
        ui_handler: ui.clone(),
        // RustDesk's desktop protocol treats keyboard control as enabled unless
        // the peer sends an explicit PermissionInfo(false).
        server_keyboard_enabled: Arc::new(RwLock::new(true)),
        server_file_transfer_enabled: Arc::new(RwLock::new(false)),
        server_clipboard_enabled: Arc::new(RwLock::new(false)),
        ..Default::default()
    };
    session.lc.write().unwrap().initialize(
        target,
        if file_transfer_mode {
            ConnType::FILE_TRANSFER
        } else {
            ConnType::DEFAULT_CONN
        },
        None,
        (*config).force_relay,
        None,
        None,
        None,
    );
    session
        .lc
        .write()
        .unwrap()
        .configure_native_viewer(
            &peer_id,
            desktop_clipboard_requested,
            receive_audio,
        );
    let round = session.connection_round_state.lock().unwrap().new_round();
    let worker_session = session.clone();
    let worker_shared = client.shared.clone();
    let worker = std::thread::spawn(move || {
        io_loop(worker_session, round);
        worker_shared.terminate_display_selection(DISPLAY_SELECTION_FAILURE_CONNECTION_CLOSED);
        worker_shared.authenticated.store(false, Ordering::Release);
        worker_shared.input_allowed.store(false, Ordering::Release);
        worker_shared
            .file_transfer_enabled
            .store(false, Ordering::Release);
        worker_shared
            .file_transfer_session_epoch
            .store(0, Ordering::Release);
        worker_shared.connection_epoch.store(0, Ordering::Release);
        *worker_shared.display_catalog.lock().unwrap() = NativeViewerDisplayCatalogState::default();
        worker_shared
            .pending_file_list_request
            .lock()
            .unwrap()
            .take();
        worker_shared
            .file_manifest_request_epoch
            .store(0, Ordering::Release);
        worker_shared
            .pending_file_manifest_request
            .lock()
            .unwrap()
            .take();
        worker_shared
            .completed_file_manifest_request
            .lock()
            .unwrap()
            .take();
        worker_shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .clear();
        worker_shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .clear();
        let retry_allowed = worker_shared.terminal_retry_allowed.load(Ordering::Acquire);
        worker_shared.emit_state(
            RDNState::Disconnected,
            if retry_allowed {
                0
            } else {
                TERMINAL_NO_RETRY_CODE
            },
            if retry_allowed {
                "disconnected"
            } else {
                "disconnected-no-retry"
            },
        );
    });
    let housekeeping = if file_transfer_mode {
        None
    } else {
        let housekeeping_session = session.clone();
        let housekeeping_shared = client.shared.clone();
        let custom_fps = native_stream_fps((*config).force_relay);
        Some(std::thread::spawn(move || {
            let mut ticks = 0;
            let mut configuration_sent = false;
            while housekeeping_shared.active.load(Ordering::Acquire) {
                std::thread::sleep(Duration::from_millis(100));
                if !housekeeping_shared.active.load(Ordering::Acquire) {
                    break;
                }
                if !configuration_sent {
                    if let Some(sender) = housekeeping_session.sender.read().unwrap().as_ref() {
                        if sender
                            .send(Data::Message(native_stream_configuration_message(
                                custom_fps,
                            )))
                            .is_err()
                        {
                            break;
                        }
                        configuration_sent = true;
                    }
                }
                ticks += 1;
                if ticks < 50 {
                    continue;
                }
                ticks = 0;
                if let Some(sender) = housekeeping_session.sender.read().unwrap().as_ref() {
                    if sender.send(Data::Message(housekeeping_message())).is_err() {
                        break;
                    }
                }
            }
        }))
    };
    *client.session.lock().unwrap() = Some(session);
    *client.worker.lock().unwrap() = Some(worker);
    *client.housekeeping.lock().unwrap() = housekeeping;
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_disconnect(client: *mut RDNClient) {
    if let Some(client) = client.as_ref() {
        client.disconnect(true);
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_select_display(
    client: *mut RDNClient,
    request: *const RDNDisplaySelectionRequest,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    let Some(request) = request.as_ref() else {
        return -1;
    };
    if request.abi_version != ABI_VERSION {
        return -2;
    }
    if request.connection_epoch == 0 || request.command_id == 0 || request.catalog_revision == 0 {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if client.shared.connection_epoch.load(Ordering::Acquire) != request.connection_epoch {
        return -10;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if session.sender.read().unwrap().is_none() {
        return -3;
    }

    let delivery = client.shared.display_catalog_delivery.lock().unwrap();
    if !client.shared.active.load(Ordering::Acquire)
        || !client.shared.authenticated.load(Ordering::Acquire)
        || client.shared.connection_epoch.load(Ordering::Acquire) != request.connection_epoch
    {
        return -10;
    }
    let mut state = client.shared.display_catalog.lock().unwrap();
    if !state.initialized || state.entries.is_none() || state.revision != request.catalog_revision {
        return -10;
    }
    if state.pending_selection.is_some() {
        return -3;
    }
    if request.command_id <= state.last_selection_command_id {
        return -5;
    }
    let selectable = state.entries.as_deref().is_some_and(|entries| {
        entries
            .get(request.display_index as usize)
            .is_some_and(|entry| entry.display_index == request.display_index && entry.online)
    });
    if !selectable {
        return -5;
    }
    state.last_selection_command_id = request.command_id;
    let pending = NativeViewerDisplaySelectionPending {
        connection_epoch: request.connection_epoch,
        command_id: request.command_id,
        catalog_revision: request.catalog_revision,
        display_index: request.display_index,
    };
    if state.selected_display_index == Some(request.display_index) {
        drop(state);
        client
            .shared
            .emit_display_selection(NativeViewerDisplaySelectionSnapshot {
                pending,
                result: DISPLAY_SELECTION_RESULT_ALREADY_SELECTED,
                failure: DISPLAY_SELECTION_FAILURE_NONE,
            });
        drop(delivery);
        return 0;
    }
    state.pending_selection = Some(pending);
    drop(state);
    session.switch_display(request.display_index as i32);
    drop(delivery);
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_request_keyframe(client: *mut RDNClient, display: u32) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -2;
    };
    session.refresh_video(display.min(i32::MAX as u32) as i32);
    0
}

fn pointer_mask(kind: RDNPointerKind, buttons: u32) -> Option<i32> {
    if buttons & !VALID_POINTER_BUTTONS != 0 {
        return None;
    }
    let event_type = match kind {
        RDNPointerKind::Move => MOUSE_TYPE_MOVE,
        RDNPointerKind::Down => MOUSE_TYPE_DOWN,
        RDNPointerKind::Up => MOUSE_TYPE_UP,
        RDNPointerKind::Scroll => MOUSE_TYPE_WHEEL,
        RDNPointerKind::PreciseScroll => MOUSE_TYPE_TRACKPAD,
    };
    let mut upstream_buttons = 0;
    if buttons & POINTER_BUTTON_LEFT != 0 {
        upstream_buttons |= MOUSE_BUTTON_LEFT;
    }
    if buttons & POINTER_BUTTON_RIGHT != 0 {
        upstream_buttons |= MOUSE_BUTTON_RIGHT;
    }
    if buttons & POINTER_BUTTON_MIDDLE != 0 {
        upstream_buttons |= MOUSE_BUTTON_WHEEL;
    }
    match kind {
        RDNPointerKind::Down | RDNPointerKind::Up if upstream_buttons.count_ones() != 1 => {
            return None;
        }
        RDNPointerKind::Scroll | RDNPointerKind::PreciseScroll if upstream_buttons != 0 => {
            return None;
        }
        _ => {}
    }
    Some(event_type | (upstream_buttons << 3))
}

fn pointer_payload_fields_are_canonical(
    kind: RDNPointerKind,
    x: i32,
    y: i32,
    scroll_x: i32,
    scroll_y: i32,
) -> bool {
    if matches!(kind, RDNPointerKind::Scroll | RDNPointerKind::PreciseScroll) {
        x == 0 && y == 0
    } else {
        scroll_x == 0 && scroll_y == 0
    }
}

fn key_name(code: RDNKeyCode, unicode_scalar: u32) -> Option<String> {
    let special = match code {
        RDNKeyCode::Character => {
            return char::from_u32(unicode_scalar)
                .filter(|value| *value != '\0')
                .map(|value| value.to_string())
        }
        RDNKeyCode::Escape => "VK_ESCAPE",
        RDNKeyCode::Return => "VK_RETURN",
        RDNKeyCode::Tab => "VK_TAB",
        RDNKeyCode::Backspace => "VK_BACK",
        RDNKeyCode::DeleteForward => "VK_DELETE",
        RDNKeyCode::Left => "VK_LEFT",
        RDNKeyCode::Right => "VK_RIGHT",
        RDNKeyCode::Up => "VK_UP",
        RDNKeyCode::Down => "VK_DOWN",
        RDNKeyCode::Space => "VK_SPACE",
        RDNKeyCode::Shift => "VK_SHIFT",
        RDNKeyCode::Control => "VK_CONTROL",
        RDNKeyCode::Option => "VK_MENU",
        RDNKeyCode::Command => "Meta",
        RDNKeyCode::Home => "VK_HOME",
        RDNKeyCode::End => "VK_END",
        RDNKeyCode::PageUp => "VK_PRIOR",
        RDNKeyCode::PageDown => "VK_NEXT",
        RDNKeyCode::Physical => return None,
    };
    Some(special.to_owned())
}

fn key_payload_fields_are_canonical(
    code: RDNKeyCode,
    unicode_scalar: u32,
    hardware_keycode: u32,
) -> bool {
    match code {
        RDNKeyCode::Character => hardware_keycode == 0,
        RDNKeyCode::Physical => unicode_scalar == 0,
        _ => unicode_scalar == 0 && hardware_keycode == 0,
    }
}

fn physical_macos_keycode(value: u32) -> Option<i32> {
    // macOS virtual hardware key positions are 7-bit values. Keeping this
    // validation in Rust prevents Swift from exposing RustDesk wire details.
    (value <= 0x7f).then_some(value as i32)
}

fn modifiers(value: u32) -> Option<(bool, bool, bool, bool)> {
    if value & !VALID_MODIFIERS != 0 {
        return None;
    }
    Some((
        value & MODIFIER_OPTION != 0,
        value & MODIFIER_CONTROL != 0,
        value & MODIFIER_SHIFT != 0,
        value & MODIFIER_COMMAND != 0,
    ))
}

fn clamp_pointer_coordinates(x: i32, y: i32, dimensions: (u32, u32)) -> Option<(i32, i32)> {
    let maximum_x = dimensions.0.checked_sub(1)?.min(i32::MAX as u32) as i32;
    let maximum_y = dimensions.1.checked_sub(1)?.min(i32::MAX as u32) as i32;
    Some((x.clamp(0, maximum_x), y.clamp(0, maximum_y)))
}

fn normalized_pointer_coordinates(
    kind: RDNPointerKind,
    x: i32,
    y: i32,
    scroll_x: i32,
    scroll_y: i32,
    dimensions: (u32, u32),
) -> Option<(i32, i32)> {
    if matches!(kind, RDNPointerKind::Scroll | RDNPointerKind::PreciseScroll) {
        let point = (scroll_x.clamp(-120, 120), scroll_y.clamp(-120, 120));
        return (point != (0, 0)).then_some(point);
    }
    clamp_pointer_coordinates(x, y, dimensions)
}

fn validated_text(bytes: &[u8]) -> Option<&str> {
    if bytes.is_empty() || bytes.len() > MAX_TEXT_BYTES {
        return None;
    }
    std::str::from_utf8(bytes)
        .ok()
        .filter(|text| !text.contains('\0'))
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_pointer(
    client: *mut RDNClient,
    event: *const RDNPointerEvent,
) -> i32 {
    let (Some(client), Some(event)) = (client.as_ref(), event.as_ref()) else {
        return -1;
    };
    if event.abi_version != ABI_VERSION {
        return -2;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.input_allowed.load(Ordering::Acquire) {
        return -6;
    }
    if !pointer_payload_fields_are_canonical(
        event.kind,
        event.x,
        event.y,
        event.scroll_x,
        event.scroll_y,
    ) {
        return -4;
    }
    let Some(mask) = pointer_mask(event.kind, event.buttons) else {
        return -4;
    };
    let Some((alt, ctrl, shift, command)) = modifiers(event.modifiers) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    let dimensions = *client.shared.dimensions.read().unwrap();
    let Some((x, y)) = normalized_pointer_coordinates(
        event.kind,
        event.x,
        event.y,
        event.scroll_x,
        event.scroll_y,
        dimensions,
    ) else {
        return -5;
    };
    session.send_mouse(mask, x, y, alt, ctrl, shift, command);
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_key(
    client: *mut RDNClient,
    event: *const RDNKeyEvent,
) -> i32 {
    let (Some(client), Some(event)) = (client.as_ref(), event.as_ref()) else {
        return -1;
    };
    if event.abi_version != ABI_VERSION {
        return -2;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.input_allowed.load(Ordering::Acquire) {
        return -6;
    }
    if !key_payload_fields_are_canonical(event.code, event.unicode_scalar, event.hardware_keycode) {
        return -4;
    }
    let physical_keycode = if event.code == RDNKeyCode::Physical {
        let Some(keycode) = physical_macos_keycode(event.hardware_keycode) else {
            return -4;
        };
        Some(keycode)
    } else {
        None
    };
    let name = if physical_keycode.is_none() {
        let Some(name) = key_name(event.code, event.unicode_scalar) else {
            return -4;
        };
        Some(name)
    } else {
        None
    };
    let Some((alt, ctrl, shift, command)) = modifiers(event.modifiers) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if let Some(keycode) = physical_keycode {
        session.handle_flutter_raw_key_event("map", "", keycode, keycode, 0, event.down);
        return 0;
    }
    session.input_key(
        name.as_deref().expect("semantic key name was validated"),
        event.down,
        false,
        alt,
        ctrl,
        shift,
        command,
    );
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_text(
    client: *mut RDNClient,
    utf8: *const u8,
    length: usize,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.input_allowed.load(Ordering::Acquire) {
        return -6;
    }
    if utf8.is_null() || length == 0 || length > MAX_TEXT_BYTES {
        return -4;
    }
    let bytes = std::slice::from_raw_parts(utf8, length);
    let Some(text) = validated_text(bytes) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    session.input_string(text);
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_clipboard_text(
    client: *mut RDNClient,
    utf8: *const u8,
    length: usize,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if !client.shared.send_clipboard_text.load(Ordering::Acquire) {
        return -7;
    }
    if !client
        .shared
        .remote_clipboard_enabled
        .load(Ordering::Acquire)
    {
        return -8;
    }
    if utf8.is_null() || length == 0 || length > MAX_CLIPBOARD_TEXT_UTF8_BYTES {
        return -4;
    }
    let bytes = std::slice::from_raw_parts(utf8, length);
    let Some(message) = native_viewer_clipboard_message(bytes) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    sender.send(Data::Message(message)).map_or(-3, |_| 0)
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_clipboard_rich_text(
    client: *mut RDNClient,
    payload: *const RDNClipboardRichTextPayload,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if !client
        .shared
        .send_clipboard_rich_text
        .load(Ordering::Acquire)
    {
        return -7;
    }
    if !client
        .shared
        .remote_clipboard_enabled
        .load(Ordering::Acquire)
    {
        return -8;
    }
    let Some(payload) = payload.as_ref() else {
        return -4;
    };
    let Some(message) = (unsafe { native_viewer_clipboard_rich_text_message(payload) }) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    sender.send(Data::Message(message)).map_or(-3, |_| 0)
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_clipboard_image(
    client: *mut RDNClient,
    payload: *const RDNClipboardImagePayload,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if !client.shared.send_clipboard_image.load(Ordering::Acquire) {
        return -7;
    }
    if !client
        .shared
        .remote_clipboard_enabled
        .load(Ordering::Acquire)
    {
        return -8;
    }
    let Some(payload) = payload.as_ref() else {
        return -4;
    };
    let Some(message) = (unsafe { native_viewer_clipboard_image_message(payload) }) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    sender.send(Data::Message(message)).map_or(-3, |_| 0)
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_cancel(
    client: *mut RDNClient,
    session_epoch: u64,
    transfer_id: i32,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if session_epoch == 0 || transfer_id <= 0 {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    if sender.send(Data::CancelJob(transfer_id)).is_err() {
        let upload_event = client
            .shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .remove(&transfer_id)
            .filter(|job| job.session_epoch == session_epoch)
            .and_then(|job| {
                job.terminal(
                    FILE_TRANSFER_EVENT_FAILED,
                    FILE_TRANSFER_FAILURE_CONNECTION_CLOSED,
                )
            });
        if let Some(event) = upload_event {
            client.shared.emit_file_transfer_event(event);
        }
        return -3;
    }
    let upload_event = {
        let mut jobs = client.shared.active_file_upload_jobs.lock().unwrap();
        if jobs
            .get(&transfer_id)
            .is_some_and(|job| job.session_epoch == session_epoch)
        {
            jobs.remove(&transfer_id).and_then(|job| {
                job.terminal(FILE_TRANSFER_EVENT_CANCELLED, FILE_TRANSFER_FAILURE_NONE)
            })
        } else {
            None
        }
    };
    if let Some(event) = upload_event {
        client.shared.emit_file_transfer_event(event);
        return 0;
    }
    let event = {
        let mut jobs = client.shared.active_file_download_jobs.lock().unwrap();
        if jobs
            .get(&transfer_id)
            .is_some_and(|job| job.session_epoch == session_epoch)
        {
            jobs.remove(&transfer_id).and_then(|job| {
                job.terminal(FILE_TRANSFER_EVENT_CANCELLED, FILE_TRANSFER_FAILURE_NONE)
            })
        } else {
            None
        }
    };
    if let Some(event) = event {
        client.shared.emit_file_transfer_event(event);
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_list_root(
    client: *mut RDNClient,
    session_epoch: u64,
    request_id: i32,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if session_epoch == 0 || request_id <= 0 {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    let request = NativeViewerListRequest {
        session_epoch,
        request_id,
    };
    {
        let mut pending = client.shared.pending_file_list_request.lock().unwrap();
        if pending.is_some() {
            return -3;
        }
        *pending = Some(request.clone());
    }
    if sender
        .send(Data::Message(native_viewer_file_list_root_message()))
        .is_err()
    {
        let mut pending = client.shared.pending_file_list_request.lock().unwrap();
        if pending.as_ref() == Some(&request) {
            pending.take();
        }
        return -3;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_manifest_root(
    client: *mut RDNClient,
    session_epoch: u64,
    request_id: i32,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if session_epoch == 0 || request_id <= 0 {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    let request = NativeViewerManifestRequest {
        session_epoch,
        request_id,
        files_delivered: false,
        empty_directories_delivered: false,
        total_files: None,
        total_bytes: None,
        files: None,
    };
    if client
        .shared
        .file_manifest_request_epoch
        .compare_exchange(0, session_epoch, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return -3;
    }
    {
        let mut pending = client.shared.pending_file_manifest_request.lock().unwrap();
        debug_assert!(pending.is_none());
        *pending = Some(request.clone());
    }
    let (files_message, directories_message) =
        native_viewer_file_manifest_root_messages(request_id);
    if sender.send(Data::Message(files_message)).is_err()
        || sender.send(Data::Message(directories_message)).is_err()
    {
        let mut pending = client.shared.pending_file_manifest_request.lock().unwrap();
        if pending.as_ref() == Some(&request) {
            pending.take();
        }
        return -3;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_download_start(
    client: *mut RDNClient,
    request: *const RDNFileTransferDownloadStart,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    let Some(request) = request.as_ref() else {
        return -4;
    };
    if request.abi_version != ABI_VERSION
        || request.session_epoch == 0
        || request.manifest_request_id <= 0
        || request.transfer_id <= 0
        || request.total_files as usize > MAX_FILE_TRANSFER_LIST_ENTRIES
        || (request.total_files == 0 && request.total_bytes != 0)
    {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != request.session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    let manifest_files = {
        let completed_manifest = client
            .shared
            .completed_file_manifest_request
            .lock()
            .unwrap();
        let Some(completed_manifest) = completed_manifest.as_ref() else {
            return -3;
        };
        if completed_manifest.session_epoch != request.session_epoch
            || completed_manifest.request_id != request.manifest_request_id
            || completed_manifest.total_files != request.total_files
            || completed_manifest.total_bytes != request.total_bytes
            || completed_manifest.files.len() != request.total_files as usize
        {
            return -3;
        }
        completed_manifest.files.clone()
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    let job = NativeViewerDownloadJob {
        session_epoch: request.session_epoch,
        manifest_request_id: request.manifest_request_id,
        transfer_id: request.transfer_id,
        total_files: request.total_files,
        total_bytes: request.total_bytes,
        manifest_files,
        next_digest_file_number: 0,
        sequence: 0,
        files_completed: 0,
        bytes_completed: 0,
    };
    let mut jobs = client.shared.active_file_download_jobs.lock().unwrap();
    if !client.shared.active.load(Ordering::Acquire)
        || !client.shared.file_transfer_enabled.load(Ordering::Acquire)
        || client
            .shared
            .file_transfer_session_epoch
            .load(Ordering::Acquire)
            != request.session_epoch
        || !client.shared.authenticated.load(Ordering::Acquire)
    {
        return -3;
    }
    if jobs.len() >= MAX_VIEWER_DOWNLOAD_JOBS || jobs.contains_key(&request.transfer_id) {
        return -3;
    }
    jobs.insert(request.transfer_id, job);
    // The unbounded channel enqueue is nonblocking. Keeping the job mutex here
    // makes a closed queue rollback atomic with registration, so cancel/retry
    // cannot observe or replace a half-dispatched transfer ID.
    if sender
        .send(Data::Message(native_viewer_file_download_root_message(
            request.transfer_id,
        )))
        .is_err()
    {
        jobs.remove(&request.transfer_id);
        return -3;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_upload_start(
    client: *mut RDNClient,
    request: *const RDNFileTransferUploadStart,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    let Some(request) = request.as_ref() else {
        return -4;
    };
    if request.abi_version != ABI_VERSION
        || request.session_epoch == 0
        || request.transfer_id <= 0
        || request.source_token == 0
    {
        return -4;
    }
    let Some((files, empty_directories)) = native_viewer_upload_manifest(request) else {
        return -4;
    };
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != request.session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if !files.is_empty()
        && client
            .shared
            .callbacks
            .on_file_transfer_upload_read
            .is_none()
    {
        return -5;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    let stage = if empty_directories.is_empty() {
        NativeViewerUploadStage::ReadyDigest { file_number: 0 }
    } else {
        NativeViewerUploadStage::AwaitingCreate {
            directory_number: 0,
        }
    };
    let job = NativeViewerUploadJob {
        session_epoch: request.session_epoch,
        transfer_id: request.transfer_id,
        source_token: request.source_token,
        files: files.into(),
        empty_directories: empty_directories.into(),
        total_bytes: request.total_bytes,
        stage,
        stage_started: Instant::now(),
        sequence: 0,
        files_completed: 0,
        bytes_completed: 0,
    };
    let Some(initial_message) = job.initial_message() else {
        return -4;
    };
    let download_jobs = client.shared.active_file_download_jobs.lock().unwrap();
    let mut upload_jobs = client.shared.active_file_upload_jobs.lock().unwrap();
    if !client.shared.active.load(Ordering::Acquire)
        || !client.shared.file_transfer_enabled.load(Ordering::Acquire)
        || client
            .shared
            .file_transfer_session_epoch
            .load(Ordering::Acquire)
            != request.session_epoch
        || !client.shared.authenticated.load(Ordering::Acquire)
        || upload_jobs.len() >= MAX_VIEWER_UPLOAD_JOBS
        || upload_jobs.contains_key(&request.transfer_id)
        || download_jobs.contains_key(&request.transfer_id)
    {
        return -3;
    }
    upload_jobs.insert(request.transfer_id, job);
    if sender.send(Data::Message(initial_message)).is_err() {
        upload_jobs.remove(&request.transfer_id);
        return -3;
    }
    0
}

struct PacketInspection {
    format: RDNPacketFormat,
    flags: u32,
}

fn inspect_packet(data: &[u8]) -> PacketInspection {
    let annex_types = annex_b_nal_types(data);
    let avcc_types = avcc_nal_types(data);
    let (format, types) = match (annex_types, avcc_types) {
        (Some(types), None) => (RDNPacketFormat::AnnexB, types),
        (None, Some(types)) => (RDNPacketFormat::Avcc, types),
        (Some(types), Some(_)) => (RDNPacketFormat::Mixed, types),
        (None, None) => (RDNPacketFormat::Unknown, Vec::new()),
    };
    let mut flags = 0;
    for nal_type in types {
        match nal_type {
            32 => flags |= FLAG_VPS,
            33 => flags |= FLAG_SPS,
            34 => flags |= FLAG_PPS,
            _ => {}
        }
    }
    PacketInspection { format, flags }
}

fn annex_b_nal_types(data: &[u8]) -> Option<Vec<u8>> {
    let mut starts = Vec::new();
    let mut index = 0;
    while index + 3 <= data.len() {
        let prefix = if index + 4 <= data.len() && data[index..index + 4] == [0, 0, 0, 1] {
            4
        } else if data[index..index + 3] == [0, 0, 1] {
            3
        } else {
            index += 1;
            continue;
        };
        starts.push((index, prefix));
        index += prefix;
    }
    if starts.first().map(|entry| entry.0) != Some(0) {
        return None;
    }
    let types: Vec<u8> = starts
        .iter()
        .filter_map(|(offset, prefix)| data.get(offset + prefix).map(|byte| (byte >> 1) & 0x3f))
        .collect();
    (!types.is_empty()).then_some(types)
}

fn avcc_nal_types(data: &[u8]) -> Option<Vec<u8>> {
    let mut index = 0;
    let mut types = Vec::new();
    while index + 4 <= data.len() {
        let length = u32::from_be_bytes(data[index..index + 4].try_into().ok()?) as usize;
        index += 4;
        if length == 0 || index + length > data.len() {
            return None;
        }
        types.push((data[index] >> 1) & 0x3f);
        index += length;
    }
    (index == data.len() && !types.is_empty()).then_some(types)
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" fn capture_state(
        context: *mut c_void,
        state: RDNState,
        code: i32,
        message: *const c_char,
    ) {
        if context.is_null() || message.is_null() {
            return;
        }
        let capture = &*(context as *const Mutex<Vec<(u32, i32, String)>>);
        capture.lock().unwrap().push((
            state as u32,
            code,
            CStr::from_ptr(message).to_string_lossy().into_owned(),
        ));
    }

    #[test]
    fn viewer_terminal_error_state_preserves_retry_authority() {
        assert_eq!(
            viewer_terminal_error_state("Closed manually by the peer", false),
            (TERMINAL_NO_RETRY_CODE, "connection-no-retry")
        );
        assert_eq!(
            viewer_terminal_error_state("Timeout", true),
            (10, "connection-timeout")
        );
        assert_eq!(
            viewer_terminal_error_state("Connection reset", true),
            (11, "connection-reset")
        );
    }

    #[test]
    fn viewer_no_retry_error_latches_terminal_disconnect() {
        let ui = BridgeUi::default();
        assert!(ui.shared.terminal_retry_allowed.load(Ordering::Acquire));
        ui.msgbox(
            "error",
            "Connection Error",
            "Closed manually by the peer",
            "",
            false,
        );
        assert!(!ui.shared.terminal_retry_allowed.load(Ordering::Acquire));
        ui.msgbox("error", "Connection Error", "Timeout", "", true);
        assert!(!ui.shared.terminal_retry_allowed.load(Ordering::Acquire));
    }

    #[derive(Debug, Eq, PartialEq)]
    struct CapturedFileListEvent {
        session_epoch: u64,
        request_id: i32,
        status: u32,
        entries: Vec<(u32, String, u64, u64)>,
    }

    #[derive(Debug, Eq, PartialEq)]
    struct CapturedFileManifestEvent {
        session_epoch: u64,
        request_id: i32,
        status: u32,
        part: u32,
        entries: Vec<(u32, String, u64, u64)>,
    }

    #[derive(Clone, Copy, Debug, PartialEq)]
    struct CapturedFileTransferEvent {
        session_epoch: u64,
        transfer_id: i32,
        sequence: u64,
        kind: u32,
        failure: u32,
        current_file_number: i32,
        files_completed: u32,
        total_files: u32,
        bytes_completed: u64,
        total_bytes: u64,
        bytes_per_second: f64,
    }

    #[derive(Debug, Eq, PartialEq)]
    struct CapturedFileReceiveBlock {
        abi_version: u32,
        session_epoch: u64,
        transfer_id: i32,
        file_number: u32,
        payload: Vec<u8>,
    }

    #[derive(Debug, PartialEq)]
    struct CapturedDisplayCatalogEntry {
        display_index: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        online: bool,
        scale: f64,
        name: String,
    }

    #[derive(Debug, PartialEq)]
    struct CapturedDisplayCatalogEvent {
        connection_epoch: u64,
        catalog_revision: u64,
        status: u32,
        selected_display_index: Option<u32>,
        entries: Vec<CapturedDisplayCatalogEntry>,
    }

    #[derive(Debug, Eq, PartialEq)]
    struct CapturedDisplaySelectionEvent {
        connection_epoch: u64,
        command_id: u64,
        catalog_revision: u64,
        display_index: u32,
        result: u32,
        failure: u32,
    }

    #[derive(Default, Debug, Eq, PartialEq)]
    struct UploadReadCapture {
        source: Vec<u8>,
        requests: Vec<(u64, i32, u64, u32, u64, usize)>,
        short_write: bool,
        reject: bool,
    }

    unsafe extern "C" fn capture_file_upload_read(
        context: *mut c_void,
        request: *const RDNFileTransferUploadReadRequest,
        bytes_written: *mut usize,
    ) -> i32 {
        if context.is_null() || request.is_null() || bytes_written.is_null() {
            return -4;
        }
        *bytes_written = 0;
        let capture = &*(context as *const Mutex<UploadReadCapture>);
        let request = &*request;
        if request.abi_version != ABI_VERSION || request.buffer.is_null() || request.length == 0 {
            return -4;
        }
        let mut capture = capture.lock().unwrap();
        capture.requests.push((
            request.session_epoch,
            request.transfer_id,
            request.source_token,
            request.file_number,
            request.offset,
            request.length,
        ));
        if capture.reject {
            return -5;
        }
        let Ok(offset) = usize::try_from(request.offset) else {
            return -5;
        };
        let Some(end) = offset.checked_add(request.length) else {
            return -5;
        };
        let Some(source) = capture.source.get(offset..end) else {
            return -5;
        };
        ptr::copy_nonoverlapping(source.as_ptr(), request.buffer, source.len());
        *bytes_written = if capture.short_write {
            request.length.saturating_sub(1)
        } else {
            request.length
        };
        0
    }

    unsafe extern "C" fn capture_file_transfer_event(
        context: *mut c_void,
        event: *const RDNFileTransferEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedFileTransferEvent>>);
        let event = &*event;
        capture.lock().unwrap().push(CapturedFileTransferEvent {
            session_epoch: event.session_epoch,
            transfer_id: event.transfer_id,
            sequence: event.sequence,
            kind: event.kind,
            failure: event.failure,
            current_file_number: event.current_file_number,
            files_completed: event.files_completed,
            total_files: event.total_files,
            bytes_completed: event.bytes_completed,
            total_bytes: event.total_bytes,
            bytes_per_second: event.bytes_per_second,
        });
    }

    unsafe extern "C" fn capture_file_receive_block(
        context: *mut c_void,
        block: *const RDNFileTransferReceiveBlock,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedFileReceiveBlock>>);
        let block = &*block;
        let payload = std::slice::from_raw_parts(block.data, block.length).to_vec();
        capture.lock().unwrap().push(CapturedFileReceiveBlock {
            abi_version: block.abi_version,
            session_epoch: block.session_epoch,
            transfer_id: block.transfer_id,
            file_number: block.file_number,
            payload,
        });
    }

    unsafe extern "C" fn capture_display_catalog(
        context: *mut c_void,
        event: *const RDNDisplayCatalogEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedDisplayCatalogEvent>>);
        let event = &*event;
        let entries = if event.entry_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(event.entries, event.entry_count)
                .iter()
                .map(|entry| {
                    let name = if entry.name_length == 0 {
                        String::new()
                    } else {
                        String::from_utf8(
                            std::slice::from_raw_parts(entry.name_utf8, entry.name_length).to_vec(),
                        )
                        .unwrap()
                    };
                    CapturedDisplayCatalogEntry {
                        display_index: entry.display_index,
                        x: entry.x,
                        y: entry.y,
                        width: entry.width,
                        height: entry.height,
                        online: entry.online,
                        scale: entry.scale,
                        name,
                    }
                })
                .collect()
        };
        capture.lock().unwrap().push(CapturedDisplayCatalogEvent {
            connection_epoch: event.connection_epoch,
            catalog_revision: event.catalog_revision,
            status: event.status,
            selected_display_index: event
                .selected_display_known
                .then_some(event.selected_display_index),
            entries,
        });
    }

    unsafe extern "C" fn capture_display_selection(
        context: *mut c_void,
        event: *const RDNDisplaySelectionEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedDisplaySelectionEvent>>);
        let event = &*event;
        capture.lock().unwrap().push(CapturedDisplaySelectionEvent {
            connection_epoch: event.connection_epoch,
            command_id: event.command_id,
            catalog_revision: event.catalog_revision,
            display_index: event.display_index,
            result: event.result,
            failure: event.failure,
        });
    }

    fn display_info(
        name: &str,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        online: bool,
        scale: f64,
    ) -> DisplayInfo {
        DisplayInfo {
            x,
            y,
            width,
            height,
            name: name.to_owned(),
            online,
            scale,
            ..Default::default()
        }
    }

    unsafe extern "C" fn capture_file_list_event(
        context: *mut c_void,
        event: *const RDNFileTransferListEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedFileListEvent>>);
        let event = &*event;
        let entries = if event.entry_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(event.entries, event.entry_count)
                .iter()
                .map(|entry| {
                    let bytes = std::slice::from_raw_parts(
                        entry.relative_path_utf8,
                        entry.relative_path_length,
                    );
                    (
                        entry.kind,
                        String::from_utf8(bytes.to_vec()).unwrap(),
                        entry.size,
                        entry.modified_time,
                    )
                })
                .collect()
        };
        capture.lock().unwrap().push(CapturedFileListEvent {
            session_epoch: event.session_epoch,
            request_id: event.request_id,
            status: event.status,
            entries,
        });
    }

    unsafe extern "C" fn capture_file_manifest_event(
        context: *mut c_void,
        event: *const RDNFileTransferManifestEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedFileManifestEvent>>);
        let event = &*event;
        let entries = if event.entry_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(event.entries, event.entry_count)
                .iter()
                .map(|entry| {
                    let bytes = std::slice::from_raw_parts(
                        entry.relative_path_utf8,
                        entry.relative_path_length,
                    );
                    (
                        entry.kind,
                        String::from_utf8(bytes.to_vec()).unwrap(),
                        entry.size,
                        entry.modified_time,
                    )
                })
                .collect()
        };
        capture.lock().unwrap().push(CapturedFileManifestEvent {
            session_epoch: event.session_epoch,
            request_id: event.request_id,
            status: event.status,
            part: event.part,
            entries,
        });
    }

    fn remote_list_entry(entry_type: FileType, name: &str, size: u64) -> FileEntry {
        FileEntry {
            entry_type: entry_type.into(),
            name: name.to_owned(),
            size,
            modified_time: 123,
            ..Default::default()
        }
    }

    fn viewer_manifest_file_authorities(
        entries: &[(u64, u64)],
    ) -> Arc<[NativeViewerManifestFileAuthority]> {
        entries
            .iter()
            .map(|(size, modified_time)| NativeViewerManifestFileAuthority {
                size: *size,
                modified_time: *modified_time,
            })
            .collect::<Vec<_>>()
            .into()
    }

    fn nal(nal_type: u8) -> [u8; 3] {
        [nal_type << 1, 1, 0x80]
    }

    #[test]
    fn identifies_annex_b_parameter_sets() {
        let mut data = Vec::new();
        for nal_type in [32, 33, 34, 19] {
            data.extend_from_slice(&[0, 0, 0, 1]);
            data.extend_from_slice(&nal(nal_type));
        }
        let result = inspect_packet(&data);
        assert_eq!(result.format, RDNPacketFormat::AnnexB);
        assert_eq!(result.flags, FLAG_VPS | FLAG_SPS | FLAG_PPS);
    }

    #[test]
    fn identifies_avcc_parameter_sets() {
        let mut data = Vec::new();
        for nal_type in [32, 33, 34, 1] {
            let unit = nal(nal_type);
            data.extend_from_slice(&(unit.len() as u32).to_be_bytes());
            data.extend_from_slice(&unit);
        }
        let result = inspect_packet(&data);
        assert_eq!(result.format, RDNPacketFormat::Avcc);
        assert_eq!(result.flags, FLAG_VPS | FLAG_SPS | FLAG_PPS);
    }

    #[test]
    fn rejects_unframed_packet() {
        assert_eq!(
            inspect_packet(&[0x26, 0x01, 0x80]).format,
            RDNPacketFormat::Unknown
        );
    }

    #[test]
    fn builds_client_housekeeping_test_delay() {
        let message = housekeeping_message();
        let Some(message::Union::TestDelay(delay)) = message.union else {
            panic!("housekeeping message must be TestDelay");
        };
        assert!(delay.from_client);
    }

    #[test]
    fn native_viewer_display_catalog_is_revisioned_and_binds_selected_frames() {
        let captured = Mutex::new(Vec::<CapturedDisplayCatalogEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_display_catalog = Some(capture_display_catalog);
        shared.context = &captured as *const _ as usize;
        ui.shared.connection_epoch.store(7, Ordering::Release);
        ui.shared.active.store(true, Ordering::Release);

        let mut peer = PeerInfo {
            displays: vec![
                display_info("Built-in", 0, 0, 1920, 1080, true, 2.0),
                display_info("Studio", 1920, 0, 2560, 1440, true, 1.0),
            ],
            current_display: 1,
            ..Default::default()
        };
        ui.set_peer_info(&peer);
        ui.set_displays(&peer.displays);
        assert_eq!(captured.lock().unwrap().len(), 1);
        assert_eq!(ui.shared.video_catalog_binding(1), Some((7, 1)));
        assert_eq!(ui.shared.video_catalog_binding(0), None);

        peer.displays[1].width = 3008;
        ui.set_displays(&peer.displays);
        ui.set_current_display(0);
        ui.switch_display(&SwitchDisplay {
            display: 1,
            width: 3008,
            height: 1440,
            ..Default::default()
        });

        assert_eq!(ui.shared.video_catalog_binding(1), Some((7, 2)));
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[
                CapturedDisplayCatalogEvent {
                    connection_epoch: 7,
                    catalog_revision: 1,
                    status: DISPLAY_CATALOG_STATUS_AVAILABLE,
                    selected_display_index: Some(1),
                    entries: vec![
                        CapturedDisplayCatalogEntry {
                            display_index: 0,
                            x: 0,
                            y: 0,
                            width: 1920,
                            height: 1080,
                            online: true,
                            scale: 2.0,
                            name: "Built-in".to_owned(),
                        },
                        CapturedDisplayCatalogEntry {
                            display_index: 1,
                            x: 1920,
                            y: 0,
                            width: 2560,
                            height: 1440,
                            online: true,
                            scale: 1.0,
                            name: "Studio".to_owned(),
                        },
                    ],
                },
                CapturedDisplayCatalogEvent {
                    connection_epoch: 7,
                    catalog_revision: 2,
                    status: DISPLAY_CATALOG_STATUS_AVAILABLE,
                    selected_display_index: Some(1),
                    entries: vec![
                        CapturedDisplayCatalogEntry {
                            display_index: 0,
                            x: 0,
                            y: 0,
                            width: 1920,
                            height: 1080,
                            online: true,
                            scale: 2.0,
                            name: "Built-in".to_owned(),
                        },
                        CapturedDisplayCatalogEntry {
                            display_index: 1,
                            x: 1920,
                            y: 0,
                            width: 3008,
                            height: 1440,
                            online: true,
                            scale: 1.0,
                            name: "Studio".to_owned(),
                        },
                    ],
                },
                CapturedDisplayCatalogEvent {
                    connection_epoch: 7,
                    catalog_revision: 2,
                    status: DISPLAY_CATALOG_STATUS_AVAILABLE,
                    selected_display_index: Some(0),
                    entries: vec![
                        CapturedDisplayCatalogEntry {
                            display_index: 0,
                            x: 0,
                            y: 0,
                            width: 1920,
                            height: 1080,
                            online: true,
                            scale: 2.0,
                            name: "Built-in".to_owned(),
                        },
                        CapturedDisplayCatalogEntry {
                            display_index: 1,
                            x: 1920,
                            y: 0,
                            width: 3008,
                            height: 1440,
                            online: true,
                            scale: 1.0,
                            name: "Studio".to_owned(),
                        },
                    ],
                },
                CapturedDisplayCatalogEvent {
                    connection_epoch: 7,
                    catalog_revision: 2,
                    status: DISPLAY_CATALOG_STATUS_AVAILABLE,
                    selected_display_index: Some(1),
                    entries: vec![
                        CapturedDisplayCatalogEntry {
                            display_index: 0,
                            x: 0,
                            y: 0,
                            width: 1920,
                            height: 1080,
                            online: true,
                            scale: 2.0,
                            name: "Built-in".to_owned(),
                        },
                        CapturedDisplayCatalogEntry {
                            display_index: 1,
                            x: 1920,
                            y: 0,
                            width: 3008,
                            height: 1440,
                            online: true,
                            scale: 1.0,
                            name: "Studio".to_owned(),
                        },
                    ],
                },
            ]
        );
    }

    #[test]
    fn native_viewer_display_catalog_fails_closed_on_malformed_inventory() {
        let captured = Mutex::new(Vec::<CapturedDisplayCatalogEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_display_catalog = Some(capture_display_catalog);
        shared.context = &captured as *const _ as usize;
        ui.shared.connection_epoch.store(9, Ordering::Release);
        ui.shared.active.store(true, Ordering::Release);

        let valid = vec![display_info("Main", 0, 0, 1920, 1080, true, 2.0)];
        ui.set_displays(&valid);
        ui.set_current_display(0);
        assert_eq!(ui.shared.video_catalog_binding(0), Some((9, 1)));

        let malformed = vec![display_info("bad\nname", 0, 0, 1920, 1080, true, 2.0)];
        ui.set_displays(&malformed);
        ui.set_displays(&malformed);
        assert_eq!(ui.shared.video_catalog_binding(0), None);
        assert_eq!(captured.lock().unwrap().len(), 3);
        assert_eq!(
            captured.lock().unwrap()[2],
            CapturedDisplayCatalogEvent {
                connection_epoch: 9,
                catalog_revision: 2,
                status: DISPLAY_CATALOG_STATUS_UNAVAILABLE,
                selected_display_index: None,
                entries: Vec::new(),
            }
        );

        assert!(normalized_native_viewer_display_catalog(&vec![display_info(
            "Main",
            0,
            0,
            1920,
            1080,
            true,
            f64::NAN,
        )])
        .is_none());
        assert!(normalized_native_viewer_display_catalog(
            &(0..=MAX_DISPLAY_CATALOG_ENTRIES)
                .map(|index| display_info(&format!("Display {index}"), 0, 0, 1, 1, true, 1.0))
                .collect::<Vec<_>>()
        )
        .is_none());

        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.set_displays(&valid);
        assert_eq!(captured.lock().unwrap().len(), 3);
    }

    #[test]
    fn native_viewer_display_selection_is_exact_single_flight_and_terminal() {
        let captured = Mutex::new(Vec::<CapturedDisplaySelectionEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_display_selection = Some(capture_display_selection);
        shared.context = &captured as *const _ as usize;
        ui.shared.connection_epoch.store(7, Ordering::Release);
        ui.shared.active.store(true, Ordering::Release);
        ui.shared.authenticated.store(true, Ordering::Release);
        let displays = vec![
            display_info("Main", 0, 0, 1920, 1080, true, 2.0),
            display_info("Studio", 1920, 0, 2560, 1440, true, 1.0),
        ];
        ui.shared.publish_display_catalog(&displays, Some(Some(0)));

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session)),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let client_pointer = &mut client as *mut RDNClient;
        let request = |command_id, catalog_revision, display_index| RDNDisplaySelectionRequest {
            abi_version: ABI_VERSION,
            connection_epoch: 7,
            command_id,
            catalog_revision,
            display_index,
        };

        let current = request(1, 1, 0);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &current) },
            0
        );
        assert!(receiver.try_recv().is_err());
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 1,
                catalog_revision: 1,
                display_index: 0,
                result: DISPLAY_SELECTION_RESULT_ALREADY_SELECTED,
                failure: DISPLAY_SELECTION_FAILURE_NONE,
            }]
        );

        let target = request(2, 1, 1);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &target) },
            0
        );
        let duplicate_while_pending = request(3, 1, 0);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &duplicate_while_pending) },
            -3
        );
        let mut sent_switch = false;
        while let Ok(data) = receiver.try_recv() {
            let Data::Message(message) = data else {
                continue;
            };
            let Some(message::Union::Misc(misc)) = message.union else {
                continue;
            };
            if let Some(misc::Union::SwitchDisplay(display)) = misc.union {
                sent_switch = display.display == 1;
            }
        }
        assert!(sent_switch);
        ui.switch_display(&SwitchDisplay {
            display: 1,
            width: 2560,
            height: 1440,
            ..Default::default()
        });
        assert_eq!(
            captured.lock().unwrap()[1],
            CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 2,
                catalog_revision: 1,
                display_index: 1,
                result: DISPLAY_SELECTION_RESULT_SELECTED,
                failure: DISPLAY_SELECTION_FAILURE_NONE,
            }
        );

        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &target) },
            -5
        );
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &duplicate_while_pending) },
            0
        );
        let mut changed = displays.clone();
        changed[1].width = 3008;
        ui.set_displays(&changed);
        assert_eq!(
            captured.lock().unwrap()[2],
            CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 3,
                catalog_revision: 1,
                display_index: 0,
                result: DISPLAY_SELECTION_RESULT_FAILED,
                failure: DISPLAY_SELECTION_FAILURE_CATALOG_CHANGED,
            }
        );

        let remote_drift = request(4, 2, 0);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &remote_drift) },
            0
        );
        ui.set_current_display(0);
        assert_eq!(
            captured.lock().unwrap()[3],
            CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 4,
                catalog_revision: 2,
                display_index: 0,
                result: DISPLAY_SELECTION_RESULT_FAILED,
                failure: DISPLAY_SELECTION_FAILURE_REMOTE_SELECTION_DRIFT,
            }
        );

        let mut stale_epoch = request(5, 2, 1);
        stale_epoch.connection_epoch = 6;
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &stale_epoch) },
            -10
        );
        let stale_revision = request(5, 1, 1);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &stale_revision) },
            -10
        );
        let out_of_range = request(5, 2, 9);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &out_of_range) },
            -5
        );

        let disconnect = request(5, 2, 1);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &disconnect) },
            0
        );
        client.disconnect(false);
        assert_eq!(
            captured.lock().unwrap()[4],
            CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 5,
                catalog_revision: 2,
                display_index: 1,
                result: DISPLAY_SELECTION_RESULT_FAILED,
                failure: DISPLAY_SELECTION_FAILURE_CONNECTION_CLOSED,
            }
        );

        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &current) },
            -3
        );
    }

    #[test]
    fn viewer_remote_listing_owns_bounded_regular_entries() {
        let mut entries = vec![
            remote_list_entry(FileType::Dir, "资料", 0),
            remote_list_entry(FileType::File, "report.txt", 42),
        ];
        let listing = native_viewer_remote_listing(&entries).unwrap();
        entries[0].name = "changed".to_owned();
        assert_eq!(listing.len(), 2);
        assert_eq!(listing[0].kind, NativeViewerRemoteListEntryKind::Directory);
        assert_eq!(listing[0].relative_path, "资料");
        assert_eq!(listing[0].size, 0);
        assert_eq!(listing[1].kind, NativeViewerRemoteListEntryKind::File);
        assert_eq!(listing[1].relative_path, "report.txt");
        assert_eq!(listing[1].size, 42);
        assert_eq!(listing[1].modified_time, 123);
        assert_eq!(native_viewer_remote_listing(&[]), Some(Vec::new()));
    }

    #[test]
    fn viewer_remote_listing_rejects_unsafe_types_names_aliases_and_bounds() {
        for invalid_name in [
            "",
            ".",
            "..",
            "/absolute",
            "nested/file",
            "windows\\path",
            "bad\nname",
        ] {
            assert!(native_viewer_remote_listing(&[remote_list_entry(
                FileType::File,
                invalid_name,
                1,
            )])
            .is_none());
        }
        assert!(native_viewer_remote_listing(&[
            remote_list_entry(FileType::File, "Report.txt", 1),
            remote_list_entry(FileType::File, "report.TXT", 1),
        ])
        .is_none());
        assert!(native_viewer_remote_listing(&[remote_list_entry(
            FileType::File,
            "partial.FARPANE-PART",
            1,
        )])
        .is_none());

        let mut hidden = remote_list_entry(FileType::File, "hidden", 1);
        hidden.is_hidden = true;
        assert!(native_viewer_remote_listing(&[hidden]).is_none());
        assert!(native_viewer_remote_listing(&[remote_list_entry(
            FileType::Dir,
            "nonempty-dir",
            1,
        )])
        .is_none());
        assert!(
            native_viewer_remote_listing(&[remote_list_entry(FileType::FileLink, "link", 1,)])
                .is_none()
        );
        let mut unknown = remote_list_entry(FileType::File, "unknown", 1);
        unknown.entry_type = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert!(native_viewer_remote_listing(&[unknown]).is_none());

        let too_many: Vec<_> = (0..=MAX_FILE_TRANSFER_LIST_ENTRIES)
            .map(|index| remote_list_entry(FileType::File, &format!("file-{index}"), 1))
            .collect();
        assert!(native_viewer_remote_listing(&too_many).is_none());
        let oversized_name = "a".repeat(MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES + 1);
        assert!(native_viewer_remote_listing(&[remote_list_entry(
            FileType::File,
            &oversized_name,
            1,
        )])
        .is_none());
    }

    #[test]
    fn viewer_recursive_manifest_parts_are_owned_bounded_and_semantic() {
        let mut files = vec![
            remote_list_entry(FileType::File, "资料/report.txt", 42),
            remote_list_entry(FileType::File, "top.txt", 1),
        ];
        let listing = native_viewer_remote_manifest_files(&files).unwrap();
        files[0].name = "changed".to_owned();
        assert_eq!(listing[0].relative_path, "资料/report.txt");
        assert!(native_viewer_remote_manifest_files(&[remote_list_entry(
            FileType::Dir,
            "folder",
            0
        ),])
        .is_none());
        assert!(native_viewer_remote_manifest_files(&[remote_list_entry(
            FileType::File,
            "a/../escape",
            1
        ),])
        .is_none());

        let response = ReadEmptyDirsResponse {
            path: "/".to_owned(),
            empty_dirs: vec![FileDirectory {
                path: "/资料/empty".to_owned(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let directories = native_viewer_remote_manifest_empty_directories(&response).unwrap();
        assert_eq!(directories[0].relative_path, "资料/empty");
        assert_eq!(
            directories[0].kind,
            NativeViewerRemoteListEntryKind::Directory
        );

        let invalid = ReadEmptyDirsResponse {
            path: "/".to_owned(),
            empty_dirs: vec![FileDirectory {
                path: "/bad/../empty".to_owned(),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(native_viewer_remote_manifest_empty_directories(&invalid).is_none());
    }

    #[test]
    fn requests_capture_headroom_for_native_decoder() {
        let message = native_stream_configuration_message(native_stream_fps(false));
        let Some(message::Union::Misc(misc)) = message.union else {
            panic!("native stream configuration must be a Misc message");
        };
        let Some(misc::Union::Option(option)) = misc.union else {
            panic!("native stream configuration must carry an OptionMessage");
        };
        assert_eq!(option.custom_fps, 36);
        assert_eq!(native_stream_fps(true), 38);
    }

    #[test]
    fn maps_semantic_pointer_masks_without_exposing_wire_types() {
        assert_eq!(
            pointer_mask(RDNPointerKind::Down, POINTER_BUTTON_LEFT),
            Some(MOUSE_TYPE_DOWN | (MOUSE_BUTTON_LEFT << 3))
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::Up, POINTER_BUTTON_RIGHT),
            Some(MOUSE_TYPE_UP | (MOUSE_BUTTON_RIGHT << 3))
        );
        assert_eq!(pointer_mask(RDNPointerKind::Down, 0), None);
        assert_eq!(
            pointer_mask(
                RDNPointerKind::Move,
                POINTER_BUTTON_LEFT | POINTER_BUTTON_RIGHT
            ),
            Some(MOUSE_TYPE_MOVE | ((MOUSE_BUTTON_LEFT | MOUSE_BUTTON_RIGHT) << 3))
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::Scroll, 0),
            Some(MOUSE_TYPE_WHEEL)
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::Scroll, POINTER_BUTTON_LEFT),
            None
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::PreciseScroll, 0),
            Some(MOUSE_TYPE_TRACKPAD)
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::PreciseScroll, POINTER_BUTTON_RIGHT),
            None
        );
        assert!(pointer_payload_fields_are_canonical(
            RDNPointerKind::Move,
            10,
            20,
            0,
            0
        ));
        assert!(!pointer_payload_fields_are_canonical(
            RDNPointerKind::Down,
            10,
            20,
            1,
            0
        ));
        assert!(pointer_payload_fields_are_canonical(
            RDNPointerKind::Scroll,
            0,
            0,
            3,
            -3
        ));
        assert!(!pointer_payload_fields_are_canonical(
            RDNPointerKind::PreciseScroll,
            1,
            0,
            3,
            -3
        ));
        assert_eq!(clamp_pointer_coordinates(-1, 200, (100, 50)), Some((0, 49)));
        assert_eq!(clamp_pointer_coordinates(0, 0, (0, 50)), None);
        assert_eq!(
            normalized_pointer_coordinates(RDNPointerKind::Scroll, 0, 0, 0, 0, (0, 0)),
            None
        );
        assert_eq!(
            normalized_pointer_coordinates(RDNPointerKind::PreciseScroll, 0, 0, 500, -500, (0, 0)),
            Some((120, -120))
        );
    }

    #[test]
    fn maps_basic_semantic_keys() {
        assert_eq!(
            key_name(RDNKeyCode::Character, 'a' as u32).as_deref(),
            Some("a")
        );
        assert_eq!(
            key_name(RDNKeyCode::Return, 0).as_deref(),
            Some("VK_RETURN")
        );
        assert_eq!(key_name(RDNKeyCode::Command, 0).as_deref(), Some("Meta"));
        assert!(key_name(RDNKeyCode::Character, 0).is_none());
        assert!(key_name(RDNKeyCode::Character, 0x11_0000).is_none());
        assert!(key_payload_fields_are_canonical(
            RDNKeyCode::Character,
            'a' as u32,
            0
        ));
        assert!(!key_payload_fields_are_canonical(
            RDNKeyCode::Character,
            'a' as u32,
            1
        ));
        assert!(key_payload_fields_are_canonical(RDNKeyCode::Return, 0, 0));
        assert!(!key_payload_fields_are_canonical(
            RDNKeyCode::Return,
            'a' as u32,
            0
        ));
        assert!(!key_payload_fields_are_canonical(RDNKeyCode::Return, 0, 1));
        assert!(key_payload_fields_are_canonical(
            RDNKeyCode::Physical,
            0,
            55
        ));
        assert!(!key_payload_fields_are_canonical(
            RDNKeyCode::Physical,
            'a' as u32,
            55
        ));
        assert_eq!(physical_macos_keycode(0), Some(0));
        assert_eq!(physical_macos_keycode(0x7f), Some(0x7f));
        assert_eq!(physical_macos_keycode(0x80), None);
    }

    #[test]
    fn gates_input_on_authentication_and_remote_permission() {
        assert!(!input_is_allowed(false, true));
        assert!(!input_is_allowed(false, false));
        assert!(!input_is_allowed(true, false));
        assert!(input_is_allowed(true, true));
    }

    #[test]
    fn gates_viewer_clipboard_receive_on_lifecycle_and_both_policies() {
        for missing in 0..4 {
            let mut gates = [true; 4];
            gates[missing] = false;
            assert!(!clipboard_receive_allowed(
                gates[0], gates[1], gates[2], gates[3]
            ));
        }
        assert!(clipboard_receive_allowed(true, true, true, true));
    }

    #[test]
    fn native_viewer_clipboard_permission_defaults_enabled_and_honors_explicit_revoke() {
        let ui = BridgeUi::default();
        assert!(ui.shared.remote_clipboard_enabled.load(Ordering::Acquire));

        ui.set_permission("clipboard", false);
        assert!(!ui.shared.remote_clipboard_enabled.load(Ordering::Acquire));

        ui.set_permission("clipboard", true);
        assert!(ui.shared.remote_clipboard_enabled.load(Ordering::Acquire));
    }

    #[test]
    fn native_viewer_rich_receive_preparse_gate_requires_every_authority() {
        let ui = BridgeUi::default();
        assert!(!ui.native_clipboard_rich_text_enabled());
        ui.shared.active.store(true, Ordering::Release);
        ui.shared.authenticated.store(true, Ordering::Release);
        ui.shared
            .receive_clipboard_rich_text
            .store(true, Ordering::Release);
        ui.shared
            .remote_clipboard_enabled
            .store(true, Ordering::Release);
        assert!(ui.native_clipboard_rich_text_enabled());

        for gate in [
            &ui.shared.active,
            &ui.shared.authenticated,
            &ui.shared.receive_clipboard_rich_text,
            &ui.shared.remote_clipboard_enabled,
        ] {
            gate.store(false, Ordering::Release);
            assert!(!ui.native_clipboard_rich_text_enabled());
            gate.store(true, Ordering::Release);
        }
    }

    #[test]
    fn validates_bounded_utf8_text_without_logging_content() {
        assert_eq!(validated_text("中文输入".as_bytes()), Some("中文输入"));
        assert!(validated_text(b"").is_none());
        assert!(validated_text(b"a\0b").is_none());
        assert!(validated_text(&[0xff]).is_none());
        assert!(validated_text(&vec![b'a'; MAX_TEXT_BYTES + 1]).is_none());
    }

    fn clipboard_fixture(content: Vec<u8>, compress: bool, format: ClipboardFormat) -> Clipboard {
        Clipboard {
            content: content.into(),
            compress,
            format: format.into(),
            ..Default::default()
        }
    }

    #[test]
    fn native_viewer_clipboard_accepts_only_one_bounded_utf8_text_entry() {
        let text = clipboard_fixture(
            "Viewer 小文本".as_bytes().to_vec(),
            false,
            ClipboardFormat::Text,
        );
        assert_eq!(
            native_viewer_clipboard_text(std::slice::from_ref(&text)).as_deref(),
            Some("Viewer 小文本")
        );
        assert!(native_viewer_clipboard_text(&[]).is_none());
        assert!(native_viewer_clipboard_text(&[text.clone(), text]).is_none());
        assert!(native_viewer_clipboard_text(&[clipboard_fixture(
            b"<b>rich</b>".to_vec(),
            false,
            ClipboardFormat::Html,
        )])
        .is_none());
        assert!(native_viewer_clipboard_text(&[clipboard_fixture(
            b"a\0b".to_vec(),
            false,
            ClipboardFormat::Text,
        )])
        .is_none());
        assert!(native_viewer_clipboard_text(&[clipboard_fixture(
            vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1],
            false,
            ClipboardFormat::Text,
        )])
        .is_none());
    }

    #[test]
    fn native_viewer_clipboard_bounds_decompression_and_builds_canonical_message() {
        let plain = vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES];
        let compressed = hbb_common::compress::compress(&plain);
        assert_eq!(
            native_viewer_clipboard_text(&[clipboard_fixture(
                compressed,
                true,
                ClipboardFormat::Text,
            )])
            .map(|text| text.len()),
            Some(MAX_CLIPBOARD_TEXT_UTF8_BYTES)
        );

        let oversized =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1]);
        assert!(native_viewer_clipboard_text(&[clipboard_fixture(
            oversized,
            true,
            ClipboardFormat::Text,
        )])
        .is_none());

        let message = native_viewer_clipboard_message("发送文本".as_bytes())
            .expect("bounded clipboard text message");
        let Some(message::Union::Clipboard(clipboard)) = message.union else {
            panic!("viewer clipboard output must be one Clipboard message");
        };
        assert_eq!(clipboard.format.enum_value(), Ok(ClipboardFormat::Text));
        assert_eq!(clipboard.content.as_ref(), "发送文本".as_bytes());
        assert!(!clipboard.compress);
        assert!(clipboard.special_name.is_empty());
        assert_eq!((clipboard.width, clipboard.height), (0, 0));
        assert!(native_viewer_clipboard_message(b"").is_none());
        assert!(native_viewer_clipboard_message(b"a\0b").is_none());
        assert!(native_viewer_clipboard_message(&[0xff]).is_none());
    }

    #[test]
    fn native_viewer_rich_clipboard_accepts_only_owned_bounded_canonical_bundle() {
        let mut source = vec![
            clipboard_fixture(b"plain fallback".to_vec(), false, ClipboardFormat::Text),
            clipboard_fixture(b"{\\rtf1 rich}".to_vec(), false, ClipboardFormat::Rtf),
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html),
        ];
        let bundle = native_viewer_clipboard_rich_text(&source).expect("canonical rich bundle");
        source
            .iter_mut()
            .for_each(|clipboard| clipboard.content.clear());
        assert_eq!(bundle.plain_text.as_deref(), Some("plain fallback"));
        assert_eq!(bundle.rtf.as_deref(), Some("{\\rtf1 rich}"));
        assert_eq!(bundle.html.as_deref(), Some("<b>rich</b>"));

        let at_limit = vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES];
        let compressed = hbb_common::compress::compress(&at_limit);
        let bundle = native_viewer_clipboard_rich_text(&[clipboard_fixture(
            compressed,
            true,
            ClipboardFormat::Html,
        )])
        .expect("bounded compressed rich entry");
        assert_eq!(bundle.html.map(|html| html.len()), Some(at_limit.len()));
    }

    #[test]
    fn native_viewer_rich_clipboard_rejects_ambiguous_or_unbounded_input() {
        let plain = clipboard_fixture(b"plain".to_vec(), false, ClipboardFormat::Text);
        let rtf = clipboard_fixture(b"{\\rtf1}".to_vec(), false, ClipboardFormat::Rtf);
        let html = clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        assert!(native_viewer_clipboard_rich_text(&[]).is_none());
        assert!(native_viewer_clipboard_rich_text(std::slice::from_ref(&plain)).is_none());
        assert!(native_viewer_clipboard_rich_text(&[
            plain.clone(),
            rtf.clone(),
            html.clone(),
            rtf.clone(),
        ])
        .is_none());
        assert!(native_viewer_clipboard_rich_text(&[rtf.clone(), rtf.clone()]).is_none());

        for invalid in [
            clipboard_fixture(Vec::new(), false, ClipboardFormat::Html),
            clipboard_fixture(b"before\0after".to_vec(), false, ClipboardFormat::Html),
            clipboard_fixture(vec![0xff], false, ClipboardFormat::Rtf),
            clipboard_fixture(
                vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES + 1],
                false,
                ClipboardFormat::Html,
            ),
            clipboard_fixture(b"image".to_vec(), false, ClipboardFormat::ImagePng),
            clipboard_fixture(b"special".to_vec(), false, ClipboardFormat::Special),
        ] {
            assert!(native_viewer_clipboard_rich_text(&[invalid]).is_none());
        }

        let compressed_over_limit =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES + 1]);
        assert!(native_viewer_clipboard_rich_text(&[clipboard_fixture(
            compressed_over_limit,
            true,
            ClipboardFormat::Rtf,
        )])
        .is_none());

        let mut wrong_metadata = html.clone();
        wrong_metadata.special_name = "public.html".to_owned();
        assert!(native_viewer_clipboard_rich_text(&[wrong_metadata]).is_none());
        let mut wrong_dimensions = html;
        wrong_dimensions.width = 1;
        assert!(native_viewer_clipboard_rich_text(&[wrong_dimensions]).is_none());
        let mut unknown = rtf;
        unknown.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert!(native_viewer_clipboard_rich_text(&[unknown]).is_none());
    }

    #[test]
    fn native_viewer_image_receive_preparse_gate_requires_every_authority() {
        let ui = BridgeUi::default();
        assert!(!ui.native_clipboard_image_enabled());
        ui.shared.active.store(true, Ordering::Release);
        ui.shared.authenticated.store(true, Ordering::Release);
        ui.shared
            .receive_clipboard_image
            .store(true, Ordering::Release);
        ui.shared
            .remote_clipboard_enabled
            .store(true, Ordering::Release);
        assert!(ui.native_clipboard_image_enabled());

        for gate in [
            &ui.shared.active,
            &ui.shared.authenticated,
            &ui.shared.receive_clipboard_image,
            &ui.shared.remote_clipboard_enabled,
        ] {
            gate.store(false, Ordering::Release);
            assert!(!ui.native_clipboard_image_enabled());
            gate.store(true, Ordering::Release);
        }
    }

    #[test]
    fn native_viewer_image_clipboard_accepts_owned_bounded_canonical_payloads() {
        let mut rgba = clipboard_fixture(vec![1, 2, 3, 255], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        let image = native_viewer_clipboard_image(std::slice::from_ref(&rgba)).unwrap();
        assert_eq!(
            image.kind,
            NativeViewerClipboardImageKind::Rgba {
                width: 1,
                height: 1,
            }
        );
        rgba.content.clear();
        assert_eq!(image.payload, vec![1, 2, 3, 255]);

        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[7, 8, 9, 255]).unwrap();
        let image = native_viewer_clipboard_image(&[clipboard_fixture(
            png.clone(),
            false,
            ClipboardFormat::ImagePng,
        )])
        .unwrap();
        assert_eq!(image.kind, NativeViewerClipboardImageKind::Png);
        assert_eq!(image.payload, png);

        let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".to_vec();
        let image = native_viewer_clipboard_image(&[clipboard_fixture(
            hbb_common::compress::compress(&svg),
            true,
            ClipboardFormat::ImageSvg,
        )])
        .unwrap();
        assert_eq!(image.kind, NativeViewerClipboardImageKind::Svg);
        assert_eq!(image.payload, svg);
    }

    #[test]
    fn native_viewer_image_clipboard_rejects_ambiguous_or_unbounded_input() {
        let mut rgba = clipboard_fixture(vec![1, 2, 3], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        assert!(native_viewer_clipboard_image(&[rgba]).is_none());

        let mut excessive = clipboard_fixture(vec![0; 4], false, ClipboardFormat::ImageRgba);
        excessive.width = MAX_CLIPBOARD_IMAGE_DIMENSION + 1;
        excessive.height = 1;
        assert!(native_viewer_clipboard_image(&[excessive.clone()]).is_none());
        excessive.width = MAX_CLIPBOARD_IMAGE_DIMENSION;
        excessive.height = MAX_CLIPBOARD_IMAGE_DIMENSION;
        assert!(native_viewer_clipboard_image(&[excessive]).is_none());

        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[0, 0, 0, 255]).unwrap();
        assert!(native_viewer_clipboard_image(&[clipboard_fixture(
            hbb_common::compress::compress(&png),
            true,
            ClipboardFormat::ImagePng,
        )])
        .is_none());
        assert!(native_viewer_clipboard_image(&[clipboard_fixture(
            png[..24].to_vec(),
            false,
            ClipboardFormat::ImagePng,
        )])
        .is_none());

        for invalid_svg in [
            vec![0xff],
            b"before\0after".to_vec(),
            b"<html></html>".to_vec(),
            b"<!DOCTYPE svg><svg></svg>".to_vec(),
        ] {
            assert!(native_viewer_clipboard_image(&[clipboard_fixture(
                invalid_svg,
                false,
                ClipboardFormat::ImageSvg,
            )])
            .is_none());
        }
        assert!(native_viewer_clipboard_image(&[clipboard_fixture(
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_SVG_UTF8_BYTES + 1]),
            true,
            ClipboardFormat::ImageSvg,
        )])
        .is_none());

        let mut special = clipboard_fixture(png, false, ClipboardFormat::ImagePng);
        special.special_name = "public.png".to_owned();
        assert!(native_viewer_clipboard_image(&[special]).is_none());
        assert!(native_viewer_clipboard_image(&[]).is_none());
    }

    fn image_payload(
        format: u32,
        bytes: &[u8],
        width: u32,
        height: u32,
    ) -> RDNClipboardImagePayload {
        RDNClipboardImagePayload {
            abi_version: ABI_VERSION,
            format,
            data: bytes.as_ptr(),
            length: bytes.len(),
            width,
            height,
        }
    }

    #[test]
    fn native_viewer_image_clipboard_builds_canonical_outbound_messages() {
        let rgba = [1, 2, 3, 255];
        let payload = image_payload(CLIPBOARD_IMAGE_FORMAT_RGBA, &rgba, 1, 1);
        let message = unsafe { native_viewer_clipboard_image_message(&payload) }.unwrap();
        let Some(message::Union::Clipboard(clipboard)) = message.union else {
            panic!("one image must use Clipboard");
        };
        assert_eq!(
            clipboard.format.enum_value(),
            Ok(ClipboardFormat::ImageRgba)
        );
        assert_eq!(clipboard.content.as_ref(), rgba);
        assert_eq!((clipboard.width, clipboard.height), (1, 1));
        assert!(!clipboard.compress);

        let svg = b"<svg></svg>";
        let payload = image_payload(CLIPBOARD_IMAGE_FORMAT_SVG, svg, 0, 0);
        let message = unsafe { native_viewer_clipboard_image_message(&payload) }.unwrap();
        let Some(message::Union::Clipboard(clipboard)) = message.union else {
            panic!("one image must use Clipboard");
        };
        assert_eq!(clipboard.format.enum_value(), Ok(ClipboardFormat::ImageSvg));
        assert_eq!(clipboard.content.as_ref(), svg);
        assert_eq!((clipboard.width, clipboard.height), (0, 0));
        assert!(!clipboard.compress);
    }

    #[test]
    fn native_viewer_image_clipboard_rejects_invalid_outbound_payloads() {
        let rgba = [1, 2, 3, 255];
        let mut payload = image_payload(CLIPBOARD_IMAGE_FORMAT_RGBA, &rgba, 1, 1);
        payload.abi_version += 1;
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(CLIPBOARD_IMAGE_FORMAT_RGBA, &rgba, 1, 1);
        payload.data = ptr::null();
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(CLIPBOARD_IMAGE_FORMAT_RGBA, &rgba[..3], 1, 1);
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(CLIPBOARD_IMAGE_FORMAT_PNG, b"not png", 0, 0);
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(CLIPBOARD_IMAGE_FORMAT_SVG, b"<html></html>", 0, 0);
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(999, &rgba, 0, 0);
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());
    }

    #[test]
    fn native_viewer_image_send_requires_every_lifecycle_and_permission_gate() {
        let ui = BridgeUi::default();
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(None),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let svg = b"<svg></svg>";
        let payload = image_payload(CLIPBOARD_IMAGE_FORMAT_SVG, svg, 0, 0);
        let client_pointer = &mut client as *mut RDNClient;

        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -3
        );
        ui.shared.active.store(true, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -6
        );
        ui.shared.authenticated.store(true, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -7
        );
        ui.shared
            .send_clipboard_image
            .store(true, Ordering::Release);
        ui.shared
            .remote_clipboard_enabled
            .store(false, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -8
        );
        ui.shared
            .remote_clipboard_enabled
            .store(true, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -3
        );
    }

    #[test]
    fn viewer_file_transfer_v9_seam_is_exact_pair_and_fail_closed() {
        assert_eq!(viewer_file_transfer_mode_admission(false, 0, false), 0);
        assert_eq!(viewer_file_transfer_mode_admission(false, 1, false), -5);
        assert_eq!(viewer_file_transfer_mode_admission(true, 0, false), -5);
        assert_eq!(viewer_file_transfer_mode_admission(true, 1, false), 0);
        assert_eq!(viewer_file_transfer_mode_admission(true, 1, true), -5);
        assert!(native_viewer_audio_disabled(false));
        assert!(!native_viewer_audio_disabled(true));
        assert!(!native_viewer_audio_is_active(false, false, false));
        assert!(!native_viewer_audio_is_active(false, true, true));
        assert!(!native_viewer_audio_is_active(true, false, true));
        assert!(!native_viewer_audio_is_active(true, true, false));
        assert!(native_viewer_audio_is_active(true, true, true));
        assert!(native_remote_audio_permission_event(0, true).is_none());
        let permission = native_remote_audio_permission_event(9, false).unwrap();
        assert_eq!(permission.abi_version, ABI_VERSION);
        assert_eq!(permission.connection_epoch, 9);
        assert_eq!(permission.permission, REMOTE_PERMISSION_AUDIO);
        assert!(!permission.enabled);

        let ui = BridgeUi::default();
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(None),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let client_pointer = &mut client as *mut RDNClient;
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 1, 1) },
            -3
        );
        ui.shared.active.store(true, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 0, 1) },
            -4
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 1, 0) },
            -4
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 1, 1) },
            -7
        );
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(2, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 1, 1) },
            -10
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 2, 1) },
            -6
        );
    }

    #[test]
    fn viewer_file_transfer_mode_dispatches_exact_epoch_cancel_only_when_ready() {
        let desktop_ui = BridgeUi::default();
        desktop_ui.shared.active.store(true, Ordering::Release);
        desktop_ui.on_connected(ConnType::DEFAULT_CONN);
        assert!(desktop_ui.shared.input_allowed.load(Ordering::Acquire));

        let ui = BridgeUi::default();
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        assert!(ui.shared.authenticated.load(Ordering::Acquire));
        assert!(!ui.shared.input_allowed.load(Ordering::Acquire));

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            server_file_transfer_enabled: Arc::new(RwLock::new(false)),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session.clone())),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let client_pointer = &mut client as *mut RDNClient;

        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 6, 23) },
            -10
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 7, 23) },
            -8
        );
        *session.server_file_transfer_enabled.write().unwrap() = true;
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 7, 23) },
            0
        );
        assert!(matches!(receiver.try_recv(), Ok(Data::CancelJob(23))));
    }

    #[test]
    fn viewer_file_transfer_waits_for_remote_permission_before_ready() {
        let captured = Mutex::new(Vec::<(u32, i32, String)>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_state = Some(capture_state);
        shared.context = &captured as *const _ as usize;
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);

        ui.on_connected(ConnType::FILE_TRANSFER);
        assert_eq!(
            *captured.lock().unwrap(),
            vec![(
                RDNState::Authenticated as u32,
                0,
                "authenticated".to_owned()
            )],
            "authentication alone must not admit file commands"
        );

        ui.set_permission("file", true);
        assert_eq!(
            *captured.lock().unwrap(),
            vec![
                (
                    RDNState::Authenticated as u32,
                    0,
                    "authenticated".to_owned()
                ),
                (
                    RDNState::Streaming as u32,
                    0,
                    "file-transfer-ready".to_owned()
                )
            ]
        );
        ui.set_permission("file", true);
        assert_eq!(captured.lock().unwrap().len(), 2);
    }

    #[test]
    fn viewer_file_transfer_list_root_is_exact_single_flight_and_callback_scoped() {
        let captured = Mutex::new(Vec::<CapturedFileListEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_list = Some(capture_file_list_event);
        shared.context = &captured as *const _ as usize;
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            server_file_transfer_enabled: Arc::new(RwLock::new(false)),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session.clone())),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let client_pointer = &mut client as *mut RDNClient;

        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 6, 41) },
            -10
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 41) },
            -8
        );
        *session.server_file_transfer_enabled.write().unwrap() = true;
        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 41) },
            0
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 42) },
            -3
        );
        let Ok(Data::Message(message)) = receiver.try_recv() else {
            panic!("list request must send one message");
        };
        let Some(message::Union::FileAction(action)) = message.union else {
            panic!("list request must send FileAction");
        };
        let Some(file_action::Union::ReadDir(read)) = action.union else {
            panic!("list request must send ReadDir");
        };
        assert_eq!(read.path, "/");
        assert!(!read.include_hidden);

        ui.update_folder_files(
            0,
            &vec![
                remote_list_entry(FileType::Dir, "资料", 0),
                remote_list_entry(FileType::File, "report.txt", 42),
            ],
            "/".to_owned(),
            false,
            false,
        );
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedFileListEvent {
                session_epoch: 7,
                request_id: 41,
                status: FILE_TRANSFER_LIST_SUCCESS,
                entries: vec![
                    (
                        FILE_TRANSFER_LIST_ENTRY_DIRECTORY,
                        "资料".to_owned(),
                        0,
                        123
                    ),
                    (
                        FILE_TRANSFER_LIST_ENTRY_FILE,
                        "report.txt".to_owned(),
                        42,
                        123
                    ),
                ],
            }]
        );
        assert!(ui
            .shared
            .pending_file_list_request
            .lock()
            .unwrap()
            .is_none());

        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 42) },
            0
        );
        let _ = receiver.try_recv();
        ui.update_folder_files(
            0,
            &vec![
                remote_list_entry(FileType::File, "Alias", 1),
                remote_list_entry(FileType::File, "alias", 1),
            ],
            "/".to_owned(),
            false,
            false,
        );
        assert_eq!(
            captured.lock().unwrap()[1].status,
            FILE_TRANSFER_LIST_REJECTED
        );
        assert!(captured.lock().unwrap()[1].entries.is_empty());

        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 43) },
            0
        );
        let _ = receiver.try_recv();
        ui.job_error(0, "remote detail must not cross ABI".to_owned(), -1);
        assert_eq!(
            captured.lock().unwrap()[2].status,
            FILE_TRANSFER_LIST_UNAVAILABLE
        );
        assert!(captured.lock().unwrap()[2].entries.is_empty());
    }

    #[test]
    fn viewer_recursive_manifest_command_delivers_two_exact_parts_and_clears() {
        let captured = Mutex::new(Vec::<CapturedFileManifestEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_manifest = Some(capture_file_manifest_event);
        shared.context = &captured as *const _ as usize;
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            server_file_transfer_enabled: Arc::new(RwLock::new(true)),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session)),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let client_pointer = &mut client as *mut RDNClient;

        assert_eq!(
            unsafe { rdn_client_file_transfer_manifest_root(client_pointer, 6, 51) },
            -10
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_manifest_root(client_pointer, 7, 51) },
            0
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_manifest_root(client_pointer, 7, 52) },
            -3
        );

        let Ok(Data::Message(files_message)) = receiver.try_recv() else {
            panic!("manifest request must send recursive files message");
        };
        let Some(message::Union::FileAction(files_action)) = files_message.union else {
            panic!("recursive files message must be FileAction");
        };
        let Some(file_action::Union::AllFiles(files)) = files_action.union else {
            panic!("recursive files message must be AllFiles");
        };
        assert_eq!(
            (files.id, files.path.as_str(), files.include_hidden),
            (51, "/", false)
        );

        let Ok(Data::Message(directories_message)) = receiver.try_recv() else {
            panic!("manifest request must send empty-directories message");
        };
        let Some(message::Union::FileAction(directories_action)) = directories_message.union else {
            panic!("empty-directories message must be FileAction");
        };
        let Some(file_action::Union::ReadEmptyDirs(directories)) = directories_action.union else {
            panic!("empty-directories message must be ReadEmptyDirs");
        };
        assert_eq!(
            (directories.path.as_str(), directories.include_hidden),
            ("/", false)
        );

        ui.update_empty_dirs(ReadEmptyDirsResponse {
            path: "/".to_owned(),
            empty_dirs: vec![FileDirectory {
                path: "/资料/empty".to_owned(),
                ..Default::default()
            }],
            ..Default::default()
        });
        ui.update_folder_files(
            51,
            &vec![remote_list_entry(FileType::File, "资料/report.txt", 42)],
            "/".to_owned(),
            false,
            false,
        );
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[
                CapturedFileManifestEvent {
                    session_epoch: 7,
                    request_id: 51,
                    status: FILE_TRANSFER_LIST_SUCCESS,
                    part: FILE_TRANSFER_MANIFEST_PART_EMPTY_DIRECTORIES,
                    entries: vec![(
                        FILE_TRANSFER_LIST_ENTRY_DIRECTORY,
                        "资料/empty".to_owned(),
                        0,
                        0,
                    )],
                },
                CapturedFileManifestEvent {
                    session_epoch: 7,
                    request_id: 51,
                    status: FILE_TRANSFER_LIST_SUCCESS,
                    part: FILE_TRANSFER_MANIFEST_PART_FILES,
                    entries: vec![(
                        FILE_TRANSFER_LIST_ENTRY_FILE,
                        "资料/report.txt".to_owned(),
                        42,
                        123,
                    )],
                },
            ]
        );
        assert!(ui
            .shared
            .pending_file_manifest_request
            .lock()
            .unwrap()
            .is_none());

        assert_eq!(
            unsafe { rdn_client_file_transfer_manifest_root(client_pointer, 7, 52) },
            -3,
            "an untagged empty-directory response makes manifest single-use per epoch"
        );
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn viewer_receive_block_owns_raw_and_bounded_decompressed_payloads() {
        let job = NativeViewerDownloadJob {
            session_epoch: 7,
            manifest_request_id: 51,
            transfer_id: 61,
            total_files: 2,
            total_bytes: 42,
            manifest_files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
            next_digest_file_number: 2,
            sequence: 0,
            files_completed: 0,
            bytes_completed: 0,
        };
        let raw = FileTransferBlock {
            id: 61,
            file_num: 0,
            data: b"raw".to_vec().into(),
            ..Default::default()
        };
        assert_eq!(
            job.receive_block(&raw),
            Some(NativeViewerReceiveBlock {
                session_epoch: 7,
                transfer_id: 61,
                file_number: 0,
                payload: b"raw".to_vec(),
            })
        );

        let plain = vec![b'a'; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES];
        let compressed = FileTransferBlock {
            id: 61,
            file_num: 1,
            data: hbb_common::compress::compress(&plain).into(),
            compressed: true,
            ..Default::default()
        };
        assert_eq!(
            job.receive_block(&compressed),
            Some(NativeViewerReceiveBlock {
                session_epoch: 7,
                transfer_id: 61,
                file_number: 1,
                payload: plain,
            })
        );
    }

    #[test]
    fn viewer_receive_block_rejects_wrong_job_file_and_payload_bounds() {
        let job = NativeViewerDownloadJob {
            session_epoch: 7,
            manifest_request_id: 51,
            transfer_id: 61,
            total_files: 2,
            total_bytes: 42,
            manifest_files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
            next_digest_file_number: 2,
            sequence: 0,
            files_completed: 0,
            bytes_completed: 0,
        };
        let block = |id, file_num, data: Vec<u8>, compressed| FileTransferBlock {
            id,
            file_num,
            data: data.into(),
            compressed,
            ..Default::default()
        };

        assert!(job
            .receive_block(&block(60, 0, b"x".to_vec(), false))
            .is_none());
        assert!(job
            .receive_block(&block(61, -1, b"x".to_vec(), false))
            .is_none());
        assert!(job
            .receive_block(&block(61, 2, b"x".to_vec(), false))
            .is_none());
        assert!(job
            .receive_block(&block(61, 0, Vec::new(), false))
            .is_none());
        assert!(job
            .receive_block(&block(
                61,
                0,
                vec![0; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES + 1],
                false,
            ))
            .is_none());
        assert!(job
            .receive_block(&block(61, 0, b"not-zstd".to_vec(), true))
            .is_none());
        assert!(job
            .receive_block(&block(
                61,
                0,
                hbb_common::compress::compress(&vec![
                    b'a';
                    hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES
                        + 1
                ]),
                true,
            ))
            .is_none());
    }

    #[test]
    fn viewer_receive_block_callback_is_exact_session_and_callback_scoped() {
        let captured = Mutex::new(Vec::<CapturedFileReceiveBlock>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_receive_block = Some(capture_file_receive_block);
        shared.context = &captured as *const _ as usize;
        let mut block = NativeViewerReceiveBlock {
            session_epoch: 7,
            transfer_id: 61,
            file_number: 1,
            payload: b"owned".to_vec(),
        };

        assert!(!ui.shared.emit_file_transfer_receive_block(&block));
        ui.shared.active.store(true, Ordering::Release);
        ui.shared.authenticated.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        assert!(ui.shared.emit_file_transfer_receive_block(&block));
        block.payload.fill(b'x');
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedFileReceiveBlock {
                abi_version: ABI_VERSION,
                session_epoch: 7,
                transfer_id: 61,
                file_number: 1,
                payload: b"owned".to_vec(),
            }]
        );

        block.session_epoch = 8;
        assert!(!ui.shared.emit_file_transfer_receive_block(&block));
        ui.shared.authenticated.store(false, Ordering::Release);
        block.session_epoch = 7;
        assert!(!ui.shared.emit_file_transfer_receive_block(&block));
        assert_eq!(captured.lock().unwrap().len(), 1);
    }

    #[test]
    fn viewer_io_loop_hook_consumes_only_registered_download_blocks() {
        let captured = Mutex::new(Vec::<CapturedFileReceiveBlock>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_receive_block = Some(capture_file_receive_block);
        shared.context = &captured as *const _ as usize;
        shared.active.store(true, Ordering::Release);
        shared.authenticated.store(true, Ordering::Release);
        shared.file_transfer_enabled.store(true, Ordering::Release);
        shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        shared.active_file_download_jobs.lock().unwrap().insert(
            61,
            NativeViewerDownloadJob {
                session_epoch: 7,
                manifest_request_id: 51,
                transfer_id: 61,
                total_files: 2,
                total_bytes: 10,
                manifest_files: viewer_manifest_file_authorities(&[(5, 100), (5, 200)]),
                next_digest_file_number: 2,
                sequence: 0,
                files_completed: 0,
                bytes_completed: 0,
            },
        );

        let block = |id, file_num, data: Vec<u8>| FileTransferBlock {
            id,
            file_num,
            data: data.into(),
            compressed: false,
            ..Default::default()
        };
        assert!(!ui.native_file_transfer_receive_block(&block(60, 0, b"foreign".to_vec())));
        assert!(ui.native_file_transfer_receive_block(&block(61, 0, b"owned".to_vec())));
        assert!(ui.native_file_transfer_receive_block(&block(61, 2, b"invalid".to_vec())));
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedFileReceiveBlock {
                abi_version: ABI_VERSION,
                session_epoch: 7,
                transfer_id: 61,
                file_number: 0,
                payload: b"owned".to_vec(),
            }]
        );

        ui.shared.active_file_download_jobs.lock().unwrap().clear();
        assert!(!ui.native_file_transfer_receive_block(&block(61, 0, b"stale".to_vec())));
    }

    #[test]
    fn viewer_digest_hook_confirms_only_exact_manifest_file_sequence() {
        let ui = BridgeUi::default();
        ui.shared.active_file_download_jobs.lock().unwrap().insert(
            61,
            NativeViewerDownloadJob {
                session_epoch: 7,
                manifest_request_id: 51,
                transfer_id: 61,
                total_files: 2,
                total_bytes: 42,
                manifest_files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
                next_digest_file_number: 0,
                sequence: 0,
                files_completed: 0,
                bytes_completed: 0,
            },
        );
        let digest = |id, file_num, size, modified_time| FileTransferDigest {
            id,
            file_num,
            file_size: size,
            last_modified: modified_time,
            ..Default::default()
        };
        let block = |file_num| FileTransferBlock {
            id: 61,
            file_num,
            data: b"owned".to_vec().into(),
            ..Default::default()
        };

        assert!(ui
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .get(&61)
            .unwrap()
            .receive_block(&block(0))
            .is_none());

        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(60, 0, 10, 100)),
            (false, None)
        );
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 1, 32, 200)),
            (true, None),
            "out-of-order digest must be consumed without confirmation"
        );
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 0, 11, 100)),
            (true, None),
            "manifest size drift must fail closed"
        );
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 0, 10, 101)),
            (true, None),
            "manifest mtime drift must fail closed"
        );

        let (consumed, confirmation) =
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 0, 10, 100));
        assert!(consumed);
        let confirmation = confirmation.expect("exact first digest must be confirmed");
        assert_eq!((confirmation.id, confirmation.file_num), (61, 0));
        assert_eq!(
            confirmation.union,
            Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
        );
        {
            let jobs = ui.shared.active_file_download_jobs.lock().unwrap();
            let job = jobs.get(&61).unwrap();
            assert!(job.receive_block(&block(0)).is_some());
            assert!(job.receive_block(&block(1)).is_none());
        }
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 0, 10, 100)),
            (true, None),
            "duplicate digest must fail closed"
        );

        let mut resume = digest(61, 1, 32, 200);
        resume.is_resume = true;
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&resume),
            (true, None)
        );
        resume.is_resume = false;
        resume.transferred_size = 1;
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&resume),
            (true, None)
        );
        resume.transferred_size = 0;
        resume.is_upload = true;
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&resume),
            (true, None)
        );
        resume.is_upload = false;
        resume.is_identical = true;
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&resume),
            (true, None)
        );

        let (consumed, confirmation) =
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 1, 32, 200));
        assert!(consumed);
        assert_eq!(
            confirmation.and_then(|request| request.union),
            Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
        );
        assert!(ui
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .get(&61)
            .unwrap()
            .receive_block(&block(1))
            .is_some());
        ui.shared.active_file_download_jobs.lock().unwrap().clear();
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 1, 32, 200)),
            (false, None)
        );
    }

    #[test]
    fn viewer_download_start_registers_exact_manifest_and_dispatches_bounded_wire_request() {
        let captured = Mutex::new(Vec::<CapturedFileTransferEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_event = Some(capture_file_transfer_event);
        shared.context = &captured as *const _ as usize;
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        *ui.shared.completed_file_manifest_request.lock().unwrap() =
            Some(NativeViewerCompletedManifest {
                session_epoch: 7,
                request_id: 51,
                total_files: 2,
                total_bytes: 42,
                files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
            });

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            server_file_transfer_enabled: Arc::new(RwLock::new(true)),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session)),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let client_pointer = &mut client as *mut RDNClient;
        let mut request = RDNFileTransferDownloadStart {
            abi_version: ABI_VERSION,
            session_epoch: 7,
            manifest_request_id: 51,
            transfer_id: 61,
            total_files: 2,
            total_bytes: 42,
        };

        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            0
        );
        assert_eq!(
            ui.shared
                .active_file_download_jobs
                .lock()
                .unwrap()
                .get(&61)
                .cloned(),
            Some(NativeViewerDownloadJob {
                session_epoch: 7,
                manifest_request_id: 51,
                transfer_id: 61,
                total_files: 2,
                total_bytes: 42,
                manifest_files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
                next_digest_file_number: 0,
                sequence: 0,
                files_completed: 0,
                bytes_completed: 0,
            })
        );
        let Ok(Data::Message(message)) = receiver.try_recv() else {
            panic!("download start must send one wire message");
        };
        let Some(message::Union::FileAction(action)) = message.union else {
            panic!("download start must send FileAction");
        };
        let Some(file_action::Union::Send(send)) = action.union else {
            panic!("download start must send a send-files request");
        };
        assert_eq!(
            (
                send.id,
                send.path.as_str(),
                send.file_num,
                send.include_hidden,
                send.file_type.enum_value(),
            ),
            (
                61,
                "/",
                0,
                false,
                Ok(file_transfer_send_request::FileType::Generic)
            )
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -3
        );

        request.transfer_id = 62;
        request.manifest_request_id = 52;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -3
        );
        request.manifest_request_id = 51;
        request.total_files = 3;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -3
        );
        request.total_files = 2;
        request.session_epoch = 6;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -10
        );
        request.session_epoch = 7;
        request.total_files = (MAX_FILE_TRANSFER_LIST_ENTRIES + 1) as u32;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -4
        );
        request.total_files = 0;
        request.total_bytes = 1;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -4
        );
        assert!(
            receiver.try_recv().is_err(),
            "rejected or duplicate starts must not dispatch another request"
        );

        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 7, 61) },
            0
        );
        assert!(ui
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .is_empty());
        assert!(matches!(receiver.try_recv(), Ok(Data::CancelJob(61))));
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedFileTransferEvent {
                session_epoch: 7,
                transfer_id: 61,
                sequence: 1,
                kind: FILE_TRANSFER_EVENT_CANCELLED,
                failure: FILE_TRANSFER_FAILURE_NONE,
                current_file_number: -1,
                files_completed: 0,
                total_files: 2,
                bytes_completed: 0,
                total_bytes: 42,
                bytes_per_second: 0.0,
            }]
        );
    }

    #[test]
    fn viewer_upload_manifest_revalidates_bounded_files_directories_and_totals() {
        let file_path = b"Folder/file.bin";
        let directory_path = b"Empty/Deep";
        let entries = [
            RDNFileTransferListEntry {
                kind: FILE_TRANSFER_LIST_ENTRY_FILE,
                relative_path_utf8: file_path.as_ptr(),
                relative_path_length: file_path.len(),
                size: 8,
                modified_time: 123,
            },
            RDNFileTransferListEntry {
                kind: FILE_TRANSFER_LIST_ENTRY_DIRECTORY,
                relative_path_utf8: directory_path.as_ptr(),
                relative_path_length: directory_path.len(),
                size: 0,
                modified_time: 0,
            },
        ];
        let mut request = RDNFileTransferUploadStart {
            abi_version: ABI_VERSION,
            session_epoch: 7,
            transfer_id: 71,
            source_token: 81,
            entries: entries.as_ptr(),
            entry_count: entries.len(),
            total_bytes: 8,
        };
        let (files, directories) = unsafe { native_viewer_upload_manifest(&request) }
            .expect("bounded canonical upload manifest");
        assert_eq!(
            files,
            vec![NativeViewerUploadFileAuthority {
                relative_path: "Folder/file.bin".to_owned(),
                size: 8,
                modified_time: 123,
            }]
        );
        assert_eq!(
            directories,
            vec!["Empty".to_owned(), "Empty/Deep".to_owned()]
        );

        request.total_bytes = 7;
        assert!(unsafe { native_viewer_upload_manifest(&request) }.is_none());
        request.total_bytes = 8;
        request.entry_count = 0;
        assert!(unsafe { native_viewer_upload_manifest(&request) }.is_none());

        let ancestor = b"Folder";
        let collision = [
            entries[0],
            RDNFileTransferListEntry {
                kind: FILE_TRANSFER_LIST_ENTRY_DIRECTORY,
                relative_path_utf8: ancestor.as_ptr(),
                relative_path_length: ancestor.len(),
                size: 0,
                modified_time: 0,
            },
        ];
        request.entries = collision.as_ptr();
        request.entry_count = collision.len();
        assert!(unsafe { native_viewer_upload_manifest(&request) }.is_none());
    }

    #[test]
    fn viewer_upload_start_registers_semantic_job_and_reads_exact_callback_range() {
        let capture = Mutex::new(UploadReadCapture {
            source: b"abcdefgh".to_vec(),
            ..Default::default()
        });
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_upload_read = Some(capture_file_upload_read);
        shared.context = &capture as *const _ as usize;
        shared.active.store(true, Ordering::Release);
        shared.file_transfer_enabled.store(true, Ordering::Release);
        shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            server_file_transfer_enabled: Arc::new(RwLock::new(true)),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session)),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let file_path = b"payload.bin";
        let entries = [RDNFileTransferListEntry {
            kind: FILE_TRANSFER_LIST_ENTRY_FILE,
            relative_path_utf8: file_path.as_ptr(),
            relative_path_length: file_path.len(),
            size: 8,
            modified_time: 123,
        }];
        let request = RDNFileTransferUploadStart {
            abi_version: ABI_VERSION,
            session_epoch: 7,
            transfer_id: 71,
            source_token: 81,
            entries: entries.as_ptr(),
            entry_count: entries.len(),
            total_bytes: 8,
        };

        assert_eq!(
            unsafe { rdn_client_file_transfer_upload_start(&mut client, &request) },
            0
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_upload_start(&mut client, &request) },
            -3,
            "duplicate semantic transfer IDs must fail closed"
        );
        let Ok(Data::Message(message)) = receiver.try_recv() else {
            panic!("upload start must send one wire message");
        };
        let Some(message::Union::FileAction(action)) = message.union else {
            panic!("upload start must send FileAction");
        };
        let Some(file_action::Union::Receive(receive)) = action.union else {
            panic!("file upload must declare a receive job");
        };
        assert_eq!(
            (receive.id, receive.path.as_str(), receive.file_num),
            (71, "", 0)
        );
        assert_eq!(receive.files.len(), 1);
        assert_eq!(
            (
                receive.files[0].name.as_str(),
                receive.files[0].size,
                receive.files[0].modified_time,
            ),
            ("payload.bin", 8, 123)
        );
        assert_eq!(
            ui.shared
                .read_file_transfer_upload_source(71, 0, 2, 4)
                .as_deref(),
            Some(&b"cdef"[..])
        );
        assert_eq!(capture.lock().unwrap().requests, vec![(7, 71, 81, 0, 2, 4)]);
        assert!(ui
            .shared
            .read_file_transfer_upload_source(71, 0, 7, 2)
            .is_none());
        capture.lock().unwrap().short_write = true;
        assert!(ui
            .shared
            .read_file_transfer_upload_source(71, 0, 0, 4)
            .is_none());
        capture.lock().unwrap().short_write = false;
        ui.shared
            .file_transfer_session_epoch
            .store(8, Ordering::Release);
        assert!(ui
            .shared
            .read_file_transfer_upload_source(71, 0, 0, 4)
            .is_none());
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);

        let digest_message = ui
            .shared
            .file_transfer_upload_poll()
            .expect("ready upload must emit digest");
        let Some(message::Union::FileResponse(response)) = digest_message.union else {
            panic!("upload poll must emit FileResponse");
        };
        let Some(file_response::Union::Digest(digest)) = response.union else {
            panic!("first upload poll must emit digest");
        };
        assert_eq!(
            (
                digest.id,
                digest.file_num,
                digest.file_size,
                digest.last_modified
            ),
            (71, 0, 8, 123)
        );
        assert_eq!(
            ui.shared
                .file_transfer_upload_confirmation(&FileTransferSendConfirmRequest {
                    id: 71,
                    file_num: 0,
                    union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
                    ..Default::default()
                }),
            (true, Vec::new())
        );
        let block_message = ui
            .shared
            .file_transfer_upload_poll()
            .expect("confirmed upload must emit one bounded block");
        let Some(message::Union::FileResponse(response)) = block_message.union else {
            panic!("upload block must use FileResponse");
        };
        let Some(file_response::Union::Block(block)) = response.union else {
            panic!("confirmed upload must emit block");
        };
        let payload = if block.compressed {
            hbb_common::compress::decompress_with_limit(
                &block.data,
                hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES,
            )
            .unwrap()
        } else {
            block.data.to_vec()
        };
        assert_eq!(
            (block.id, block.file_num, payload.as_slice()),
            (71, 0, &b"abcdefgh"[..])
        );
        assert!(ui.shared.file_transfer_upload_poll().is_none());
        let done_message = ui
            .shared
            .file_transfer_upload_poll()
            .expect("completed payload must emit Done");
        let Some(message::Union::FileResponse(response)) = done_message.union else {
            panic!("upload Done must use FileResponse");
        };
        let Some(file_response::Union::Done(done)) = response.union else {
            panic!("final upload poll must emit Done");
        };
        assert_eq!((done.id, done.file_num), (71, 1));
        assert_eq!(
            ui.shared.file_transfer_upload_done(&done),
            (true, Vec::new())
        );
        assert!(ui.shared.active_file_upload_jobs.lock().unwrap().is_empty());
    }

    #[test]
    fn viewer_upload_confirmation_rejects_resume_and_skips_existing_without_replace() {
        let ui = BridgeUi::default();
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        let upload_job = |transfer_id| NativeViewerUploadJob {
            session_epoch: 7,
            transfer_id,
            source_token: 81,
            files: vec![NativeViewerUploadFileAuthority {
                relative_path: "payload.bin".to_owned(),
                size: 8,
                modified_time: 123,
            }]
            .into(),
            empty_directories: Vec::new().into(),
            total_bytes: 8,
            stage: NativeViewerUploadStage::AwaitingConfirmation { file_number: 0 },
            stage_started: Instant::now(),
            sequence: 0,
            files_completed: 0,
            bytes_completed: 0,
        };
        ui.shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .insert(71, upload_job(71));
        let (consumed, messages) =
            ui.shared
                .file_transfer_upload_confirmation(&FileTransferSendConfirmRequest {
                    id: 71,
                    file_num: 0,
                    union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(1)),
                    ..Default::default()
                });
        assert!(consumed);
        assert_eq!(messages.len(), 1);
        assert!(matches!(
            messages[0].union.as_ref(),
            Some(message::Union::FileAction(FileAction {
                union: Some(file_action::Union::Cancel(FileTransferCancel {
                    id: 71,
                    ..
                })),
                ..
            }))
        ));
        assert!(!ui
            .shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .contains_key(&71));

        ui.shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .insert(72, upload_job(72));
        let (consumed, messages) =
            ui.shared
                .file_transfer_upload_existing_target(&FileTransferDigest {
                    id: 72,
                    file_num: 0,
                    is_upload: true,
                    ..Default::default()
                });
        assert!(consumed);
        assert_eq!(messages.len(), 1);
        let Some(message::Union::FileAction(action)) = messages[0].union.as_ref() else {
            panic!("existing target must emit FileAction");
        };
        let Some(file_action::Union::SendConfirm(confirm)) = action.union.as_ref() else {
            panic!("existing target must emit SendConfirm");
        };
        assert_eq!(
            confirm.union,
            Some(file_transfer_send_confirm_request::Union::Skip(true))
        );
        assert!(matches!(
            ui.shared
                .active_file_upload_jobs
                .lock()
                .unwrap()
                .get(&72)
                .map(|job| job.stage),
            Some(NativeViewerUploadStage::ReadyDone)
        ));
    }

    #[test]
    fn viewer_upload_empty_directories_wait_for_each_exact_done() {
        let ui = BridgeUi::default();
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        ui.shared.active_file_upload_jobs.lock().unwrap().insert(
            73,
            NativeViewerUploadJob {
                session_epoch: 7,
                transfer_id: 73,
                source_token: 81,
                files: Vec::new().into(),
                empty_directories: vec!["a".to_owned(), "a/b".to_owned()].into(),
                total_bytes: 0,
                stage: NativeViewerUploadStage::AwaitingCreate {
                    directory_number: 0,
                },
                stage_started: Instant::now(),
                sequence: 0,
                files_completed: 0,
                bytes_completed: 0,
            },
        );
        let (consumed, messages) = ui.shared.file_transfer_upload_done(&FileTransferDone {
            id: 73,
            file_num: 0,
            ..Default::default()
        });
        assert!(consumed);
        assert_eq!(messages.len(), 1);
        let Some(message::Union::FileAction(action)) = messages[0].union.as_ref() else {
            panic!("next empty directory must use FileAction");
        };
        let Some(file_action::Union::Create(create)) = action.union.as_ref() else {
            panic!("next empty directory must use Create");
        };
        assert_eq!(create.path, "a/b");
        assert_eq!(
            ui.shared.file_transfer_upload_done(&FileTransferDone {
                id: 73,
                file_num: 0,
                ..Default::default()
            }),
            (true, Vec::new())
        );
        assert!(ui.shared.active_file_upload_jobs.lock().unwrap().is_empty());
    }

    #[test]
    fn viewer_download_start_rolls_back_registration_when_wire_queue_is_closed() {
        let ui = BridgeUi::default();
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        *ui.shared.completed_file_manifest_request.lock().unwrap() =
            Some(NativeViewerCompletedManifest {
                session_epoch: 7,
                request_id: 51,
                total_files: 2,
                total_bytes: 42,
                files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
            });

        let (sender, receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        drop(receiver);
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            server_file_transfer_enabled: Arc::new(RwLock::new(true)),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session)),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let request = RDNFileTransferDownloadStart {
            abi_version: ABI_VERSION,
            session_epoch: 7,
            manifest_request_id: 51,
            transfer_id: 61,
            total_files: 2,
            total_bytes: 42,
        };

        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(&mut client, &request) },
            -3
        );
        assert!(ui
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn viewer_download_progress_and_terminal_callbacks_are_monotonic_and_stable() {
        let captured = Mutex::new(Vec::<CapturedFileTransferEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_event = Some(capture_file_transfer_event);
        shared.context = &captured as *const _ as usize;
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        let job = NativeViewerDownloadJob {
            session_epoch: 7,
            manifest_request_id: 51,
            transfer_id: 61,
            total_files: 2,
            total_bytes: 42,
            manifest_files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
            next_digest_file_number: 2,
            sequence: 0,
            files_completed: 0,
            bytes_completed: 0,
        };
        ui.shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .insert(61, job.clone());

        ui.job_progress(61, -1, 7.5, 10.0);
        ui.job_progress(61, -1, 7.5, 9.0);
        ui.job_progress(61, 0, 8.0, 40.0);
        ui.job_done(61, 1);
        ui.job_progress(61, 1, 1.0, 42.0);
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[
                CapturedFileTransferEvent {
                    session_epoch: 7,
                    transfer_id: 61,
                    sequence: 1,
                    kind: FILE_TRANSFER_EVENT_PROGRESS,
                    failure: FILE_TRANSFER_FAILURE_NONE,
                    current_file_number: 0,
                    files_completed: 0,
                    total_files: 2,
                    bytes_completed: 10,
                    total_bytes: 42,
                    bytes_per_second: 7.5,
                },
                CapturedFileTransferEvent {
                    session_epoch: 7,
                    transfer_id: 61,
                    sequence: 2,
                    kind: FILE_TRANSFER_EVENT_PROGRESS,
                    failure: FILE_TRANSFER_FAILURE_NONE,
                    current_file_number: 1,
                    files_completed: 1,
                    total_files: 2,
                    bytes_completed: 40,
                    total_bytes: 42,
                    bytes_per_second: 8.0,
                },
                CapturedFileTransferEvent {
                    session_epoch: 7,
                    transfer_id: 61,
                    sequence: 3,
                    kind: FILE_TRANSFER_EVENT_COMPLETED,
                    failure: FILE_TRANSFER_FAILURE_NONE,
                    current_file_number: -1,
                    files_completed: 2,
                    total_files: 2,
                    bytes_completed: 42,
                    total_bytes: 42,
                    bytes_per_second: 0.0,
                },
            ]
        );

        ui.shared.active_file_download_jobs.lock().unwrap().insert(
            62,
            NativeViewerDownloadJob {
                transfer_id: 62,
                ..job.clone()
            },
        );
        ui.job_error(62, "raw remote detail".to_owned(), 0);
        assert_eq!(
            captured.lock().unwrap().last().copied(),
            Some(CapturedFileTransferEvent {
                session_epoch: 7,
                transfer_id: 62,
                sequence: 1,
                kind: FILE_TRANSFER_EVENT_FAILED,
                failure: FILE_TRANSFER_FAILURE_UNAVAILABLE,
                current_file_number: -1,
                files_completed: 0,
                total_files: 2,
                bytes_completed: 0,
                total_bytes: 42,
                bytes_per_second: 0.0,
            })
        );

        let mut precision_boundary_job = NativeViewerDownloadJob {
            transfer_id: 63,
            total_bytes: 9_007_199_254_740_995,
            ..job
        };
        assert_eq!(
            precision_boundary_job.progress(-1, 1.0, precision_boundary_job.total_bytes as f64,),
            None
        );
        assert_eq!(precision_boundary_job.sequence, 0);
        assert_eq!(precision_boundary_job.bytes_completed, 0);
    }

    fn optional_payload_bytes(bytes: Option<&[u8]>) -> (*const u8, usize) {
        bytes.map_or((ptr::null(), 0), |bytes| (bytes.as_ptr(), bytes.len()))
    }

    fn rich_payload(
        plain: Option<&[u8]>,
        rtf: Option<&[u8]>,
        html: Option<&[u8]>,
    ) -> RDNClipboardRichTextPayload {
        let (plain_utf8, plain_length) = optional_payload_bytes(plain);
        let (rtf_utf8, rtf_length) = optional_payload_bytes(rtf);
        let (html_utf8, html_length) = optional_payload_bytes(html);
        RDNClipboardRichTextPayload {
            abi_version: ABI_VERSION,
            plain_utf8,
            plain_length,
            rtf_utf8,
            rtf_length,
            html_utf8,
            html_length,
        }
    }

    #[test]
    fn native_viewer_rich_clipboard_builds_canonical_outbound_messages() {
        let rtf = b"{\\rtf1 outbound}";
        let payload = rich_payload(None, Some(rtf), None);
        let message = unsafe { native_viewer_clipboard_rich_text_message(&payload) }
            .expect("single rich payload");
        let Some(message::Union::Clipboard(clipboard)) = message.union else {
            panic!("one rich entry must use Clipboard");
        };
        assert_eq!(clipboard.format.enum_value(), Ok(ClipboardFormat::Rtf));
        assert_eq!(clipboard.content.as_ref(), rtf);
        assert!(!clipboard.compress);
        assert!(clipboard.special_name.is_empty());
        assert_eq!((clipboard.width, clipboard.height), (0, 0));

        let plain = "回退文本".as_bytes();
        let html = b"<b>outbound</b>";
        let payload = rich_payload(Some(plain), Some(rtf), Some(html));
        let message = unsafe { native_viewer_clipboard_rich_text_message(&payload) }
            .expect("multi rich payload");
        let Some(message::Union::MultiClipboards(multi)) = message.union else {
            panic!("multiple rich entries must use MultiClipboards");
        };
        assert_eq!(multi.clipboards.len(), 3);
        for (clipboard, expected_format, expected_content) in [
            (&multi.clipboards[0], ClipboardFormat::Text, plain),
            (&multi.clipboards[1], ClipboardFormat::Rtf, rtf.as_slice()),
            (&multi.clipboards[2], ClipboardFormat::Html, html.as_slice()),
        ] {
            assert_eq!(clipboard.format.enum_value(), Ok(expected_format));
            assert_eq!(clipboard.content.as_ref(), expected_content);
            assert!(!clipboard.compress);
            assert!(clipboard.special_name.is_empty());
            assert_eq!((clipboard.width, clipboard.height), (0, 0));
        }
    }

    #[test]
    fn native_viewer_rich_clipboard_rejects_invalid_outbound_payloads() {
        let plain = b"plain";
        let rtf = b"{\\rtf1}";
        let mut payload = rich_payload(Some(plain), None, None);
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        payload = rich_payload(None, Some(rtf), None);
        payload.abi_version += 1;
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        payload = rich_payload(None, Some(rtf), None);
        payload.rtf_utf8 = ptr::null();
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        payload = rich_payload(None, Some(rtf), None);
        payload.rtf_length = 0;
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        payload = rich_payload(None, Some(rtf), None);
        payload.rtf_length = MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES + 1;
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        for invalid in [&[0xff][..], &b"before\0after"[..]] {
            payload = rich_payload(None, None, Some(invalid));
            assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());
        }
    }
}
