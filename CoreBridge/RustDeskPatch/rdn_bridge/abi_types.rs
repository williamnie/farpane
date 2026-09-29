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
