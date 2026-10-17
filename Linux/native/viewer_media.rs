//! One bounded compressed queue, one decoder generation, three presentation loans.
use super::{
    decode::{Codec, Decoder, Output},
    viewer::State,
};
use base::message_proto::{supported_decoding, video_frame, SupportedDecoding, VideoFrame};
use farpane_protocol::{
    frame,
    frame_socket::{Channel, Packet},
    EventKind, Renderer,
};
use hbb_common::{bail, ResultType};
use std::{
    collections::HashMap,
    fs::OpenOptions,
    os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError},
        Arc, OnceLock,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

const QUEUE_BYTES: usize = 16 * 1024 * 1024;
const ACK: Duration = Duration::from_millis(500);
struct Reservation {
    bytes: usize,
    total: Arc<AtomicUsize>,
    items: Arc<AtomicUsize>,
}
impl Drop for Reservation {
    fn drop(&mut self) {
        self.total.fetch_sub(self.bytes, Ordering::AcqRel);
        self.items.fetch_sub(1, Ordering::AcqRel);
    }
}
struct Queued {
    frame: VideoFrame,
    _reserved: Reservation,
}
struct Handle {
    queue: SyncSender<Queued>,
    wake: Arc<OwnedFd>,
    bytes: Arc<AtomicUsize>,
    items: Arc<AtomicUsize>,
    state: Arc<State>,
}
static HANDLE: OnceLock<Handle> = OnceLock::new();

pub fn supported() -> SupportedDecoding {
    SupportedDecoding {
        ability_h264: 1,
        ability_h265: 1,
        ability_vp8: 1,
        ability_vp9: 1,
        prefer: supported_decoding::PreferCodec::H264.into(),
        ..Default::default()
    }
}
pub fn enqueue(frame: VideoFrame) -> bool {
    let Some(handle) = HANDLE.get() else {
        return false;
    };
    if handle.state.stopped.load(Ordering::Acquire) {
        return false;
    }
    let bytes = match &frame.union {
        Some(
            video_frame::Union::H264s(frames)
            | video_frame::Union::H265s(frames)
            | video_frame::Union::Vp8s(frames)
            | video_frame::Union::Vp9s(frames),
        ) if frames.frames.len() <= 256 => frames
            .frames
            .iter()
            .try_fold(0usize, |n, frame| n.checked_add(frame.data.len())),
        _ => None,
    };
    let Some(bytes) = bytes.filter(|n| *n != 0 && *n <= QUEUE_BYTES) else {
        handle
            .state
            .fail("Remote sent an unsupported or oversized video packet");
        return false;
    };
    if handle
        .bytes
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            n.checked_add(bytes).filter(|n| *n <= QUEUE_BYTES)
        })
        .is_err()
    {
        handle
            .state
            .fail("Viewer compressed queue exceeded its byte budget");
        return false;
    }
    {
        let mut metrics = handle.state.metrics.lock().unwrap();
        metrics.received_bytes = metrics.received_bytes.saturating_add(bytes as u64);
        metrics.received_packets = metrics.received_packets.saturating_add(match &frame.union {
            Some(
                video_frame::Union::H264s(f)
                | video_frame::Union::H265s(f)
                | video_frame::Union::Vp8s(f)
                | video_frame::Union::Vp9s(f),
            ) => f.frames.len() as u64,
            _ => 0,
        });
    }
    handle.items.fetch_add(1, Ordering::AcqRel);
    let value = Queued {
        frame,
        _reserved: Reservation {
            bytes,
            total: handle.bytes.clone(),
            items: handle.items.clone(),
        },
    };
    if handle.queue.try_send(value).is_err() {
        handle.state.metrics.lock().unwrap().channel_rejected_groups += 1;
        handle
            .state
            .fail("Viewer is too far behind; reconnect to request a fresh keyframe");
        return false;
    }
    unsafe {
        hbb_common::libc::write(handle.wake.as_raw_fd(), (&1u64 as *const u64).cast(), 8);
    }
    true
}

pub fn gauges() -> (u64, u32) {
    HANDLE
        .get()
        .map(|h| {
            (
                h.bytes.load(Ordering::Acquire) as u64,
                h.items.load(Ordering::Acquire) as u32,
            )
        })
        .unwrap_or_default()
}

