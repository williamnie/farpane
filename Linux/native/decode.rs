//! Thread-confined VAAPI decoder. No Host IPC, UI toolkit, or host FFmpeg.
//! A returned lease remains in the decoder until the renderer proves completion.
use farpane_protocol::frame::{
    Chroma, Color, ColorSource, Frame, Layer, Matrix, Object, Plane, Range, SoftwareFrame,
};
use hbb_common::{anyhow::anyhow, bail, ResultType};
use std::{
    ffi::{c_char, c_void, CStr},
    marker::PhantomData,
    os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd},
    ptr::NonNull,
    rc::Rc,
};

#[derive(Clone, Copy, Default)]
#[repr(C)]
struct RawObject {
    fd: i32,
    reserved: u32,
    size: u64,
    modifier: u64,
}
#[derive(Clone, Copy, Default)]
#[repr(C)]
struct RawLayer {
    format: u32,
    object: u32,
    pitch: u32,
    reserved: u32,
    offset: u64,
}
#[derive(Default)]
#[repr(C)]
struct RawFrame {
    lease: u64,
    pts: i64,
    width: u32,
    height: u32,
    object_count: u32,
    pool_size: u32,
    objects: [RawObject; 4],
    layers: [RawLayer; 2],
    matrix: i32,
    range: i32,
    primaries: i32,
    transfer: i32,
    chroma: i32,
}
#[repr(C)]
struct RawCpuFrame {
    lease: u64,
    pts: i64,
    width: u32,
    height: u32,
    stride: u32,
    reserved: u32,
    bgra: *const u8,
    length: usize,
}
extern "C" {
    fn fp_viewer_create(fd: i32, codec: i32, error: *mut c_char, size: usize) -> *mut c_void;
    fn fp_viewer_create_software(codec: i32, error: *mut c_char, size: usize) -> *mut c_void;
    fn fp_viewer_send(ctx: *mut c_void, data: *const u8, length: usize, pts: i64) -> i32;
    fn fp_viewer_receive(ctx: *mut c_void, frame: *mut RawFrame) -> i32;
    fn fp_viewer_receive_software(ctx: *mut c_void, frame: *mut RawCpuFrame) -> i32;
    fn fp_viewer_release(ctx: *mut c_void, lease: u64) -> i32;
    fn fp_viewer_error(ctx: *const c_void) -> *const c_char;
    fn fp_viewer_destroy(ctx: *mut c_void);
}

