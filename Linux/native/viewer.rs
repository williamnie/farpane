//! Disposable out-bound session. Never enters core_main, CM, Host, or the tray.
use super::{viewer_media, viewer_ui::NativeUi};
use crate::{
    client::{Data, Interface},
    ui_session_interface::Session,
};
use farpane_protocol::{
    frame_socket, transport, Command, Display, Event, EventKind, Metrics, Permissions, Phase,
    Request,
};
use hbb_common::{bail, ResultType};
use std::{
    collections::VecDeque,
    os::fd::AsRawFd,
    sync::{
        atomic::{AtomicBool, AtomicI32, AtomicU64, AtomicU8, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

pub static CURRENT: OnceLock<Arc<State>> = OnceLock::new();
pub struct State {
    pub generation: AtomicU64,
    pub authenticated: AtomicBool,
    pub file_only: AtomicBool,
    pub files: Mutex<Option<super::file_viewer::Link>>,
    pub auth_challenge: AtomicU8,
    pub stopped: AtomicBool,
    pub selected: AtomicI32,
    pub permissions: Mutex<Permissions>,
    pub displays: Mutex<Vec<Display>>,
    pub metrics: Mutex<Metrics>,
    pub metrics_enabled: AtomicBool,
    pub resources: farpane_protocol::telemetry::Monitor,
    pub delay_at: Mutex<Option<Instant>>,
    pub media_deadline: AtomicU64,
    pub started: Instant,
    pub phase: Mutex<(Phase, String)>,
    pub fault: Mutex<Option<String>>,
    pub command_budget: Arc<Mutex<super::viewer_queue::Budget>>,
    pub clipboard_budget: Arc<Mutex<super::viewer_queue::Budget>>,
    pub input: Mutex<super::viewer_input::State>,
    pub release_input: AtomicBool,
    pub clipboard: Mutex<super::viewer_clipboard::Policy>,
    pub cursor_premultiplied: AtomicBool,
    pub audio: super::viewer_audio::Control,
    events: Mutex<VecDeque<(u64, EventKind)>>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            generation: AtomicU64::new(1),
            authenticated: AtomicBool::new(false),
            file_only: AtomicBool::new(false),
            files: Mutex::new(None),
            auth_challenge: AtomicU8::new(0),
            stopped: AtomicBool::new(false),
            selected: AtomicI32::new(-1),
            permissions: Mutex::new(Permissions {
                keyboard: true,
                clipboard: true,
                audio: true,
                file: true,
            }),
            displays: Mutex::new(Vec::new()),
            metrics: Mutex::new(Metrics::default()),
            metrics_enabled: AtomicBool::new(false),
            resources: Default::default(),
            delay_at: Mutex::new(None),
            media_deadline: AtomicU64::new(0),
            started: Instant::now(),
            phase: Mutex::new((Phase::Connecting, String::new())),
            fault: Mutex::new(None),
            command_budget: Arc::new(Mutex::new(super::viewer_queue::Budget::default())),
            clipboard_budget: Arc::new(Mutex::new(super::viewer_queue::Budget::default())),
            input: Mutex::new(super::viewer_input::State::default()),
            release_input: AtomicBool::new(false),
            clipboard: Mutex::new(super::viewer_clipboard::Policy::default()),
            cursor_premultiplied: AtomicBool::new(false),
            audio: Default::default(),
            events: Mutex::new(VecDeque::new()),
        }
    }
}
impl State {
    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }
    pub fn emit(&self, event: EventKind) {
        self.emit_at(0, event);
    }
    pub fn emit_at(&self, generation: u64, event: EventKind) {
        let mut events = self.events.lock().unwrap();
        let generation = if generation == 0 {
            self.generation()
        } else {
            generation
        };
        if generation < self.generation() {
            return;
        }
        let metrics = matches!(&event, EventKind::Metrics(_));
        if !farpane_protocol::event_queue::admit(&mut events, metrics, |(_, event)| {
            matches!(event, EventKind::Metrics(_))
        }) {
            drop(events);
            if !metrics {
                self.fail("Viewer event queue exceeded its limit");
            }
            return;
        }
        events.push_back((generation, event));
    }
    pub fn advance_generation(&self) -> ResultType<u64> {
        let _events = self.events.lock().unwrap();
        let next = self
            .generation()
            .checked_add(1)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Viewer generation exhausted"))?;
        self.generation.store(next, Ordering::Release);
        Ok(next)
    }
    pub fn fail(&self, message: &str) {
        let mut fault = self.fault.lock().unwrap();
        if fault.is_none() {
            *fault = Some(message.chars().take(512).collect());
        }
        self.stopped.store(true, Ordering::Release);
    }
    pub fn phase(&self, phase: Phase, detail: &str) {
        let detail: String = detail.chars().take(512).collect();
        *self.phase.lock().unwrap() = (phase, detail.clone());
        self.emit(EventKind::Phase { phase, detail });
    }
    pub fn media_call(&self, deadline: Duration) {
        self.media_deadline.store(
            self.started.elapsed().as_millis() as u64 + deadline.as_millis() as u64,
            Ordering::Release,
        );
    }
    pub fn media_idle(&self) {
        self.media_deadline.store(0, Ordering::Release);
    }
}

