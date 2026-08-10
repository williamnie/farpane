// RustDesk Native Viewer bridge.
//
// This file is compiled inside RustDesk 1.4.9 at commit
// 6c578292e8ebbbec708b76986ba8c4bc7c509747. The surrounding RustDesk-derived
// build is AGPL-3.0; see CoreBridge/README.md and the repository root LICENSE.

use crate::client::{Data, QualityStatus};
use crate::common::input::{
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_WHEEL, MOUSE_TYPE_DOWN, MOUSE_TYPE_MOVE,
    MOUSE_TYPE_TRACKPAD, MOUSE_TYPE_UP, MOUSE_TYPE_WHEEL,
};
use crate::ui_session_interface::{io_loop, InvokeUiSession, Session};
use hbb_common::{message_proto::*, rendezvous_proto::ConnType};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    ptr,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, RwLock,
    },
    thread::JoinHandle,
    time::Duration,
};

const ABI_VERSION: u32 = 7;
const MAX_TEXT_BYTES: usize = 4_096;
const MAX_CLIPBOARD_TEXT_UTF8_BYTES: usize = 64 * 1024;
const MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES: usize = 1024 * 1024;
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
}

#[repr(C)]
pub struct RDNCoreMetrics {
    abi_version: u32,
    remote_fps: f64,
    network_delay_ms: i32,
    target_bitrate: u64,
}

type StateCallback = unsafe extern "C" fn(*mut c_void, RDNState, i32, *const c_char);
type VideoCallback = unsafe extern "C" fn(*mut c_void, *const RDNEncodedVideoFrame);
type MetricsCallback = unsafe extern "C" fn(*mut c_void, *const RDNCoreMetrics);
type ClipboardTextCallback = unsafe extern "C" fn(*mut c_void, *const u8, usize);
type ClipboardRichTextCallback =
    unsafe extern "C" fn(*mut c_void, *const RDNClipboardRichTextPayload);

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
#[derive(Clone, Copy)]
pub struct RDNCallbacks {
    abi_version: u32,
    on_state: Option<StateCallback>,
    on_video: Option<VideoCallback>,
    on_metrics: Option<MetricsCallback>,
    on_clipboard_text: Option<ClipboardTextCallback>,
    on_clipboard_rich_text: Option<ClipboardRichTextCallback>,
}

