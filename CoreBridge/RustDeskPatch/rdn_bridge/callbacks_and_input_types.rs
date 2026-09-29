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