pub fn run(id: u64) -> ResultType<()> {
    let mut stream = super::control::viewer_parent(id)?;
    let frames = frame_socket::receive_channel(&stream)?;
    let first: Request = transport::receive(&mut stream, Duration::from_secs(3))?;
    if first.id != 1 || first.session != id || first.generation != 0 {
        bail!("Invalid Viewer first request");
    }
    let Command::Connect {
        peer,
        file_only,
        password,
        receive_audio,
        force_relay,
        configuration,
        renderer,
    } = first.command
    else {
        bail!("Viewer requires Connect as its first command");
    };
    if peer.is_empty()
        || peer.len() > 256
        || peer.chars().any(char::is_control)
        || password.0.len() > 4096
        || renderer.formats.len() > 256
    {
        bail!("Invalid Viewer connection parameters");
    }
    let clipboard_channel = if file_only {
        None
    } else {
        Some(farpane_protocol::clipboard_socket::Channel::receive_channel(&stream)?)
    };
    hbb_common::config::farpane_viewer::seed(
        configuration.local_id,
        configuration.server.rendezvous,
        configuration.server.relay,
        configuration.server.public_key,
        configuration.server.force_relay,
    )?;
    let state = Arc::new(State::default());
    state.file_only.store(file_only, Ordering::Release);
    CURRENT
        .set(state.clone())
        .map_err(|_| hbb_common::anyhow::anyhow!("Viewer role already started"))?;
    state.audio.permit(!file_only);
    state.audio.enable(receive_audio && !file_only);
    let (media, _file_channel) = if file_only {
        (None, Some(frames))
    } else {
        (
            Some(viewer_media::start(frames, renderer, state.clone())?),
            None,
        )
    };
    let session = Session {
        password: password.0,
        ui_handler: NativeUi(state.clone()),
        ..Default::default()
    };
    session.lc.write().unwrap().initialize(
        peer,
        if file_only {
            hbb_common::rendezvous_proto::ConnType::FILE_TRANSFER
        } else {
            hbb_common::rendezvous_proto::ConnType::DEFAULT_CONN
        },
        None,
        force_relay || configuration.server.force_relay,
        None,
        None,
        None,
    );
    {
        let mut lc = session.lc.write().unwrap();
        let preferences = lc.get_config();
        preferences.disable_audio.v = !receive_audio;
        preferences.disable_clipboard.v = true;
        preferences.enable_file_copy_paste.v = false;
        preferences.lock_after_session_end.v = false;
        preferences.show_remote_cursor.v = true;
        preferences.options.insert("custom-fps".into(), "30".into());
        preferences.password.clear();
    }
    *session.server_keyboard_enabled.write().unwrap() = true;
    *session.server_file_transfer_enabled.write().unwrap() = true;
    *session.server_clipboard_enabled.write().unwrap() = true;
    if let Some(channel) = clipboard_channel {
        super::viewer_clipboard::start(channel, state.clone(), session.clone())?;
    }
    if file_only {
        *state.files.lock().unwrap() = Some(super::file_viewer::Link::start(
            state.clone(),
            session.clone(),
        )?);
    }
    state.emit(EventKind::Reply {
        request: 1,
        revision: 0,
        error: None,
    });
    state.phase(Phase::Connecting, "正在建立远程连接");
    let network_session = session.clone();
    let network_state = state.clone();
    let network = std::thread::Builder::new()
        .name("viewer-network".into())
        .spawn(move || {
            crate::ui_session_interface::io_loop(network_session, 0);
            if !network_state.stopped.load(Ordering::Acquire)
                && network_state.phase.lock().unwrap().0 != Phase::Failed
            {
                network_state.phase(Phase::Ended, "连接已结束");
            }
            network_state.stopped.store(true, Ordering::Release);
        })?;
    let mut sequence = 0;
    let mut request_id = 1;
    let mut metrics_at = Instant::now();
    let mut previous_metrics = None::<Metrics>;
    let mut rate_at = Instant::now();
    let mut rate = 0;
    let mut input_rate = 0;
    let mut input_generation = state.generation();
    let result: ResultType<()> = (|| {
        loop {
            super::viewer_clipboard::report(&state);
            if state.release_input.swap(false, Ordering::AcqRel)
                || input_generation != state.generation()
            {
                send_input(&session, &state, farpane_protocol::Input::ReleaseAll)?;
                input_generation = state.generation();
            }
            let deadline = state.media_deadline.load(Ordering::Acquire);
            if deadline != 0 && state.started.elapsed().as_millis() as u64 > deadline {
                state.fail("Viewer media operation exceeded its deadline");
            }
            if let Some(error) = state.fault.lock().unwrap().take() {
                sequence += 1;
                transport::send(
                    &mut stream,
                    &Event {
                        sequence,
                        session: id,
                        generation: state.generation(),
                        event: EventKind::Phase {
                            phase: Phase::Failed,
                            detail: error,
                        },
                    },
                    Duration::from_secs(1),
                )?;
                break;
            }
            // Observe shutdown before draining: the network thread queues its
            // terminal status before publishing stopped, and it must reach GUI.
            let stopping = state.stopped.load(Ordering::Acquire);
            let events = std::mem::take(&mut *state.events.lock().unwrap());
            for (generation, event) in events {
                sequence += 1;
                transport::send(
                    &mut stream,
                    &Event {
                        sequence,
                        session: id,
                        generation,
                        event,
                    },
                    Duration::from_secs(1),
                )?;
            }
            if stopping {
                break;
            }
            if state.metrics_enabled.load(Ordering::Acquire) {
                if previous_metrics.is_none() {
                    previous_metrics = Some(state.metrics.lock().unwrap().clone());
                    metrics_at = Instant::now();
                } else if metrics_at.elapsed() >= Duration::from_secs(1) {
                    let mut current = state.metrics.lock().unwrap().clone();
                    let previous = previous_metrics.as_ref().unwrap();
                    let seconds = metrics_at.elapsed().as_secs_f32();
                    current.packet_rate = Some(
                        current
                            .received_packets
                            .saturating_sub(previous.received_packets)
                            as f32
                            / seconds,
                    );
                    current.decode_fps = Some(
                        current
                            .decoded_frames
                            .saturating_sub(previous.decoded_frames) as f32
                            / seconds,
                    );
                    current.receive_kib_per_sec = Some(
                        current
                            .received_bytes
                            .saturating_sub(previous.received_bytes) as f32
                            / (seconds * 1024.0),
                    );
                    let decoded = current
                        .decoded_frames
                        .saturating_sub(previous.decoded_frames);
                    current.decode_ms = if decoded > 0 {
                        Some(
                            current
                                .decode_call_ns
                                .saturating_sub(previous.decode_call_ns)
                                as f32
                                / (decoded as f32 * 1_000_000.0),
                        )
                    } else {
                        None
                    };
                    current.delay_age_ms = state
                        .delay_at
                        .lock()
                        .unwrap()
                        .map(|at| at.elapsed().as_millis() as u64);
                    if current.delay_age_ms.is_none_or(|age| age > 15_000) {
                        current.delay_ms = None;
                    }
                    (current.queue_bytes, current.queued_groups) = viewer_media::gauges();
                    current.resources = state.resources.snapshot();
                    previous_metrics = Some(current.clone());
                    metrics_at = Instant::now();
                    state.emit(EventKind::Metrics(current));
                }
            } else {
                previous_metrics = None;
            }
            let mut descriptor = hbb_common::libc::pollfd {
                fd: stream.as_raw_fd(),
                events: hbb_common::libc::POLLIN,
                revents: 0,
            };
            let ready = unsafe { hbb_common::libc::poll(&mut descriptor, 1, 20) };
            if ready < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            if ready == 0 {
                continue;
            }
            let request: Request = transport::receive(&mut stream, Duration::from_secs(2))?;
            if request.id <= request_id
                || request.session != id
                || request.generation > state.generation()
            {
                bail!("Stale Viewer command");
            }
            request_id = request.id;
            if rate_at.elapsed() > Duration::from_secs(1) {
                rate = 0;
                input_rate = 0;
                rate_at = Instant::now();
            }
            if matches!(request.command, Command::Input(_)) {
                input_rate += 1;
            } else {
                rate += 1;
            }
            if rate > 32 || input_rate > 512 {
                bail!("Viewer command rate exceeded");
            }
            let result = if request.generation != state.generation()
                && !matches!(
                    request.command,
                    Command::Disconnect
                        | Command::Snapshot
                        | Command::Subscribe
                        | Command::Input(farpane_protocol::Input::ReleaseAll)
                ) {
                Err(hbb_common::anyhow::anyhow!("显示状态已变化，请重试操作"))
            } else {
                command(&session, &state, request.command)
            };
            state.emit(EventKind::Reply {
                request: request_id,
                revision: 0,
                error: result.err().map(|e| e.to_string()),
            });
        }
        Ok(())
    })();
    let _ = send_input(&session, &state, farpane_protocol::Input::ReleaseAll);
    session.send(Data::Close);
    state.stopped.store(true, Ordering::Release);
    super::viewer_clipboard::stop();
    let deadline = Instant::now() + Duration::from_millis(500);
    let files = state.files.lock().unwrap().take();
    if let Some(files) = files {
        files.finish();
    }
    while (!network.is_finished() || media.as_ref().is_some_and(|m| !m.is_finished()))
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(5));
    }
    if network.is_finished() {
        let _ = network.join();
    }
    if let Some(media) = media.filter(|m| m.is_finished()) {
        let _ = media.join();
    }
    // Returning from this role ends this disposable process. A wedged decoder
    // cannot be reused; the GUI must confirm process exit before another attempt.
    result
}

