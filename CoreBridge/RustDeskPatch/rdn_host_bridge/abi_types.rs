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
    enable_clipboard_rich_text_read: bool,
    enable_clipboard_rich_text_write: bool,
    enable_clipboard_image_read: bool,
    enable_clipboard_image_write: bool,
    enable_audio: bool,
    audio_input_device: *const c_char,
    enable_file_transfer: bool,
    file_transfer_receive_root: *const c_char,
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
