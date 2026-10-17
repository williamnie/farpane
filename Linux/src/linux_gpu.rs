use crate::{codec::{EncoderApi, EncoderCfg, ENCODE_NEED_SWITCH}, EncodeInput, EncodeYuvFormat, Pixfmt};
use base::message_proto::{EncodedVideoFrame, EncodedVideoFrames, VideoFrame};
use hbb_common::{anyhow::anyhow, bail, bytes::Bytes, log, ResultType};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    os::fd::{AsRawFd, OwnedFd},
    sync::{atomic::{AtomicBool, AtomicU32, Ordering}, mpsc, Arc, Mutex},
    time::{Duration, Instant},
};

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Descriptor {
    pub fd: i32,
    pub width: u32,
    pub height: u32,
    pub fourcc: u32,
    pub pitch: u32,
    pub offset: u32,
    pub size: u64,
    pub modifier: u64,
}

pub const IMPLICIT_MODIFIER: u64 = 0x00ff_ffff_ffff_ffff;

extern "C" {
    fn fp_gpu_create(node: *const c_char, w: u32, h: u32, fourcc: u32, kbps: u32,
        fps: u32, gop: u32, error: *mut c_char, capacity: usize) -> *mut c_void;
    fn fp_gpu_validate(frame: *const Descriptor) -> i32;
    fn fp_gpu_convert(ctx: *mut c_void, frame: *const Descriptor, pts: i64) -> i32;
    fn fp_gpu_source_done(ctx: *mut c_void, timeout_ms: u32) -> i32;
    fn fp_gpu_encode(ctx: *mut c_void, callback: extern "C" fn(*mut c_void, *const u8, usize, i64, i32) -> i32,
        opaque: *mut c_void) -> i32;
    fn fp_gpu_error(ctx: *const c_void) -> *const c_char;
    fn fp_gpu_destroy(ctx: *mut c_void) -> i32;
    fn fp_gpu_read_rgba(frame: *const Descriptor, rgba: *mut u8, length: usize) -> i32;
}

struct Lease {
    source: Mutex<Option<OwnedFd>>,
    claimed: AtomicBool,
    descriptor: Descriptor,
    acknowledge: Box<dyn Fn() + Send + Sync>,
}

static LIVE_SOURCES: AtomicU32 = AtomicU32::new(0);

/// Includes sources and retiring driver work after the network session ends.
/// A false value is only one part of the supervisor's complete idle snapshot.
pub fn has_live_resources() -> bool {
    LIVE_SOURCES.load(Ordering::Acquire) != 0 || MEDIA_BUSY.load(Ordering::Acquire)
}

impl Lease {
    fn complete(&self) {
        let fd = self.source.lock().unwrap().take();
        if let Some(fd) = fd {
            drop(fd);
            (self.acknowledge)();
            LIVE_SOURCES.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.complete();
    }
}

#[derive(Clone)]
pub struct LinuxGpuFrame {
    lease: Arc<Lease>,
    pub generation: u64,
}

impl LinuxGpuFrame {
    pub fn new(fd: OwnedFd, mut descriptor: Descriptor, generation: u64,
        acknowledge: impl Fn() + Send + Sync + 'static) -> ResultType<Self> {
        descriptor.fd = fd.as_raw_fd();
        if unsafe { fp_gpu_validate(&descriptor) } != 1 {
            bail!("invalid Linux GPU descriptor");
        }
        LIVE_SOURCES.fetch_add(1, Ordering::AcqRel);
        Ok(Self { lease: Arc::new(Lease {
            source: Mutex::new(Some(fd)), claimed: AtomicBool::new(false), descriptor,
            acknowledge: Box::new(acknowledge),
        }), generation })
    }

    pub fn valid(&self) -> bool {
        self.lease.source.lock().unwrap().is_some()
    }

    pub fn descriptor(&self) -> ResultType<Descriptor> {
        if !self.valid() { bail!("source lease already completed"); }
        Ok(self.lease.descriptor)
    }