#[repr(C)]
pub struct RDNConnectionConfig {
    abi_version: u32,
    rendezvous_server: *const c_char,
    server_public_key: *const c_char,
    peer_id: *const c_char,
    password: *const c_char,
    force_relay: bool,
    receive_clipboard_text: bool,
    send_clipboard_text: bool,
    receive_clipboard_rich_text: bool,
    send_clipboard_rich_text: bool,
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

struct BridgeShared {
    callbacks: RDNCallbacks,
    context: usize,
    active: AtomicBool,
    sequence: AtomicU64,
    dimensions: RwLock<(u32, u32)>,
    authenticated: AtomicBool,
    remote_keyboard_enabled: AtomicBool,
    input_allowed: AtomicBool,
    receive_clipboard_text: AtomicBool,
    send_clipboard_text: AtomicBool,
    receive_clipboard_rich_text: AtomicBool,
    send_clipboard_rich_text: AtomicBool,
    remote_clipboard_enabled: AtomicBool,
}

impl BridgeShared {
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
                display: frame.display.max(0) as u32,
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
                    on_video: None,
                    on_metrics: None,
                    on_clipboard_text: None,
                    on_clipboard_rich_text: None,
                },
                context: 0,
                active: AtomicBool::new(false),
                sequence: AtomicU64::new(0),
                dimensions: RwLock::new((0, 0)),
                authenticated: AtomicBool::new(false),
                remote_keyboard_enabled: AtomicBool::new(true),
                input_allowed: AtomicBool::new(false),
                receive_clipboard_text: AtomicBool::new(false),
                send_clipboard_text: AtomicBool::new(false),
                receive_clipboard_rich_text: AtomicBool::new(false),
                send_clipboard_rich_text: AtomicBool::new(false),
                remote_clipboard_enabled: AtomicBool::new(false),
            }),
        }
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
    }

    fn set_peer_info(&self, _peer_info: &PeerInfo) {}
    fn set_displays(&self, _displays: &Vec<DisplayInfo>) {}
    fn set_platform_additions(&self, _data: &str) {}

    fn on_connected(&self, _conn_type: ConnType) {
        self.shared.authenticated.store(true, Ordering::Release);
        let allowed = input_is_allowed(
            true,
            self.shared.remote_keyboard_enabled.load(Ordering::Acquire),
        );
        self.shared.input_allowed.store(allowed, Ordering::Release);
        self.shared
            .emit_state(RDNState::Authenticated, 0, "authenticated");
        if allowed {
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
            let allowed =
                input_is_allowed(self.shared.authenticated.load(Ordering::Acquire), value);
            self.shared.input_allowed.store(allowed, Ordering::Release);
            if allowed {
                self.shared
                    .emit_state(RDNState::ControlReady, 0, "control-ready");
            }
        } else if name == "clipboard" {
            self.shared
                .remote_clipboard_enabled
                .store(value, Ordering::Release);
        }
    }

    fn close_success(&self) {
        self.shared.emit_state(RDNState::Streaming, 0, "streaming");
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
    fn job_error(&self, _id: i32, _error: String, _file_num: i32) {}
    fn job_done(&self, _id: i32, _file_num: i32) {}
    fn clear_all_jobs(&self) {}
    fn new_message(&self, _message: String) {}
    fn update_transfer_list(&self) {}
    fn load_last_job(&self, _count: i32, _json: &str, _auto_start: bool) {}

    fn update_folder_files(
        &self,
        _id: i32,
        _entries: &Vec<FileEntry>,
        _path: String,
        _is_local: bool,
        _only_count: bool,
    ) {
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
    fn job_progress(&self, _id: i32, _file_num: i32, _speed: f64, _finished_size: f64) {}
    fn adapt_size(&self) {}
    fn on_rgba(&self, _display: usize, _rgba: &mut scrap::ImageRgb) {}

    fn msgbox(&self, message_type: &str, _title: &str, text: &str, _link: &str, _retry: bool) {
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
                let lower = text.to_ascii_lowercase();
                let (code, message) = if lower == "timeout" {
                    (10, "connection-timeout")
                } else if lower.contains("reset by the peer") || lower.contains("connection reset")
                {
                    (11, "connection-reset")
                } else if lower.contains("deadline") {
                    (12, "connection-deadline")
                } else if lower.contains("broken pipe") {
                    (13, "connection-broken-pipe")
                } else if lower.contains("closed") || lower.contains("eof") {
                    (14, "connection-closed")
                } else {
                    (3, "rustdesk-session-error")
                };
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
    fn set_current_display(&self, _display: i32) {}
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
}

pub struct RDNClient {
    shared: Arc<BridgeShared>,
    session: Mutex<Option<Session<BridgeUi>>>,
    worker: Mutex<Option<JoinHandle<()>>>,
    housekeeping: Mutex<Option<JoinHandle<()>>>,
}

impl RDNClient {
    fn disconnect(&self, emit_state: bool) {
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
            .remote_clipboard_enabled
            .store(false, Ordering::Release);
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
        sequence: AtomicU64::new(0),
        dimensions: RwLock::new((0, 0)),
        authenticated: AtomicBool::new(false),
        remote_keyboard_enabled: AtomicBool::new(true),
        input_allowed: AtomicBool::new(false),
        receive_clipboard_text: AtomicBool::new(false),
        send_clipboard_text: AtomicBool::new(false),
        receive_clipboard_rich_text: AtomicBool::new(false),
        send_clipboard_rich_text: AtomicBool::new(false),
        remote_clipboard_enabled: AtomicBool::new(false),
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

    client.shared.active.store(true, Ordering::Release);
    client.shared.authenticated.store(false, Ordering::Release);
    client
        .shared
        .remote_keyboard_enabled
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
        .remote_clipboard_enabled
        .store(false, Ordering::Release);
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
        ConnType::DEFAULT_CONN,
        None,
        (*config).force_relay,
        None,
        None,
        None,
    );
    session.lc.write().unwrap().configure_native_viewer(
        &peer_id,
        (*config).receive_clipboard_text
            || (*config).send_clipboard_text
            || (*config).receive_clipboard_rich_text
            || (*config).send_clipboard_rich_text,
    );
    let round = session.connection_round_state.lock().unwrap().new_round();
    let worker_session = session.clone();
    let worker_shared = client.shared.clone();
    let worker = std::thread::spawn(move || {
        io_loop(worker_session, round);
        worker_shared.authenticated.store(false, Ordering::Release);
        worker_shared.input_allowed.store(false, Ordering::Release);
        worker_shared.emit_state(RDNState::Disconnected, 0, "disconnected");
    });
    let housekeeping_session = session.clone();
    let housekeeping_shared = client.shared.clone();
    let custom_fps = native_stream_fps((*config).force_relay);
    let housekeeping = std::thread::spawn(move || {
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
    });
    *client.session.lock().unwrap() = Some(session);
    *client.worker.lock().unwrap() = Some(worker);
    *client.housekeeping.lock().unwrap() = Some(housekeeping);
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_disconnect(client: *mut RDNClient) {
    if let Some(client) = client.as_ref() {
        client.disconnect(true);
    }
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