#[derive(Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Codec {
    H264 = 1,
    Hevc = 2,
    Vp8 = 3,
    Vp9 = 4,
}
pub enum Output {
    Frame(Frame, Vec<OwnedFd>),
    Software(SoftwareFrame, OwnedFd),
    NeedsInput,
    Backpressure,
}
pub struct Decoder {
    context: NonNull<c_void>,
    generation: u64,
    /// Reported after the first format negotiation; counts DPB and loaned frames.
    pub pool_size: u32,
    pub hardware: bool,
    _thread_confined: PhantomData<Rc<()>>,
}
impl Decoder {
    pub fn new(render: BorrowedFd<'_>, codec: Codec, generation: u64) -> ResultType<Self> {
        if generation == 0 {
            bail!("Invalid Viewer decoder generation");
        }
        let mut error = [0 as c_char; 256];
        let ptr = unsafe {
            fp_viewer_create(
                render.as_raw_fd(),
                codec as i32,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        let context = NonNull::new(ptr).ok_or_else(|| {
            anyhow!(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned())
        })?;
        Ok(Self {
            context,
            generation,
            pool_size: 0,
            hardware: true,
            _thread_confined: PhantomData,
        })
    }
    pub fn software(codec: Codec, generation: u64) -> ResultType<Self> {
        if generation == 0 {
            bail!("Invalid Viewer decoder generation");
        }
        let mut error = [0 as c_char; 256];
        let ptr =
            unsafe { fp_viewer_create_software(codec as i32, error.as_mut_ptr(), error.len()) };
        let context = NonNull::new(ptr).ok_or_else(|| {
            anyhow!(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned())
        })?;
        Ok(Self {
            context,
            generation,
            hardware: false,
            pool_size: 0,
            _thread_confined: PhantomData,
        })
    }
    fn error(&self) -> hbb_common::anyhow::Error {
        anyhow!(
            unsafe { CStr::from_ptr(fp_viewer_error(self.context.as_ptr())) }
                .to_string_lossy()
                .into_owned()
        )
    }
    /// false means drain output and retry this exact compressed packet. Never
    /// drop arbitrary reference packets to keep up with a slow renderer.
    pub fn send(&mut self, bytes: &[u8], pts: i64) -> ResultType<bool> {
        match unsafe { fp_viewer_send(self.context.as_ptr(), bytes.as_ptr(), bytes.len(), pts) } {
            0 => Ok(true),
            1 => Ok(false),
            _ => Err(self.error()),
        }
    }
    pub fn receive(&mut self) -> ResultType<Output> {
        if !self.hardware {
            return self.receive_software();
        }
        let mut raw = RawFrame::default();
        match unsafe { fp_viewer_receive(self.context.as_ptr(), &mut raw) } {
            1 => return Ok(Output::NeedsInput),
            2 => return Ok(Output::Backpressure),
            0 => (),
            _ => return Err(self.error()),
        }
        let result = self.export(&raw);
        if result.is_err() {
            // This frame was never delivered. It has no external GPU reader.
            unsafe {
                fp_viewer_release(self.context.as_ptr(), raw.lease);
            }
        }
        result
    }
    fn receive_software(&mut self) -> ResultType<Output> {
        let mut raw: RawCpuFrame = unsafe { std::mem::zeroed() };
        match unsafe { fp_viewer_receive_software(self.context.as_ptr(), &mut raw) } {
            1 => return Ok(Output::NeedsInput),
            2 => return Ok(Output::Backpressure),
            0 => (),
            _ => return Err(self.error()),
        }
        let result = (|| {
            let frame = SoftwareFrame {
                generation: self.generation,
                lease: raw.lease,
                pts: raw.pts,
                width: raw.width,
                height: raw.height,
                stride: raw.stride,
            };
            if raw.bgra.is_null() || frame.byte_len().map_err(|e| anyhow!(e))? != raw.length {
                bail!("Invalid software decoder pixels");
            }
            let bytes = unsafe { std::slice::from_raw_parts(raw.bgra, raw.length) };
            Ok(Output::Software(
                frame,
                farpane_protocol::sealed::create(bytes)?,
            ))
        })();
        // The GUI owns an immutable copy. No CPU decoder reference crosses IPC.
        unsafe {
            fp_viewer_release(self.context.as_ptr(), raw.lease);
        }
        result
    }
    fn export(&mut self, raw: &RawFrame) -> ResultType<Output> {
        if !(1..=4).contains(&raw.object_count) || raw.pool_size == 0 || raw.pool_size > 23 {
            bail!("Invalid Viewer decoder object/pool budget");
        }
        let frame = Frame {
            generation: self.generation,
            lease: raw.lease,
            pts: raw.pts,
            width: raw.width,
            height: raw.height,
            objects: raw.objects[..raw.object_count as usize]
                .iter()
                .map(|object| Object {
                    size: object.size,
                    modifier: object.modifier,
                })
                .collect(),
            layers: raw
                .layers
                .iter()
                .map(|layer| Layer {
                    format: layer.format,
                    planes: vec![Plane {
                        object: layer.object,
                        offset: layer.offset,
                        pitch: layer.pitch,
                    }],
                })
                .collect(),
            color: color(raw)?,
        };
        frame
            .validate(raw.object_count as usize, self.generation)
            .map_err(|e| anyhow!(e))?;
        let mut files = Vec::new();
        for object in &raw.objects[..raw.object_count as usize] {
            let fd =
                unsafe { hbb_common::libc::fcntl(object.fd, hbb_common::libc::F_DUPFD_CLOEXEC, 3) };
            if fd < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            files.push(unsafe { OwnedFd::from_raw_fd(fd) });
        }
        self.pool_size = raw.pool_size;
        Ok(Output::Frame(frame, files))
    }
    /// Call only for a never-published candidate or after the GUI's completion
    /// fence signalled. Stale/duplicate acknowledgements cannot release a frame.
    pub fn release_completed(&mut self, generation: u64, lease: u64) -> ResultType<()> {
        if generation != self.generation
            || unsafe { fp_viewer_release(self.context.as_ptr(), lease) } != 0
        {
            bail!("Unknown or stale Viewer frame acknowledgement");
        }
        Ok(())
    }
}
impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe { fp_viewer_destroy(self.context.as_ptr()) };
    }
}

