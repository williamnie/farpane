//! Bounded remote audio. Format, permission and stop changes bypass the queue.
use super::{audio, viewer::State};
use crate::client::MediaData;
use farpane_protocol::EventKind;
use hbb_common::{bail, ResultType};
use magnum_opus::{Channels, Decoder};
use std::{
    collections::VecDeque,
    sync::{atomic::Ordering, Arc, Condvar, Mutex},
    time::{Duration, Instant},
};

const QUEUE: usize = 8;
const PACKET: usize = 16 * 1024;
#[derive(Default)]
pub struct Control {
    pub inner: Mutex<Policy>,
    changed: Condvar,
}
#[derive(Default)]
pub struct Policy {
    enabled: bool,
    permitted: bool,
    generation: u64,
    format: Option<(u32, u8)>,
    frames: VecDeque<(Instant, Vec<u8>)>,
    dropped: u64,
}
impl Control {
    pub fn enable(&self, enabled: bool) {
        let mut p = self.inner.lock().unwrap();
        if p.enabled != enabled {
            p.enabled = enabled;
            p.generation += 1;
            p.frames.clear();
            self.changed.notify_one();
        }
    }
    pub fn permit(&self, permitted: bool) {
        let mut p = self.inner.lock().unwrap();
        if p.permitted != permitted {
            p.permitted = permitted;
            // Revocation requires a new explicit enable after permission returns.
            if !permitted {
                p.enabled = false;
            }
            p.generation += 1;
            p.frames.clear();
            self.changed.notify_one();
        }
    }
}
pub struct Sender {
    state: Option<Arc<State>>,
}
impl Sender {
    pub fn start() -> Self {
        let state = super::viewer::CURRENT.get().cloned();
        if state
            .as_ref()
            .is_some_and(|s| s.file_only.load(Ordering::Acquire))
        {
            return Self { state: None };
        }
        if let Some(state) = state.clone() {
            let copy = state.clone();
            if let Err(error) = std::thread::Builder::new()
                .name("viewer-audio".into())
                .spawn(move || run(copy))
            {
                report(&state, "unavailable", &error.to_string(), 0);
            }
        }
        Self { state }
    }
    pub fn send(&self, data: MediaData) -> Result<(), ()> {
        let Some(state) = &self.state else {
            return Err(());
        };
        let mut p = state.audio.inner.lock().unwrap();
        match data {
            MediaData::AudioFormat(format) => {
                let valid = matches!(format.sample_rate, 8000 | 12000 | 16000 | 24000 | 48000)
                    && matches!(format.channels, 1 | 2);
                let format = valid.then_some((format.sample_rate, format.channels as u8));
                if p.format != format {
                    p.format = format;
                    p.generation += 1;
                    p.frames.clear();
                    state.audio.changed.notify_one();
                }
                if !valid {
                    drop(p);
                    report(state, "unavailable", "远端音频格式不受支持", 0);
                }
            }
            MediaData::AudioFrame(frame) if p.enabled && p.permitted && p.format.is_some() => {
                if frame.data.is_empty() || frame.data.len() > PACKET {
                    p.dropped += 1;
                    return Err(());
                }
                if p.frames.len() == QUEUE {
                    p.frames.pop_front();
                    p.dropped += 1;
                }
                p.frames.push_back((Instant::now(), frame.data.to_vec()));
            }
            _ => {}
        }
        Ok(())
    }
}
fn report(state: &State, status: &str, detail: &str, dropped: u64) {
    state.emit(EventKind::Audio {
        status: status.into(),
        detail: detail.chars().take(256).collect(),
        dropped,
    });
}
fn run(state: Arc<State>) {
    let mut generation = None;
    while !state.stopped.load(Ordering::Acquire) {
        let (current, active, format, dropped) = {
            let p = state.audio.inner.lock().unwrap();
            (p.generation, p.enabled && p.permitted, p.format, p.dropped)
        };
        if generation != Some(current) {
            generation = Some(current);
            if active {
                if let Some(format) = format {
                    report(&state, "starting", "正在打开音频输出", dropped);
                    if let Err(error) = play(&state, current, format) {
                        state.audio.inner.lock().unwrap().frames.clear();
                        report(
                            &state,
                            "unavailable",
                            &format!("音频不可用：{error}；可关闭后重试"),
                            dropped,
                        );
                    }
                } else {
                    report(&state, "waiting", "等待远端音频", dropped);
                }
            } else {
                report(&state, "disabled", "音频已关闭", dropped);
            }
        }
        let p = state.audio.inner.lock().unwrap();
        if Some(p.generation) == generation {
            let _ = state
                .audio
                .changed
                .wait_timeout(p, Duration::from_millis(100))
                .unwrap();
        }
    }
}
fn play(state: &State, generation: u64, (rate, channels): (u32, u8)) -> ResultType<()> {
    let cancelled = || {
        state.stopped.load(Ordering::Acquire)
            || state.audio.inner.lock().unwrap().generation != generation
    };
    let mut connection = audio::Connection::open(&cancelled)?;
    let mut stream = connection.stream(rate, channels, None, &cancelled)?;
    let mut decoder = Decoder::new(
        rate,
        if channels == 1 {
            Channels::Mono
        } else {
            Channels::Stereo
        },
    )?;
    // Opus maximum packet duration is 120 ms. Allocation does not follow peer sizes.
    let mut decoded = vec![0f32; rate as usize * channels as usize * 120 / 1000];
    let mut pending = Vec::<u8>::with_capacity(decoded.len() * 4);
    let mut offset = 0;
    let mut pending_at = Instant::now();
    let mut reported = false;
    while !cancelled() {
        connection.tick()?;
        if stream.get_state() != pulse::stream::State::Ready {
            bail!("Audio output disconnected");
        }
        if offset == pending.len() {
            pending.clear();
            offset = 0;
            let frame = {
                let mut p = state.audio.inner.lock().unwrap();
                while p
                    .frames
                    .front()
                    .is_some_and(|(at, _)| at.elapsed() > Duration::from_millis(150))
                {
                    p.frames.pop_front();
                    p.dropped += 1;
                }
                p.frames.pop_front()
            };
            if let Some((_, bytes)) = frame {
                let n = decoder.decode_float(&bytes, &mut decoded, false)? * channels as usize;
                for sample in &decoded[..n] {
                    pending.extend_from_slice(&sample.to_le_bytes());
                }
                pending_at = Instant::now();
            }
        }
        if offset < pending.len() {
            if pending_at.elapsed() > Duration::from_millis(250) {
                bail!("Audio output stalled");
            }
            let writable = stream
                .writable_size()
                .ok_or_else(|| hbb_common::anyhow::anyhow!("Audio output failed"))?;
            let unit = channels as usize * 4;
            let n = writable.min(pending.len() - offset) / unit * unit;
            if n > 0 {
                // Serialize permission/enable changes against the final nonblocking write.
                let p = state.audio.inner.lock().unwrap();
                if p.generation != generation {
                    break;
                }
                stream.write_copy(
                    &pending[offset..offset + n],
                    0,
                    pulse::stream::SeekMode::Relative,
                )?;
                offset += n;
                if !reported {
                    report(state, "playing", "正在播放远端音频", p.dropped);
                    reported = true;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    // Disconnect instead of drain: disabling must not play the queued tail.
    stream.disconnect().ok();
    connection.tick().ok();
    Ok(())
}
