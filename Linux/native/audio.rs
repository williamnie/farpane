//! Nonblocking PulseAudio-compatible transport, confined to its owning thread.
//! No autospawn, default microphone, legacy CM IPC, or synchronous audio reads.
use hbb_common::{anyhow::anyhow, bail, ResultType};
use pulse::{
    context,
    context::Context,
    mainloop::standard::{IterateResult, Mainloop},
    stream,
};
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

pub struct Connection {
    // Drop context before the mainloop whose API it references.
    pub context: Context,
    mainloop: Mainloop,
}
impl Connection {
    pub fn open(cancel: impl Fn() -> bool) -> ResultType<Self> {
        if cancel() {
            bail!("Audio connection cancelled");
        }
        let mainloop = Mainloop::new().ok_or_else(|| anyhow!("Audio mainloop unavailable"))?;
        let mut context = Context::new(&mainloop, "FarPane")
            .ok_or_else(|| anyhow!("Audio context unavailable"))?;
        context.connect(None, context::FlagSet::NOAUTOSPAWN, None)?;
        let mut this = Self { context, mainloop };
        let deadline = Instant::now() + Duration::from_secs(2);
        while this.context.get_state() != context::State::Ready {
            this.tick()?;
            if cancel() || Instant::now() >= deadline {
                bail!("Audio connection cancelled or timed out");
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Ok(this)
    }
    pub fn tick(&mut self) -> ResultType<()> {
        match self.mainloop.iterate(false) {
            IterateResult::Success(_) => {}
            _ => bail!("Audio event loop ended"),
        }
        if matches!(
            self.context.get_state(),
            context::State::Failed | context::State::Terminated
        ) {
            bail!("Audio service disconnected");
        }
        Ok(())
    }
    pub fn sources(&mut self) -> ResultType<Vec<farpane_protocol::AudioSource>> {
        use pulse::callbacks::ListResult;
        let result = Rc::new(RefCell::new((Vec::new(), false)));
        let copy = result.clone();
        let mut operation = self.context.introspect().get_source_info_list(move |info| {
            let mut result = copy.borrow_mut();
            match info {
                ListResult::Item(info) => {
                    if result.0.len() >= 64 {
                        result.1 = true;
                        return;
                    }
                    let id = info.name.as_deref().unwrap_or_default();
                    if id.is_empty() || id.len() > 512 || id.chars().any(char::is_control) {
                        return;
                    }
                    let name: String = info
                        .description
                        .as_deref()
                        .unwrap_or(id)
                        .chars()
                        .take(160)
                        .collect();
                    let bytes: usize = result
                        .0
                        .iter()
                        .map(|s: &farpane_protocol::AudioSource| s.id.len() + s.name.len())
                        .sum();
                    if bytes + id.len() + name.len() > 12 * 1024 {
                        result.1 = true;
                        return;
                    }
                    result.0.push(farpane_protocol::AudioSource {
                        id: id.into(),
                        name,
                        microphone: info.monitor_of_sink.is_none(),
                    });
                }
                ListResult::Error => result.1 = true,
                ListResult::End => {}
            }
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while operation.get_state() == pulse::operation::State::Running {
            if Instant::now() >= deadline {
                operation.cancel();
                bail!("Audio source query timed out");
            }
            self.tick()?;
            std::thread::sleep(Duration::from_millis(5));
        }
        let mut result = result.borrow_mut();
        if result.1 {
            bail!("Audio source query failed or exceeds 64 devices");
        }
        Ok(std::mem::take(&mut result.0))
    }
    pub fn stream(
        &mut self,
        rate: u32,
        channels: u8,
        source: Option<&str>,
        cancel: impl Fn() -> bool,
    ) -> ResultType<stream::Stream> {
        let spec = pulse::sample::Spec {
            format: pulse::sample::Format::F32le,
            channels,
            rate,
        };
        if !spec.is_valid() {
            bail!("Invalid audio sample format");
        }
        if cancel() {
            bail!("Audio stream cancelled");
        }
        let record = source.is_some();
        let mut stream = stream::Stream::new(
            &mut self.context,
            if record {
                "FarPane system capture"
            } else {
                "FarPane remote playback"
            },
            &spec,
            None,
        )
        .ok_or_else(|| anyhow!("Audio stream unavailable"))?;
        let bytes_10ms = rate / 100 * channels as u32 * 4;
        let attr = pulse::def::BufferAttr {
            maxlength: bytes_10ms * 20,
            tlength: bytes_10ms * 4,
            // Zero enables manual corking and loses writes behind the read index after underrun.
            prebuf: bytes_10ms * 2,
            minreq: bytes_10ms,
            fragsize: bytes_10ms,
        };
        let flags = stream::FlagSet::ADJUST_LATENCY | stream::FlagSet::DONT_MOVE;
        if record {
            stream.connect_record(source, Some(&attr), flags)?;
        } else {
            stream.connect_playback(None, Some(&attr), flags, None, None)?;
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while stream.get_state() != stream::State::Ready {
            self.tick()?;
            if matches!(
                stream.get_state(),
                stream::State::Failed | stream::State::Terminated
            ) || cancel()
                || Instant::now() >= deadline
            {
                bail!("Audio stream failed, cancelled or timed out");
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Ok(stream)
    }
}
impl Drop for Connection {
    fn drop(&mut self) {
        self.context.disconnect();
    }
}

#[derive(Default, Clone)]
pub struct Status {
    pub sources: Vec<farpane_protocol::AudioSource>,
    pub error: String,
    pub capture: String,
}
static STATUS: OnceLock<Mutex<Status>> = OnceLock::new();
pub fn status() -> Status {
    STATUS.get_or_init(Default::default).lock().unwrap().clone()
}
pub fn capture_status(detail: &str) {
    let mut state = STATUS.get_or_init(Default::default).lock().unwrap();
    let detail: String = detail.chars().take(256).collect();
    if state.capture != detail {
        state.capture = detail;
        drop(state);
        super::control::changed();
    }
}
pub fn start_catalog() -> ResultType<()> {
    std::thread::Builder::new()
        .name("audio-catalog".into())
        .spawn(|| loop {
            let result = Connection::open(|| false).and_then(|mut c| c.sources());
            let (sources, error) = match result {
                Ok(s) => (s, String::new()),
                Err(e) => (vec![], e.to_string()),
            };
            let mut state = STATUS.get_or_init(Default::default).lock().unwrap();
            let changed = state.sources != sources || state.error != error;
            state.sources = sources;
            state.error = error;
            drop(state);
            if changed {
                super::control::changed();
            }
            std::thread::sleep(Duration::from_secs(5));
        })?;
    Ok(())
}

/// Old versions stored a device description, not a stable source ID. Never
/// silently reinterpret that explicit selection as the default monitor/mic.
pub fn needs_source_selection() -> bool {
    let options = hbb_common::config::Config::get_options();
    options.get("farpane-audio-choice").map(String::as_str) != Some("1")
        && !options.contains_key("farpane-audio-source")
        && options
            .get("audio-input")
            .is_some_and(|value| !value.is_empty())
}
