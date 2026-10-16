use super::*;
use scrap::linux_gpu::{Descriptor, Failure, LinuxGpuEncoderConfig};
use crate::platform::linux::gpu_status;
use std::sync::atomic::{AtomicU64, Ordering};

const ENABLE: &str = "linux-gpu-media";
const RETRY: &str = "linux-gpu-retry";
static GENERATION: AtomicU64 = AtomicU64::new(1);

#[derive(Default)]
pub(super) struct State {
    identity: String,
    retry: String,
    failure: Failure,
}
impl State {
    fn for_identity(&mut self, identity: &str, retry: &str) -> Failure {
        if self.identity != identity || self.retry != retry {
            self.identity = identity.into();
            self.retry = retry.into();
            self.failure = Default::default();
        }
        self.failure.clone()
    }
}

pub(super) struct Run {
    state: Arc<Mutex<State>>,
    service: GenericService,
    enabled: bool,
    retry: String,
    monitor: bool,
}
impl Run {
    pub(super) fn new(state: Arc<Mutex<State>>, service: GenericService, monitor: bool) -> Self {
        Self { state, service, monitor, enabled: Config::get_option(ENABLE) == "Y", retry: Config::get_option(RETRY) }
    }
    pub(super) fn changed(&self, config: &Option<Selection>, spf: Duration) -> bool {
        self.monitor && (self.enabled != (Config::get_option(ENABLE) == "Y") || self.retry != Config::get_option(RETRY) ||
            config.as_ref().is_some_and(|c| c.fps != 0 && c.fps != fps(spf)))
    }
    pub(super) fn select(&self, source: VideoSource, index: usize)
        -> Option<(CapturerInfo, Selection)> {
        if !self.enabled || !source.is_monitor() { return None; }
        if Encoder::negotiated_codec() != CodecFormat::H264 {
            gpu_status::fallback("The connection did not negotiate H.264");
            return None;
        }
        if get_privacy_mode_conn_id().unwrap_or(INVALID_PRIVACY_MODE_CONN_ID) != INVALID_PRIVACY_MODE_CONN_ID {
            return None;
        }
        let eligible = match super::super::drm_capturer::gpu::eligible(index) {
            Ok(info) => info,
            Err(error) => {
                hbb_common::throttled_log!(Duration::from_secs(600), debug, "GPU media unavailable: {error}");
                gpu_status::fallback(&error.to_string());
                return None;
            }
        };
        let failure = {
            let mut state = self.state.lock().unwrap();
            state.for_identity(&eligible.key, &self.retry)
        };
        if let Some(reason) = failure.lock().unwrap().as_ref() {
            gpu_status::fallback(reason);
            return None;
        }
        let generation = GENERATION.fetch_add(1, Ordering::Relaxed);
        let node = eligible.info.render_node.clone();
        match super::super::drm_capturer::gpu::capture(eligible, generation, failure.clone()) {
            Ok((capturer, descriptor)) => Some((capturer, Selection {
                descriptor, node, generation, failure, fps: 0,
            })),
            Err(error) => {
                log::warn!("GPU capture declined; paired CPU fallback: {error}");
                gpu_status::fallback(&error.to_string());
                *failure.lock().unwrap() = Some(error.to_string());
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ordinary_rebuild_preserves_failure_until_explicit_retry_or_display_change() {
        let mut state = State::default();
        let first = state.for_identity("card0/Virtual-1/1920x1080", "");
        *first.lock().unwrap() = Some("source completion timeout".into());
        for _ in 0..5 {
            let rebuilt = state.for_identity("card0/Virtual-1/1920x1080", "");
            assert_eq!(rebuilt.lock().unwrap().as_deref(), Some("source completion timeout"));
        }
        let retried = state.for_identity("card0/Virtual-1/1920x1080", "retry-1");
        assert!(retried.lock().unwrap().is_none());
        *first.lock().unwrap() = Some("late old generation error".into());
        assert!(retried.lock().unwrap().is_none());
        *retried.lock().unwrap() = Some("import failure".into());
        assert!(state.for_identity("card0/Virtual-1/1280x720", "retry-1").lock().unwrap().is_none());
    }
}
impl Drop for Run {
    fn drop(&mut self) {
        if !self.service.has_subscribes() {
            *self.state.lock().unwrap() = State::default();
            if self.monitor { gpu_status::idle(); }
        }
    }
}

pub(super) struct Selection {
    descriptor: Descriptor,
    node: String,
    generation: u64,
    failure: Failure,
    fps: u32,
}

fn fps(spf: Duration) -> u32 { (1.0 / spf.as_secs_f64()).round().clamp(1.0, 120.0) as u32 }

impl Selection {
    pub(super) fn prepare(&mut self, spf: Duration) { self.fps = fps(spf); }

    pub(super) fn setup(&self, quality: f32, record: bool, record_incoming: bool, index: usize)
        -> ResultType<(Encoder, EncoderCfg, CodecFormat, bool, Arc<Mutex<Option<Recorder>>>)> {
        let config = EncoderCfg::LinuxGpu(LinuxGpuEncoderConfig {
            render_node: self.node.clone(), width: self.descriptor.width, height: self.descriptor.height,
            fourcc: self.descriptor.fourcc,
            kbps: scrap::hwcodec::HwRamEncoder::calc_bitrate(self.descriptor.width as usize,
                self.descriptor.height as usize, quality, true),
            fps: self.fps, gop: if record { 240 } else { i32::MAX as u32 },
            generation: self.generation, failure: self.failure.clone(),
        });
        let encoder = match Encoder::new(config.clone(), false) {
            Ok(encoder) => encoder,
            Err(error) => {
                *self.failure.lock().unwrap() = Some(error.to_string());
                return Err(error);
            }
        };
        log::info!("GPU media active: generation={} node={} {}x{} fps={} bitrate={}kbps",
            self.generation, self.node, self.descriptor.width, self.descriptor.height, self.fps, encoder.bitrate());
        gpu_status::active(self.generation, self.failure.clone());
        Ok((encoder, config, CodecFormat::H264, false, get_recorder(record_incoming, index, false)))
    }
}