    /// Explicit screenshot request only. Normal encode never maps CPU pixels.
    pub fn rgba(&self) -> ResultType<(usize, usize, Vec<u8>)> {
        let guard = self.lease.source.lock().unwrap();
        if guard.is_none() { bail!("screenshot source lease already completed"); }
        let descriptor = self.lease.descriptor;
        let mut pixels = vec![0; descriptor.width as usize * descriptor.height as usize * 4];
        if descriptor.modifier == IMPLICIT_MODIFIER {
            // KMS may omit an explicit modifier even on a tiled AMD scanout.
            // Reuse the established driver detile only for this cold consumer.
            let mut converter = crate::drm_render::RenderConverter::open_render(Some("/dev/dri/renderD128"))
                .ok_or_else(|| anyhow!("screenshot render context unavailable"))?;
            let mut desc = crate::drmtap_dl::drmtap_dmabuf_desc {
                width: descriptor.width, height: descriptor.height, format: descriptor.fourcc,
                modifier: descriptor.modifier, num_planes: 1,
                pitches: [descriptor.pitch, 0, 0, 0], offsets: [descriptor.offset, 0, 0, 0],
                ..Default::default()
            };
            let (source, width, height, format) = converter.convert(&mut desc, descriptor.fd)?;
            if width != descriptor.width || height != descriptor.height ||
                !matches!(format, Pixfmt::RGBA | Pixfmt::BGRA) {
                bail!("unexpected GPU screenshot geometry or format");
            }
            let stride = source.len() / height as usize;
            for (input, output) in source.chunks_exact(stride).zip(pixels.chunks_exact_mut(width as usize * 4)) {
                for (input, output) in input.chunks_exact(4).zip(output.chunks_exact_mut(4)) {
                    let (r, b) = if format == Pixfmt::RGBA { (0, 2) } else { (2, 0) };
                    output.copy_from_slice(&[input[r], input[1], input[b], 255]);
                }
            }
            return Ok((width as usize, height as usize, pixels));
        }
        if unsafe { fp_gpu_read_rgba(&descriptor, pixels.as_mut_ptr(), pixels.len()) } != 0 {
            bail!("Linux GPU screenshot readback failed");
        }
        Ok((descriptor.width as usize, descriptor.height as usize, pixels))
    }
}

pub type Failure = Arc<Mutex<Option<String>>>;

#[derive(Clone, Debug)]
pub struct LinuxGpuEncoderConfig {
    pub render_node: String,
    pub width: u32,
    pub height: u32,
    pub fourcc: u32,
    pub kbps: u32,
    pub fps: u32,
    pub gop: u32,
    pub generation: u64,
    pub failure: Failure,
}

// One hardware context owner per process. A driver call that never returns retains
// this permit, its bounded surfaces and source lease; further sessions use CPU.
static MEDIA_BUSY: AtomicBool = AtomicBool::new(false);
struct MediaPermit;
impl MediaPermit {
    fn acquire() -> ResultType<Self> {
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if MEDIA_BUSY.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_ok() {
                return Ok(Self);
            }
            if Instant::now() >= deadline { bail!("previous GPU context is still draining"); }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
impl Drop for MediaPermit {
    fn drop(&mut self) { MEDIA_BUSY.store(false, Ordering::Release); }
}

struct EncodeCommand {
    frame: LinuxGpuFrame,
    pts: i64,
    response: mpsc::SyncSender<Result<VideoFrame, String>>,
}

pub struct LinuxGpuEncoder {
    sender: mpsc::SyncSender<EncodeCommand>,
    config: LinuxGpuEncoderConfig,
}

impl LinuxGpuEncoder {
    fn fail(&self, reason: String) {
        let mut failure = self.config.failure.lock().unwrap();
        if failure.is_none() {
            log::warn!("Linux GPU media disabled for generation {}: {}", self.config.generation, reason);
            *failure = Some(reason);
        }
    }
}

extern "C" fn packet_callback(opaque: *mut c_void, data: *const u8, size: usize, pts: i64, key: i32) -> i32 {
    if opaque.is_null() || data.is_null() || size == 0 || size > 16 * 1024 * 1024 { return -1; }
    // The synchronous native callback borrows only this media thread's packet vector.
    let packets = unsafe { &mut *(opaque as *mut Vec<EncodedVideoFrame>) };
    if packets.len() >= 4 { return -1; }
    packets.push(EncodedVideoFrame {
        data: Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(data, size) }),
        pts, key: key != 0, ..Default::default()
    });
    0
}

fn native_error(context: *const c_void) -> String {
    unsafe { CStr::from_ptr(fp_gpu_error(context)) }.to_string_lossy().into_owned()
}

fn media_thread(config: LinuxGpuEncoderConfig, receiver: mpsc::Receiver<EncodeCommand>,
    ready: mpsc::SyncSender<Result<(), String>>, _permit: MediaPermit) {
    let node = match CString::new(config.render_node.as_str()) {
        Ok(node) => node,
        Err(error) => { let _ = ready.send(Err(error.to_string())); return; }
    };
    let mut error = [0 as c_char; 512];
    let context = unsafe { fp_gpu_create(node.as_ptr(), config.width, config.height, config.fourcc,
        config.kbps, config.fps, config.gop, error.as_mut_ptr(), error.len()) };
    if context.is_null() {
        let message = unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy().into_owned();
        let _ = ready.send(Err(message));
        return;
    }
    let mut pending: Option<LinuxGpuFrame> = None;
    if ready.send(Ok(())).is_ok() {
        while let Ok(command) = receiver.recv() {
            let descriptor = match command.frame.descriptor() {
                Ok(descriptor) if command.frame.generation == config.generation => descriptor,
                _ => {
                    let _ = command.response.send(Err("stale or completed GPU frame".into()));
                    break;
                }
            };
            pending = Some(command.frame);
            if unsafe { fp_gpu_convert(context, &descriptor, command.pts) } != 0 {
                let _ = command.response.send(Err(native_error(context)));
                break;
            }
            // VPP completion was checked before this ACK and before encoder submission.
            if let Some(frame) = pending.take() { frame.lease.complete(); }
            let mut packets: Vec<EncodedVideoFrame> = Vec::new();
            if unsafe { fp_gpu_encode(context, packet_callback, &mut packets as *mut _ as *mut c_void) } != 0 {
                let _ = command.response.send(Err(native_error(context)));
                break;
            }
            let mut frame = VideoFrame::new();
            frame.set_h264s(EncodedVideoFrames { frames: packets.into(), ..Default::default() });
            if command.response.send(Ok(frame)).is_err() { break; }
        }
    }
    drop(receiver);
    // A timed-out caller can fall back while this sole owner retains its source.
    // No cross-thread context destruction, forced thread termination or early ACK.
    while unsafe { fp_gpu_source_done(context, 100) } != 1 {
        std::thread::sleep(Duration::from_millis(100));
    }
    if let Some(frame) = pending.take() { frame.lease.complete(); }
    while unsafe { fp_gpu_destroy(context) } != 1 {
        std::thread::sleep(Duration::from_millis(100));
    }
}

impl EncoderApi for LinuxGpuEncoder {
    fn new(config: EncoderCfg, i444: bool) -> ResultType<Self> {
        let EncoderCfg::LinuxGpu(config) = config else { bail!("Linux GPU encoder config mismatch"); };
        if i444 { bail!("Linux GPU supports NV12 only"); }
        let permit = MediaPermit::acquire()?;
        let (sender, receiver) = mpsc::sync_channel(1);
        let (ready, wait) = mpsc::sync_channel(1);
        let worker_config = config.clone();
        std::thread::Builder::new().name("farpane-media".into())
            .spawn(move || media_thread(worker_config, receiver, ready, permit))?;
        let encoder = Self { sender, config };
        match wait.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(())) => Ok(encoder),
            result => {
                let reason = match result {
                    Ok(Err(reason)) => reason,
                    Err(error) => format!("GPU initialization deadline/channel: {error}"),
                    Ok(Ok(())) => unreachable!(),
                };
                encoder.fail(reason.clone());
                Err(anyhow!(reason))
            }
        }
    }

    fn encode_to_message(&mut self, input: EncodeInput, pts: i64) -> ResultType<VideoFrame> {
        let EncodeInput::LinuxGpu(frame) = input else { bail!("GPU encoder received CPU input"); };
        if frame.lease.claimed.swap(true, Ordering::AcqRel) {
            self.fail("source lease submitted more than once".into());
            bail!(ENCODE_NEED_SWITCH);
        }
        let (response, result) = mpsc::sync_channel(1);
        let command = EncodeCommand { frame, pts, response };
        if let Err(error) = self.sender.try_send(command) {
            self.fail(format!("media command queue: {error}"));
            bail!(ENCODE_NEED_SWITCH);
        }
        match result.recv_timeout(Duration::from_millis(500)) {
            Ok(Ok(frame)) => Ok(frame),
            result => {
                let reason = match result {
                    Ok(Err(reason)) => reason,
                    Err(error) => format!("GPU frame deadline/channel: {error}"),
                    Ok(Ok(_)) => unreachable!(),
                };
                self.fail(reason);
                bail!(ENCODE_NEED_SWITCH)
            }
        }
    }

    fn yuvfmt(&self) -> EncodeYuvFormat {
        EncodeYuvFormat { pixfmt: Pixfmt::NV12, w: self.config.width as _, h: self.config.height as _,
            stride: Vec::new(), u: 0, v: 0 }
    }
    #[cfg(feature = "vram")]
    fn input_texture(&self) -> bool { false }
    fn set_quality(&mut self, _ratio: f32) -> ResultType<()> { bail!(ENCODE_NEED_SWITCH) }
    fn bitrate(&self) -> u32 { self.config.kbps }
    fn support_changing_quality(&self) -> bool { false }
    fn latency_free(&self) -> bool { true }
    fn is_hardware(&self) -> bool { true }
    fn disable(&self) { self.fail("encoder requested CPU fallback".into()); }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs::OpenOptions, sync::atomic::AtomicUsize};

    #[test]
    #[ignore = "requires isolated renderD128 and bundled libdrmtap; no desktop"]
    fn implicit_tiled_screenshot_uses_driver_detile() {
        use std::os::fd::FromRawFd;
        #[link(name = "gbm")]
        extern "C" {
            fn gbm_create_device(fd: i32) -> *mut c_void;
            fn gbm_device_destroy(device: *mut c_void);
            fn gbm_bo_create(device: *mut c_void, w: u32, h: u32, format: u32, flags: u32) -> *mut c_void;
            fn gbm_bo_destroy(bo: *mut c_void);
            fn gbm_bo_get_fd(bo: *mut c_void) -> i32;
            fn gbm_bo_get_stride(bo: *mut c_void) -> u32;
            fn gbm_bo_get_modifier(bo: *mut c_void) -> u64;
            fn gbm_bo_map(bo: *mut c_void, x: u32, y: u32, w: u32, h: u32, flags: u32,
                stride: *mut u32, token: *mut *mut c_void) -> *mut c_void;
            fn gbm_bo_unmap(bo: *mut c_void, token: *mut c_void);
        }
        let render = OpenOptions::new().read(true).write(true).open("/dev/dri/renderD128").unwrap();
        unsafe {
            let device = gbm_create_device(render.as_raw_fd());
            assert!(!device.is_null());
            let format = u32::from_le_bytes(*b"XR24");
            let bo = gbm_bo_create(device, 256, 128, format, 1 | 4); // SCANOUT | RENDERING
            assert!(!bo.is_null());
            assert_ne!(gbm_bo_get_modifier(bo), 0);
            let mut stride = 0;
            let mut token = std::ptr::null_mut();
            let mapped = gbm_bo_map(bo, 0, 0, 256, 128, 2, &mut stride, &mut token);
            assert!(!mapped.is_null());
            for y in 0..128usize { for x in 0..256usize {
                std::ptr::copy_nonoverlapping([x as u8, y as u8, 37, 255].as_ptr(),
                    mapped.cast::<u8>().add(y * stride as usize + x * 4), 4);
            }}
            gbm_bo_unmap(bo, token);
            let fd = gbm_bo_get_fd(bo);
            assert!(fd >= 0);
            let size = hbb_common::libc::lseek(fd, 0, hbb_common::libc::SEEK_END);
            assert!(size > 0);
            let frame = LinuxGpuFrame::new(OwnedFd::from_raw_fd(fd), Descriptor {
                fd, width: 256, height: 128, fourcc: format, pitch: gbm_bo_get_stride(bo),
                offset: 0, size: size as u64, modifier: IMPLICIT_MODIFIER,
            }, 1, || {}).unwrap();
            let (w, h, rgba) = frame.rgba().unwrap();
            assert_eq!((w, h), (256, 128));
            for y in 0..h { for x in 0..w {
                assert_eq!(&rgba[(y * w + x) * 4..(y * w + x + 1) * 4], &[37, y as u8, x as u8, 255]);
            }}
            drop(frame);
            gbm_bo_destroy(bo);
            gbm_device_destroy(device);
        }
    }

    #[test]
    fn source_credit_is_returned_once_after_last_owner_or_explicit_completion() {
        for complete in [false, true] {
            let baseline = LIVE_SOURCES.load(Ordering::Acquire);
            let path = std::env::temp_dir().join(format!("farpane-lease-{}-{complete}", std::process::id()));
            let file = OpenOptions::new().read(true).write(true).create_new(true).open(&path).unwrap();
            std::fs::remove_file(path).unwrap();
            file.set_len(1024).unwrap();
            let count = Arc::new(AtomicUsize::new(0));
            let callback_count = count.clone();
            let frame = LinuxGpuFrame::new(file.into(), Descriptor {
                fd: -1, width: 16, height: 16, fourcc: u32::from_le_bytes(*b"XR24"),
                pitch: 64, offset: 0, size: 1024, modifier: 0,
            }, 42, move || { callback_count.fetch_add(1, Ordering::SeqCst); }).unwrap();
            assert_eq!(LIVE_SOURCES.load(Ordering::Acquire), baseline + 1);
            let retained = frame.clone();
            drop(frame);
            assert_eq!(count.load(Ordering::SeqCst), 0);
            assert!(retained.valid());
            if complete {
                retained.lease.complete();
                retained.lease.complete();
                assert!(!retained.valid());
                assert!(retained.descriptor().is_err());
                assert_eq!(count.load(Ordering::SeqCst), 1);
                assert_eq!(LIVE_SOURCES.load(Ordering::Acquire), baseline);
            }
            drop(retained);
            assert_eq!(count.load(Ordering::SeqCst), 1);
            assert_eq!(LIVE_SOURCES.load(Ordering::Acquire), baseline);
        }
    }

    #[test]
    fn failed_device_initialization_latches_reason_and_returns_worker_permit() {
        for _ in 0..2 {
            let failure: Failure = Default::default();
            let config = EncoderCfg::LinuxGpu(LinuxGpuEncoderConfig {
                render_node: "/farpane-test/nonexistent".into(), width: 16, height: 16,
                fourcc: u32::from_le_bytes(*b"XR24"), kbps: 100, fps: 12, gop: 12,
                generation: 1, failure: failure.clone(),
            });
            assert!(LinuxGpuEncoder::new(config, false).is_err());
            assert!(failure.lock().unwrap().as_ref().unwrap().contains("DRM device"));
        }
    }
}
