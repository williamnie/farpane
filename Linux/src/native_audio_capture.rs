//! Included only in the native Linux Host audio service.
use super::*;
use crate::farpane_native::audio;
use pulse::stream::{PeekResult, State};
use std::time::{Duration, Instant};

pub fn run(sp: EmptyExtraFieldService) -> ResultType<()> {
    let result = capture(&sp);
    audio::capture_status(match &result {
        Ok(_) => "空闲",
        Err(_) => "音频采集不可用，请检查选择的设备",
    });
    result
}
fn capture(sp: &EmptyExtraFieldService) -> ResultType<()> {
    RESTARTING.store(false, Ordering::SeqCst);
    let cancelled = || {
        !sp.ok()
            || RESTARTING.load(Ordering::SeqCst)
            || !crate::Connection::is_permission_enabled_locally("enable-audio")
    };
    if cancelled() {
        return Ok(());
    }
    if audio::needs_source_selection() {
        bail!("Reselect the audio source imported from the previous version before sharing audio");
    }
    let mut connection = audio::Connection::open(&cancelled)?;
    let sources = connection.sources()?;
    let selected = Config::get_option("farpane-audio-source");
    let microphone = Config::get_option("farpane-audio-microphone") == "Y";
    let source = sources
        .iter()
        .find(|s| {
            if selected.is_empty() {
                !s.microphone
            } else {
                s.id == selected
            }
        })
        .ok_or_else(|| {
            hbb_common::anyhow::anyhow!(
                "Selected audio source is unavailable; no microphone fallback"
            )
        })?;
    if source.microphone && !microphone {
        bail!("Microphone capture requires explicit consent");
    }
    let mut stream = connection.stream(48000, 2, Some(&source.id), &cancelled)?;
    let mut encoder = AudioEncoder::new(Encoder::new(48000, Stereo, LowDelay)?);
    let mut frame = Vec::<f32>::with_capacity(960);
    let mut last_data = Instant::now();
    audio::capture_status(if source.microphone {
        "正在共享麦克风"
    } else {
        "正在共享系统音频"
    });
    while !cancelled() {
        connection.tick()?;
        if stream.get_state() != State::Ready {
            bail!("Audio source disconnected");
        }
        sp.snapshot(|sps| {
            sps.send(create_format_msg(48000, 2));
            Ok(())
        })?;
        let consumed = match stream.peek()? {
            PeekResult::Empty => false,
            PeekResult::Hole(_) => {
                frame.clear();
                true
            }
            PeekResult::Data(bytes) => {
                if bytes.len() > 48000 * 2 * 4 / 5 || bytes.len() % 4 != 0 {
                    bail!("Audio capture fragment exceeds bounds");
                }
                for bytes in bytes.chunks_exact(4) {
                    frame.push(f32::from_le_bytes(bytes.try_into().unwrap()));
                    if frame.len() == 960 {
                        if cancelled() {
                            return Ok(());
                        }
                        send_f32(&frame, &mut encoder, sp);
                        frame.clear();
                    }
                }
                true
            }
        };
        if consumed {
            stream.discard()?;
            last_data = Instant::now();
        } else if last_data.elapsed() > Duration::from_secs(3) {
            bail!("Audio capture stalled");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    stream.disconnect().ok();
    Ok(())
}