pub fn start(
    channel: Channel,
    renderer: Renderer,
    state: Arc<State>,
) -> ResultType<JoinHandle<()>> {
    let fd = unsafe {
        hbb_common::libc::eventfd(
            0,
            hbb_common::libc::EFD_CLOEXEC | hbb_common::libc::EFD_NONBLOCK,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let wake = Arc::new(unsafe { OwnedFd::from_raw_fd(fd) });
    let (tx, rx) = mpsc::sync_channel(4);
    HANDLE
        .set(Handle {
            queue: tx,
            wake: wake.clone(),
            bytes: Arc::new(AtomicUsize::new(0)),
            items: Arc::new(AtomicUsize::new(0)),
            state: state.clone(),
        })
        .map_err(|_| hbb_common::anyhow::anyhow!("Viewer media already started"))?;
    Ok(std::thread::Builder::new()
        .name("viewer-media".into())
        .spawn(move || {
            if let Err(error) = run(channel, renderer, &state, rx, &wake) {
                state.fail(&error.to_string());
            }
            state.media_idle();
        })?)
}

struct Watched {
    decoder: Decoder,
    state: Arc<State>,
}
impl Watched {
    fn call<T>(&mut self, action: impl FnOnce(&mut Decoder) -> ResultType<T>) -> ResultType<T> {
        self.state.media_call(ACK);
        let at = Instant::now();
        let result = action(&mut self.decoder);
        let nanos = at.elapsed().as_nanos().min(u64::MAX as u128) as u64;
        let mut metrics = self.state.metrics.lock().unwrap();
        metrics.decode_call_ns = metrics.decode_call_ns.saturating_add(nanos);
        drop(metrics);
        self.state.media_idle();
        result
    }
}
impl Drop for Watched {
    fn drop(&mut self) {
        self.state.media_call(ACK);
    }
}
fn decoder(
    codec: Codec,
    generation: u64,
    renderer: &Renderer,
    state: &Arc<State>,
) -> ResultType<Watched> {
    state.media_call(Duration::from_secs(3));
    let gpu_formats = [frame::R8, frame::GR88]
        .iter()
        .all(|format| renderer.formats.iter().any(|f| f.format == *format));
    let hardware =
        if !renderer.software && gpu_formats && matches!(codec, Codec::H264 | Codec::Hevc) {
            OpenOptions::new()
                .read(true)
                .write(true)
                .open("/dev/dri/renderD128")
                .map_err(Into::into)
                .and_then(|file| Decoder::new(file.as_fd(), codec, generation))
        } else {
            Err(hbb_common::anyhow::anyhow!(
                "Renderer selected software compatibility"
            ))
        };
    let (decoder, detail) = match hardware {
        Ok(decoder) => (decoder, "VAAPI → DRM_PRIME"),
        Err(_) => (
            Decoder::software(codec, generation)?,
            "软件兼容模式：CPU 解码与颜色转换",
        ),
    };
    state.media_idle();
    let backend = if decoder.hardware {
        "vaapi"
    } else {
        "software"
    };
    {
        let mut metrics = state.metrics.lock().unwrap();
        metrics.backend = backend.into();
        metrics.codec = match codec {
            Codec::H264 => "H.264",
            Codec::Hevc => "HEVC",
            Codec::Vp8 => "VP8",
            Codec::Vp9 => "VP9",
        }
        .into();
    }
    state.emit_at(
        generation,
        EventKind::Media {
            backend: backend.into(),
            detail: detail.into(),
        },
    );
    Ok(Watched {
        decoder,
        state: state.clone(),
    })
}

fn acknowledgements(
    channel: &Channel,
    decoder: &mut Watched,
    generation: u64,
    outstanding: &mut HashMap<u64, Instant>,
) -> ResultType<()> {
    loop {
        match channel.receive() {
            Ok((
                Packet::Release {
                    generation: returned,
                    lease,
                },
                _,
            )) if returned < generation => {}
            Ok((
                Packet::Release {
                    generation: returned,
                    lease,
                },
                _,
            )) if returned == generation => {
                if outstanding.remove(&lease).is_none() {
                    bail!("Unknown or duplicated Viewer frame acknowledgement");
                }
                decoder.state.metrics.lock().unwrap().leases = outstanding.len() as u32;
                if decoder.decoder.hardware {
                    decoder.state.media_call(ACK);
                    let result = decoder.decoder.release_completed(generation, lease);
                    decoder.state.media_idle();
                    result?;
                }
            }
            Ok(_) => bail!("Unexpected Viewer frame channel message"),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(error) => return Err(error.into()),
        }
    }
    if outstanding.values().any(|at| at.elapsed() > ACK) {
        bail!("Viewer presentation acknowledgement timed out");
    }
    Ok(())
}
fn poll(channel: &Channel, wake: &OwnedFd, timeout: i32) -> ResultType<()> {
    let mut fds = [
        hbb_common::libc::pollfd {
            fd: channel.as_raw_fd(),
            events: hbb_common::libc::POLLIN,
            revents: 0,
        },
        hbb_common::libc::pollfd {
            fd: wake.as_raw_fd(),
            events: hbb_common::libc::POLLIN,
            revents: 0,
        },
    ];
    if unsafe { hbb_common::libc::poll(fds.as_mut_ptr(), fds.len() as _, timeout) } < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if fds[0].revents & (hbb_common::libc::POLLHUP | hbb_common::libc::POLLERR) != 0 {
        bail!("Viewer renderer disconnected");
    }
    if fds[1].revents & hbb_common::libc::POLLIN != 0 {
        let mut count = 0u64;
        unsafe {
            hbb_common::libc::read(wake.as_raw_fd(), (&mut count as *mut u64).cast(), 8);
        }
    }
    Ok(())
}

fn drain_output(
    channel: &Channel,
    wake: &OwnedFd,
    decoder: &mut Watched,
    renderer: &Renderer,
    state: &State,
    generation: u64,
    outstanding: &mut HashMap<u64, Instant>,
) -> ResultType<()> {
    loop {
        acknowledgements(channel, decoder, generation, outstanding)?;
        if state.stopped.load(Ordering::Acquire) {
            bail!("Viewer stopped");
        }
        if outstanding.len() >= frame::MAX_LEASES {
            poll(channel, wake, 10)?;
            continue;
        }
        let output = decoder.call(Decoder::receive)?;
        let (packet, files, lease) = match output {
            Output::NeedsInput => return Ok(()),
            Output::Backpressure => {
                poll(channel, wake, 10)?;
                continue;
            }
            Output::Frame(frame, files) => {
                for layer in &frame.layers {
                    let object = &frame.objects[layer.planes[0].object as usize];
                    if !renderer
                        .formats
                        .iter()
                        .any(|f| f.format == layer.format && f.modifier == object.modifier)
                    {
                        bail!("Decoded GPU modifier is unavailable in the renderer; use software compatibility");
                    }
                }
                let lease = frame.lease;
                (Packet::DmaBuf(frame), files, lease)
            }
            Output::Software(frame, file) => {
                let lease = frame.lease;
                (Packet::Software(frame), vec![file], lease)
            }
        };
        let raw: Vec<_> = files.iter().map(AsRawFd::as_raw_fd).collect();
        channel.send(&packet, &raw)?;
        outstanding.insert(lease, Instant::now());
        let mut metrics = state.metrics.lock().unwrap();
        metrics.decoded_frames = metrics.decoded_frames.saturating_add(1);
        metrics.leases = outstanding.len() as u32;
    }
}
fn run(
    channel: Channel,
    renderer: Renderer,
    state: &Arc<State>,
    rx: Receiver<Queued>,
    wake: &OwnedFd,
) -> ResultType<()> {
    let mut decoder_state: Option<Watched> = None;
    let mut active = None;
    let mut outstanding = HashMap::new();
    let mut generation = state.generation();

    while !state.stopped.load(Ordering::Acquire) {
        if let Some(decoder) = &mut decoder_state {
            acknowledgements(&channel, decoder, generation, &mut outstanding)?;
        }
        let queued = match rx.try_recv() {
            Ok(frame) => frame,
            Err(TryRecvError::Empty) => {
                poll(&channel, wake, 100)?;
                continue;
            }
            Err(TryRecvError::Disconnected) => return Ok(()),
        };
        let vf = &queued.frame;
        if vf.display != state.selected.load(Ordering::Acquire) {
            state.metrics.lock().unwrap().skipped_display_groups += 1;
            continue;
        }
        let (codec, packets) = match &vf.union {
            Some(video_frame::Union::H264s(frames)) => (Codec::H264, &frames.frames),
            Some(video_frame::Union::H265s(frames)) => (Codec::Hevc, &frames.frames),
            Some(video_frame::Union::Vp8s(frames)) => (Codec::Vp8, &frames.frames),
            Some(video_frame::Union::Vp9s(frames)) => (Codec::Vp9, &frames.frames),
            _ => bail!("Remote selected an unsupported Viewer codec"),
        };
        let key = (vf.display, codec);
        if active != Some(key) {
            if let Some(old) = &mut decoder_state {
                channel.send(&Packet::Drain { generation }, &[])?;
                while !outstanding.is_empty() {
                    acknowledgements(&channel, old, generation, &mut outstanding)?;
                    if state.stopped.load(Ordering::Acquire) {
                        return Ok(());
                    }
                    poll(&channel, wake, 10)?;
                }
                drop(decoder_state.take());
                state.media_idle();
                generation = state.advance_generation()?;
                state.phase(
                    farpane_protocol::Phase::AwaitingFrame,
                    "显示器或编码已变化，等待新画面",
                );
            }
            decoder_state = Some(decoder(codec, generation, &renderer, state)?);
            active = Some(key);
        }
        let decoder = decoder_state.as_mut().unwrap();
        for packet in packets {
            let mut retries = 0;
            while !decoder.call(|d| d.send(&packet.data, packet.pts))? {
                retries += 1;
                if retries > 2 {
                    bail!("Viewer decoder made no progress while draining");
                }
                drain_output(
                    &channel,
                    wake,
                    decoder,
                    &renderer,
                    state,
                    generation,
                    &mut outstanding,
                )?;
            }
            drain_output(
                &channel,
                wake,
                decoder,
                &renderer,
                state,
                generation,
                &mut outstanding,
            )?;
        }
    }
    Ok(())
}
