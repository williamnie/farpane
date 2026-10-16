use super::*;
use crate::ipc::DmabufDesc;
use hbb_common::libc;
use scrap::linux_gpu::{Descriptor, Failure, LinuxGpuFrame, IMPLICIT_MODIFIER};
use std::{os::fd::OwnedFd, path::Path};

pub(crate) struct Eligibility {
    pub info: DrmDisplayInfo,
    pub key: String,
    snapshot: u64,
    origin: (i32, i32),
    calibration: CalContext,
}

pub(crate) fn eligible(index: usize) -> ResultType<Eligibility> {
    if unsafe { libc::geteuid() } == 0 { bail!("GPU media must run in the unprivileged user server"); }
    if index != 0 || crate::platform::linux::is_x11() {
        bail!("GPU media requires a single Wayland display");
    }
    let displays = match &*DRM_STATE.lock().unwrap() {
        ProbeState::Available(_, displays) => displays.clone(),
        _ => bail!("DRM service is unavailable"),
    };
    if displays.len() != 1 { bail!("GPU media requires one DRM display"); }
    let info = displays[0].clone();
    if !info.active || info.name != "Virtual-1" || info.render_node != "/dev/dri/renderD128" {
        bail!("display is outside the qualified hermes configuration");
    }
    let card = Path::new(&info.device).file_name().and_then(|v| v.to_str())
        .filter(|v| v.starts_with("card")).ok_or_else(|| anyhow!("missing DRM card identity"))?;
    let device = std::fs::canonicalize(format!("/sys/class/drm/{card}/device"))?;
    let render = std::fs::canonicalize("/sys/class/drm/renderD128/device")?;
    if device != render || std::fs::read_to_string(device.join("vendor"))?.trim() != "0x1002" ||
        std::fs::read_to_string(device.join("device"))?.trim() != "0x1900" {
        bail!("unqualified GPU or scanout/render device mismatch");
    }
    let snapshot = scrap::wayland::display::wayland_snapshot_generation();
    let wl = scrap::wayland::display::get_displays();
    if wl.displays.len() != 1 { bail!("Wayland display snapshot is not single-output"); }
    let calibration = calibration_context(&displays, 0, &wl, snapshot).map_err(|e| anyhow!(e))?;
    let (transform, origin) = transform_and_origin(&displays, 0, &wl);
    if transform != 0 { bail!("GPU media does not support transformed output"); }
    // Snapshot counters also advance on ordinary SWITCH teardown. Only a changed
    // identity/geometry may clear a failure; a new counter alone must not retry it.
    let key = format!("{info:?}/{:?}", calibration.rect);
    super::super::display_service::note_capturer_layout(&wl.displays, snapshot);
    Ok(Eligibility { origin: origin.unwrap_or((info.x, info.y)), info, key, snapshot, calibration })
}

#[derive(Default)]
struct Slot { latest: Option<LinuxGpuFrame>, ended: Option<String> }
struct SharedGpu {
    slot: Mutex<Slot>,
    cv: Condvar,
    stop: AtomicBool,
    failure: Failure,
}
struct GpuCapturer {
    shared: Arc<SharedGpu>,
    snapshot: u64,
    first: Option<LinuxGpuFrame>,
}
impl Drop for GpuCapturer {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.slot.lock().unwrap().latest.take();
    }
}
impl TraitCapturer for GpuCapturer {
    fn frame<'a>(&'a mut self, timeout: Duration) -> io::Result<Frame<'a>> {
        if scrap::wayland::display::wayland_snapshot_generation() != self.snapshot {
            return Err(io::Error::new(io::ErrorKind::Other, "GPU display layout changed"));
        }
        if let Some(frame) = self.first.take() { return Ok(Frame::LinuxGpu(frame)); }
        take_frame(&self.shared, timeout).map(Frame::LinuxGpu)
    }
}
fn take_frame(shared: &SharedGpu, timeout: Duration) -> io::Result<LinuxGpuFrame> {
    let deadline = Instant::now() + timeout;
    let mut slot = shared.slot.lock().unwrap();
    loop {
        if let Some(reason) = &slot.ended {
            return Err(io::Error::new(io::ErrorKind::Other, reason.clone()));
        }
        if let Some(frame) = slot.latest.take() { return Ok(frame); }
        let now = Instant::now();
        if now >= deadline { return Err(io::ErrorKind::WouldBlock.into()); }
        slot = shared.cv.wait_timeout(slot, deadline - now).unwrap().0;
    }
}