fn command(session: &Session<NativeUi>, state: &State, command: Command) -> ResultType<()> {
    use farpane_protocol::Role;
    if !command.allowed_for(Role::Viewer) {
        bail!("Viewer cannot manage the Host");
    }
    if state.file_only.load(Ordering::Acquire) && state.authenticated.load(Ordering::Acquire) {
        if matches!(
            command,
            Command::ListDirectory { .. }
                | Command::Transfer { .. }
                | Command::TransferFiles { .. }
                | Command::CancelTransfer { .. }
                | Command::ConfirmTransfer { .. }
        ) {
            return state
                .files
                .lock()
                .unwrap()
                .as_ref()
                .ok_or_else(|| hbb_common::anyhow::anyhow!("File worker ended"))?
                .command(command);
        }
        if !matches!(
            command,
            Command::Disconnect | Command::Snapshot | Command::Subscribe | Command::Metrics { .. }
        ) {
            bail!("This is a file-only session");
        }
    }
    match command {
        Command::Password { password } => {
            if password.0.len() > 4096
                || state
                    .auth_challenge
                    .compare_exchange(1, 0, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
            {
                bail!("No password challenge is pending");
            }
            session.login(String::new(), String::new(), password.0, false);
            state.phase(Phase::Authenticating, "正在验证密码");
        }
        Command::TwoFactor { code } => {
            if code.0.is_empty() || code.0.len() > 16 || !code.0.bytes().all(|b| b.is_ascii_digit())
            {
                bail!("Invalid verification code");
            }
            if state
                .auth_challenge
                .compare_exchange(2, 0, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
            {
                bail!("No verification challenge is pending");
            }
            session.send2fa(code.0, false);
        }
        Command::ConfirmInsecure { accept } => {
            if state
                .auth_challenge
                .compare_exchange(3, 0, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
            {
                bail!("No insecure connection challenge is pending");
            }
            session.continue_insecure_connection(accept);
        }
        Command::Disconnect => {
            state.phase(Phase::Ended, "已断开");
            state.stopped.store(true, Ordering::Release);
        }
        Command::Snapshot | Command::Subscribe => {
            let (phase, detail) = state.phase.lock().unwrap().clone();
            state.emit(EventKind::Phase { phase, detail });
            state.emit(EventKind::Permissions(
                state.permissions.lock().unwrap().clone(),
            ));
            state.emit(EventKind::Displays {
                displays: state.displays.lock().unwrap().clone(),
                selected: state.selected.load(Ordering::Acquire),
            });
        }
        Command::RefreshFrame if state.authenticated.load(Ordering::Acquire) => {
            session.refresh_video(state.selected.load(Ordering::Acquire))
        }
        Command::SelectDisplay { index } if state.authenticated.load(Ordering::Acquire) => {
            if !state
                .displays
                .lock()
                .unwrap()
                .iter()
                .any(|d| d.index == index)
            {
                bail!("Display is unavailable");
            }
            send_input(session, state, farpane_protocol::Input::ReleaseAll)?;
            session.switch_display(index);
        }
        Command::SetAudio { enabled } if state.authenticated.load(Ordering::Acquire) => {
            if enabled && !state.permissions.lock().unwrap().audio {
                bail!("Remote audio permission is disabled");
            }
            state.audio.enable(enabled);
            if session.get_toggle_option("disable-audio".into()) == enabled {
                session.toggle_option("disable-audio".into());
            }
        }
        Command::Metrics { enabled } => {
            state.metrics_enabled.store(enabled, Ordering::Release);
            state.resources.enable(enabled);
        }
        Command::Input(input) if state.authenticated.load(Ordering::Acquire) => {
            if !matches!(input, farpane_protocol::Input::ReleaseAll)
                && !state.permissions.lock().unwrap().keyboard
            {
                bail!("Remote input permission is disabled");
            }
            send_input(session, state, input)?;
        }
        Command::SetClipboard { policy } if state.authenticated.load(Ordering::Acquire) => {
            super::viewer_clipboard::configure(session, state, policy)?
        }
        Command::Retry => bail!("Retry requires this worker to exit before a new attempt"),
        _ => bail!("Viewer command is not available in this development build"),
    }
    Ok(())
}

fn send_input(
    session: &Session<NativeUi>,
    state: &State,
    input: farpane_protocol::Input,
) -> ResultType<()> {
    let display = state
        .displays
        .lock()
        .unwrap()
        .iter()
        .find(|d| d.index == state.selected.load(Ordering::Acquire))
        .cloned();
    let messages = state
        .input
        .lock()
        .unwrap()
        .translate(input, display.as_ref())?;
    for message in messages {
        session.send(Data::Message(message));
    }
    Ok(())
}