fn color(raw: &RawFrame) -> ResultType<Color> {
    let mut color = Color::compatibility_default(raw.height);
    color.matrix = match raw.matrix {
        1 => Matrix::Bt709,
        5 | 6 => Matrix::Bt601,
        2 => color.matrix,
        _ => bail!("Unsupported Viewer color matrix"),
    };
    color.range = match raw.range {
        1 => Range::Limited,
        2 => Range::Full,
        0 => color.range,
        _ => bail!("Unsupported Viewer color range"),
    };
    color.chroma = match raw.chroma {
        1 => Chroma::Left,
        2 => Chroma::Center,
        0 => color.chroma,
        _ => bail!("Unsupported Viewer chroma location"),
    };
    if !(0..=255).contains(&raw.primaries)
        || !(0..=255).contains(&raw.transfer)
        || matches!(raw.transfer, 16 | 18)
    {
        bail!("Unsupported Viewer color characteristics");
    }
    color.primaries = raw.primaries as u8;
    color.transfer = raw.transfer as u8;
    color.source = if raw.matrix == 2 || raw.range == 0 || raw.chroma == 0 {
        ColorSource::CompatibilityDefault
    } else {
        ColorSource::Vui
    };
    Ok(color)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsFd;
    #[test]
    fn colors_preserve_vui_and_reject_hdr_or_unknown_matrix() {
        let mut raw = RawFrame {
            height: 1440,
            matrix: 2,
            range: 0,
            primaries: 2,
            transfer: 2,
            chroma: 0,
            ..Default::default()
        };
        let inferred = color(&raw).unwrap();
        assert_eq!(inferred.matrix, Matrix::Bt709);
        assert_eq!(inferred.range, Range::Limited);
        assert_eq!(inferred.source, ColorSource::CompatibilityDefault);
        raw.matrix = 6;
        raw.range = 2;
        raw.chroma = 2;
        let explicit = color(&raw).unwrap();
        assert_eq!(explicit.matrix, Matrix::Bt601);
        assert_eq!(explicit.range, Range::Full);
        assert_eq!(explicit.chroma, Chroma::Center);
        assert_eq!(explicit.source, ColorSource::Vui);
        raw.transfer = 16;
        assert!(color(&raw).is_err());
        raw.transfer = 2;
        raw.matrix = 9;
        assert!(color(&raw).is_err());
    }
    #[test]
    fn decoder_rejects_non_render_fd_without_opening_a_gpu() {
        assert_eq!(std::mem::size_of::<RawFrame>(), 200);
        assert_eq!(std::mem::offset_of!(RawFrame, matrix), 176);
        let file = std::fs::File::open("/dev/null").unwrap();
        assert!(Decoder::new(file.as_fd(), Codec::H264, 1).is_err());
        assert!(Decoder::new(file.as_fd(), Codec::Hevc, 1).is_err());
    }
    #[test]
    fn software_vpx_decodes_real_packets_into_immutable_bgra() {
        use scrap::{
            codec::{EncoderApi, EncoderCfg},
            VpxEncoder, VpxEncoderConfig, VpxVideoCodecId,
        };
        for (codec, encoder_codec) in [
            (Codec::Vp8, VpxVideoCodecId::VP8),
            (Codec::Vp9, VpxVideoCodecId::VP9),
        ] {
            let mut encoder = VpxEncoder::new(
                EncoderCfg::VPX(VpxEncoderConfig {
                    width: 64,
                    height: 48,
                    quality: 1.0,
                    codec: encoder_codec,
                    keyframe_interval: Some(30),
                }),
                false,
            )
            .unwrap();
            let mut decoder = Decoder::software(codec, 1).unwrap();
            let mut count = 0;
            for (pts, luma) in [(10, 235u8), (20, 16)] {
                let mut pixels = vec![128; 64 * 48 * 3 / 2];
                pixels[..64 * 48].fill(luma);
                let mut packets: Vec<_> = encoder
                    .encode(pts, &pixels, 1)
                    .unwrap()
                    .map(|packet| packet.data.to_vec())
                    .collect();
                packets.extend(encoder.flush().unwrap().map(|packet| packet.data.to_vec()));
                assert!(!packets.is_empty());
                for packet in packets {
                    assert!(decoder.send(&packet, pts).unwrap());
                    loop {
                        match decoder.receive().unwrap() {
                            Output::NeedsInput => break,
                            Output::Software(frame, file) => {
                                assert_eq!((frame.width, frame.height, frame.pts), (64, 48, pts));
                                let bytes = farpane_protocol::sealed::Bytes::map(
                                    file,
                                    frame.byte_len().unwrap(),
                                )
                                .unwrap();
                                for pixel in bytes.as_ref().chunks_exact(4) {
                                    assert_eq!(pixel[3], 255);
                                    assert!(pixel[..3].iter().all(|v| if luma == 235 {
                                        *v > 245
                                    } else {
                                        *v < 10
                                    }));
                                }
                                count += 1;
                            }
                            _ => panic!("Software decoder returned a GPU frame or leaked a lease"),
                        }
                    }
                }
            }
            assert_eq!(count, 2);
        }
    }
    #[test]
    fn software_decoder_rejects_oversized_keyframe_before_allocation() {
        // VP8 keyframe sync header claims 8191² pixels; reject before libvpx decode.
        let bytes = [0, 0, 0, 0x9d, 1, 0x2a, 0xff, 0x1f, 0xff, 0x1f];
        let mut decoder = Decoder::software(Codec::Vp8, 1).unwrap();
        assert!(decoder.send(&bytes, 0).is_err());
        assert!(
            decoder.send(&bytes, 1).is_err(),
            "Failed decoder must remain poisoned"
        );
    }
}