pub(crate) fn capture(eligible: Eligibility, generation: u64, failure: Failure)
    -> ResultType<(super::super::video_service::CapturerInfo, Descriptor)> {
    let shared = Arc::new(SharedGpu {
        slot: Mutex::new(Slot::default()), cv: Condvar::new(), stop: AtomicBool::new(false), failure,
    });
    let mut capturer = GpuCapturer { shared: shared.clone(), snapshot: eligible.snapshot, first: None };
    let info = eligible.info.clone();
    let origin = eligible.origin;
    std::thread::Builder::new().name("farpane-drm-recv".into()).spawn(move || {
        let result = tokio::runtime::Builder::new_current_thread().enable_all().build()
            .map_err(hbb_common::anyhow::Error::from)
            .and_then(|runtime| runtime.block_on(receive(&eligible, generation, &shared)));
        if let Err(error) = result {
            let reason = error.to_string();
            let mut failure = shared.failure.lock().unwrap();
            if !shared.stop.load(Ordering::Acquire) && failure.is_none() { *failure = Some(reason.clone()); }
            shared.slot.lock().unwrap().ended = Some(reason);
        } else {
            shared.slot.lock().unwrap().ended = Some("GPU capture stopped".into());
        }
        shared.stop.store(true, Ordering::Release);
        shared.slot.lock().unwrap().latest.take();
        shared.cv.notify_all();
    })?;
    let first = take_frame(&capturer.shared, Duration::from_secs(16))?;
    let descriptor = first.descriptor()?;
    capturer.first = Some(first);
    Ok((super::super::video_service::CapturerInfo {
        origin, width: info.width as usize, height: info.height as usize,
        ndisplay: 1, current: 0, privacy_mode_id: 0, _capturer_privacy_mode_id: 0,
        capturer: Box::new(capturer),
    }, descriptor))
}

fn frame_descriptor(desc: &DmabufDesc, fd: &OwnedFd, info: &DrmDisplayInfo) -> ResultType<Descriptor> {
    if !desc.has_fd || desc.num_planes != 1 ||
        !matches!(desc.modifier, 0 | IMPLICIT_MODIFIER) || desc.hdr_eotf != 0 ||
        desc.plane_rotation != Some(1) || desc.width != info.width || desc.height != info.height {
        bail!("unsupported DMA-BUF: {}x{} (display {}x{}), planes={}, modifier={:#x}, HDR={}, rotation={:?}, fd={}",
            desc.width, desc.height, info.width, info.height, desc.num_planes, desc.modifier,
            desc.hdr_eotf, desc.plane_rotation, desc.has_fd);
    }
    let size = unsafe { libc::lseek(fd.as_raw_fd(), 0, libc::SEEK_END) };
    if size <= 0 { bail!("DMA-BUF object size is unavailable"); }
    Ok(Descriptor { fd: fd.as_raw_fd(), width: desc.width, height: desc.height,
        fourcc: desc.format, pitch: desc.pitches[0], offset: desc.offsets[0], size: size as u64,
        modifier: desc.modifier })
}

async fn receive(eligible: &Eligibility, generation: u64, shared: &Arc<SharedGpu>) -> ResultType<()> {
    let mut conn = connect_drm(DRM_CONNECT_TIMEOUT_MS).await?;
    let displays = match conn.recv_msg_timeout2(DISPLAY_LIST_TIMEOUT_MS).await {
        Some(Ok((Data::DrmDisplayList(displays), _))) => displays,
        _ => bail!("GPU DRM handshake failed"),
    };
    if displays.len() != 1 || displays[0] != eligible.info {
        swap_available_displays(displays);
        scrap::wayland::display::clear_wayland_displays_cache();
        bail!("GPU display identity changed during handshake");
    }
    conn.send_msg(&Data::DrmStart { display: 0, need_cpu: false }, None).await?;
    let (ack, mut credits) = tokio::sync::mpsc::channel::<()>(2);
    let epoch = next_cursor_epoch();
    struct CursorEpoch(u64);
    impl Drop for CursorEpoch { fn drop(&mut self) { remove_drm_cursor(0, self.0); } }
    let _cursor = CursorEpoch(epoch);
    let mut cal = None;
    loop {
        if shared.stop.load(Ordering::Acquire) { return Ok(()); }
        // Only the readiness wait is cancelled. Once any message byte is read,
        // recv_msg_timeout2 owns the whole frame, including its SCM_RIGHTS FD.
        tokio::select! {
            biased;
            credit = credits.recv() => {
                if credit.is_none() { bail!("GPU credit channel closed"); }
                if shared.stop.load(Ordering::Acquire) { return Ok(()); }
                conn.send_frame_ack().await?;
                continue;
            }
            ready = conn.wait_readable() => { ready?; }
            _ = tokio::time::sleep(Duration::from_millis(100)) => { continue; }
        }
        let (message, fd) = match conn.recv_msg_timeout2(200).await {
            Some(result) => result?,
            None => continue,
        };
        match message {
            Data::DrmFrameDmabuf(desc) => {
                on_cursor_plane(&mut cal, desc.cursor_pos,
                    super::super::input_service::last_peer_abs_sample,
                    super::super::display_service::wayland_layout_drifted(),
                    scrap::wayland::display::wayland_snapshot_generation(),
                    super::super::display_service::input_map_gen(),
                    super::super::display_service::input_map_epoch(), 0, epoch);
                let fd = fd.ok_or_else(|| anyhow!("GPU frame carried no owned FD"))?;
                let descriptor = frame_descriptor(&desc, &fd, &eligible.info)?;
                let ack = ack.clone();
                let shared_ack = Arc::downgrade(shared);
                let frame = LinuxGpuFrame::new(fd, descriptor, generation, move || {
                    if let Some(shared) = shared_ack.upgrade() {
                        if !shared.stop.load(Ordering::Acquire) && ack.try_send(()).is_err() {
                            shared.stop.store(true, Ordering::Release);
                            *shared.failure.lock().unwrap() = Some("GPU credit channel overflow/closed".into());
                        }
                    }
                })?;
                let previous = shared.slot.lock().unwrap().latest.replace(frame);
                drop(previous);
                shared.cv.notify_one();
            }
            Data::DrmCursor { id, width, height, hotx, hoty, hot_measured } => {
                if width == 0 || height == 0 || width > 512 || height > 512 {
                    bail!("invalid GPU cursor dimensions");
                }
                let mut raw = Vec::new();
                conn.next_raw_into(&mut raw).await?;
                if raw.len() != width as usize * height as usize * 4 { bail!("invalid GPU cursor body"); }
                cal = on_cursor_shape(0, epoch, Some(eligible.calibration), id, width, height,
                    hotx, hoty, hot_measured, raw, 0);
            }
            Data::DrmDisplaysChanged(displays) => {
                swap_available_displays(displays);
                scrap::wayland::display::clear_wayland_displays_cache();
                bail!("GPU display topology changed; rebuilding paired backend");
            }
            Data::DrmFrame { .. } => bail!("DRM producer returned CPU pixels to GPU capturer"),
            _ => {}
        }
    }
}
