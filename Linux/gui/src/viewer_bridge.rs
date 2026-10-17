//! A disposable, authenticated Viewer process. GTK never waits for it to exit.
use crate::bridge::Release;
use farpane_protocol::{
    frame_socket::{self, Channel, Packet},
    transport, Command, Event, EventKind, Hello, Renderer, Request, Role, Secret,
    ViewerConfiguration, VERSION,
};
use std::{
    collections::{HashSet, VecDeque},
    io::{self, Read},
    os::{
        fd::{AsRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    process::{Child, Command as Process, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
const DEADLINE: Duration = Duration::from_secs(3);

pub struct Frame {
    pub packet: Packet,
    pub files: Vec<OwnedFd>,
    channel: Arc<Channel>,
    pub received: Instant,
    skipped: Arc<AtomicU64>,
}
impl Frame {
    pub fn generation(&self) -> u64 {
        match &self.packet {
            Packet::DmaBuf(f) => f.generation,
            Packet::Software(f) => f.generation,
            _ => unreachable!(),
        }
    }
    pub fn discard(&self) -> io::Result<()> {
        self.skipped.fetch_add(1, Ordering::Relaxed);
        self.release()
    }
    // Call only before import, after copying immutable pixels, or after an actual
    // GPU completion fence. Drop/HUP alone must NEVER acknowledge a GPU lease.
    pub fn release(&self) -> io::Result<()> {
        let (generation, lease) = match &self.packet {
            Packet::DmaBuf(f) => (f.generation, f.lease),
            Packet::Software(f) => (f.generation, f.lease),
            _ => unreachable!(),
        };
        self.channel
            .send(&Packet::Release { generation, lease }, &[])
    }
}

#[derive(Default)]
pub struct Update {
    pub events: VecDeque<Event>,
    pub frame: Option<Frame>,
    pub error: Option<String>,
    pub exited: bool,
}
pub struct Bridge {
    pub session: u64,
    commands: Arc<Mutex<VecDeque<Command>>>,
    updates: Arc<Mutex<Update>>,
    stop: Arc<AtomicBool>,
    renderer: Arc<Mutex<Option<Renderer>>>,
    skipped: Arc<AtomicU64>,
    pub clipboard: Option<Arc<farpane_protocol::clipboard_link::Link>>,
}
impl Bridge {
    pub fn start(peer: String, audio: bool, configuration: ViewerConfiguration) -> Result<Self> {
        Self::start_mode(peer, audio, configuration, false)
    }
    pub fn start_files(peer: String, configuration: ViewerConfiguration) -> Result<Self> {
        Self::start_mode(peer, false, configuration, true)
    }
    fn start_mode(
        peer: String,
        audio: bool,
        configuration: ViewerConfiguration,
        file_only: bool,
    ) -> Result<Self> {
        let mut bytes = [0; 8];
        std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
        let session = u64::from_ne_bytes(bytes).max(1);
        let commands = Arc::new(Mutex::new(VecDeque::new()));
        let queue = commands.clone();
        let updates = Arc::new(Mutex::new(Update::default()));
        let output = updates.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let skipped = Arc::new(AtomicU64::new(0));
        let skipped_worker = skipped.clone();
        let renderer = Arc::new(Mutex::new(None));
        let renderer_ready = renderer.clone();
        let clipboard = if file_only {
            None
        } else {
            Some(farpane_protocol::clipboard_link::Link::new(
                farpane_protocol::clipboard::Direction::Send,
            )?)
        };
        let clipboard_worker = clipboard.clone();
        thread::Builder::new()
            .name("farpane-viewer-control".into())
            .spawn(move || {
                let mut child = None;
                let result = run(
                    session,
                    peer,
                    audio,
                    file_only,
                    configuration,
                    &renderer_ready,
                    &queue,
                    &output,
                    &stopping,
                    &mut child,
                    &skipped_worker,
                    clipboard_worker.as_ref(),
                );
                if let Some(link) = &clipboard_worker {
                    link.stop();
                }
                if let Err(error) = result {
                    if !stopping.load(Ordering::Acquire) {
                        output.lock().unwrap().error = Some(error.to_string());
                    }
                }
                // Retire the private process, never a process selected by name. A
                // blocked kernel task remains owned and prevents retry until reaped.
                if let Some(mut child) = child {
                    let deadline = Instant::now() + Duration::from_millis(700);
                    let mut killed = false;
                    loop {
                        match child.try_wait() {
                            Ok(Some(_)) => break,
                            Ok(None) => {}
                            Err(error) => {
                                output.lock().unwrap().error =
                                    Some(format!("无法确认 Viewer 退出：{error}"));
                                // No successful exit claim on an unknown process state.
                                return;
                            }
                        }
                        if !killed && Instant::now() >= deadline {
                            let _ = child.kill();
                            killed = true;
                        }
                        thread::sleep(Duration::from_millis(25));
                    }
                }
                // Keep retry disabled until this session's large-payload owner
                // has released its memory. GTK never joins a worker thread.
                while clipboard_worker
                    .as_ref()
                    .is_some_and(|link| !link.finished())
                {
                    thread::sleep(Duration::from_millis(10));
                }
                let mut output = output.lock().unwrap();
                output.frame = None;
                output.exited = true;
            })?;
        if file_only {
            *renderer.lock().unwrap() = Some(Renderer::default());
        }
        Ok(Self {
            session,
            commands,
            updates,
            stop,
            renderer,
            skipped,
            clipboard,
        })
    }
    pub fn skipped(&self) -> u64 {
        self.skipped.load(Ordering::Relaxed)
    }
    pub fn renderer_ready(&self, renderer: Renderer) {
        *self.renderer.lock().unwrap() = Some(renderer);
    }
    pub fn send(&self, command: Command) -> Result<()> {
        let mut queue = self.commands.lock().unwrap();
        let motion = |command: &Command| {
            matches!(
                command,
                Command::Input(farpane_protocol::Input::Pointer {
                    action: farpane_protocol::PointerAction::Move,
                    ..
                })
            )
        };
        // Only adjacent motions may collapse. Preserve key/button/scroll order.
        if motion(&command) && queue.back().is_some_and(motion) {
            queue.pop_back();
        }
        if queue.len() == 64 {
            return Err("会话输入队列已满".into());
        }
        queue.push_back(command);
        Ok(())
    }
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
        if let Some(link) = &self.clipboard {
            link.stop();
        }
    }
    pub fn take(&self) -> Update {
        let mut update = self.updates.lock().unwrap();
        Update {
            events: std::mem::take(&mut update.events),
            frame: update.frame.take(),
            error: update.error.take(),
            exited: update.exited,
        }
    }
}
impl Drop for Bridge {
    fn drop(&mut self) {
        self.stop();
    }
}

#[allow(clippy::too_many_arguments)]
fn run(
    session: u64,
    peer: String,
    audio: bool,
    file_only: bool,
    configuration: ViewerConfiguration,
    renderer: &Mutex<Option<Renderer>>,
    commands: &Mutex<VecDeque<Command>>,
    updates: &Mutex<Update>,
    stop: &AtomicBool,
    child: &mut Option<Child>,
    skipped: &Arc<AtomicU64>,
    clipboard: Option<&Arc<farpane_protocol::clipboard_link::Link>>,
) -> Result<()> {
    // Negotiate only after the actual GTK GLArea context is realised. Waiting
    // occurs on this control thread; the GTK thread never waits for IPC.
    let deadline = Instant::now() + Duration::from_secs(8);
    let renderer = loop {
        if stop.load(Ordering::Acquire) {
            return Ok(());
        }
        if let Some(renderer) = renderer.lock().unwrap().take() {
            break renderer;
        }
        if Instant::now() >= deadline {
            return Err("图形后端初始化超时".into());
        }
        thread::sleep(Duration::from_millis(10));
    };
    let release = Release::current()?;
    let (mut stream, child_stream) = UnixStream::pair()?;
    *child = Some(
        Process::new(&release.core)
            .args(["--viewer", &session.to_string()])
            .stdin(Stdio::from(OwnedFd::from(child_stream)))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?,
    );
    transport::send(
        &mut stream,
        &Hello {
            version: VERSION,
            role: Role::Gui,
            release: release.name.clone(),
            session,
        },
        DEADLINE,
    )?;
    let hello: Hello = transport::receive(&mut stream, DEADLINE)?;
    if hello.version != VERSION
        || hello.role != Role::Viewer
        || hello.session != session
        || hello.release != release.name
    {
        return Err("Viewer 与界面版本不一致".into());
    }
    let (frames, worker_frames) = Channel::pair()?;
    frame_socket::send_channel(&stream, &worker_frames)?;
    drop(worker_frames);
    let frames = Arc::new(frames);
    transport::send(
        &mut stream,
        &Request {
            id: 1,
            session,
            generation: 0,
            command: Command::Connect {
                peer,
                file_only,
                password: Secret::default(),
                receive_audio: audio,
                force_relay: configuration.server.force_relay,
                configuration,
                renderer,
            },
        },
        DEADLINE,
    )?;
    if let Some(link) = clipboard {
        let (local, worker) = farpane_protocol::clipboard_socket::Channel::pair()?;
        worker.pass(&stream)?;
        drop(worker);
        let _ = link.start(local, None);
    }
    let mut sequence = 0;
    let mut generation = 0;
    let mut id = 1;
    let mut pending = HashSet::from([1]);
    let mut pending_since = Instant::now();
    let mut last_command = Instant::now() - Duration::from_secs(1);
    let mut frame_closed = None::<Instant>;
    loop {
        if stop.load(Ordering::Acquire) {
            if generation != 0 {
                let _ = transport::send(
                    &mut stream,
                    &Request {
                        id: id + 1,
                        session,
                        generation,
                        command: Command::Disconnect,
                    },
                    Duration::from_millis(100),
                );
            }
            return Ok(());
        }
        let mut descriptors = [
            libc::pollfd {
                fd: stream.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: if frame_closed.is_none() {
                    frames.as_raw_fd()
                } else {
                    -1
                },
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let ready = unsafe { libc::poll(descriptors.as_mut_ptr(), 2, 10) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error.into());
        }
        if descriptors[0].revents != 0 {
            let event: Event = transport::receive(&mut stream, DEADLINE)?;
            if event.session != session
                || event.sequence != sequence + 1
                || event.generation == 0
                || event.generation < generation
            {
                return Err("Viewer 返回了过期或缺失的会话事件".into());
            }
            sequence = event.sequence;
            generation = event.generation;
            if let EventKind::Reply { request, .. } = &event.event {
                if !pending.remove(request) {
                    return Err("Viewer 响应序号无效".into());
                }
            }
            let mut update = updates.lock().unwrap();
            let metrics = matches!(&event.event, EventKind::Metrics(_));
            if !farpane_protocol::event_queue::admit(&mut update.events, metrics, |e| {
                matches!(&e.event, EventKind::Metrics(_))
            }) {
                if !metrics {
                    return Err("界面事件处理超时，会话已停止".into());
                }
            } else {
                update.events.push_back(event);
            }
        }
        if descriptors[1].revents != 0 {
            loop {
                let (packet, files) = match frames.receive() {
                    Ok(frame) => frame,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => {
                        // Media can close before the core's queued terminal event.
                        // Only that authenticated event can authorize a retry.
                        frame_closed = Some(Instant::now());
                        break;
                    }
                    Err(e) => return Err(e.into()),
                };
                let mut update = updates.lock().unwrap();
                match packet {
                    Packet::DmaBuf(_) | Packet::Software(_) => {
                        if let Some(unread) = update.frame.take() {
                            unread.discard()?;
                        }
                        update.frame = Some(Frame {
                            packet,
                            files,
                            channel: frames.clone(),
                            received: Instant::now(),
                            skipped: skipped.clone(),
                        });
                    }
                    Packet::Drain { generation: old } => {
                        if update.frame.as_ref().is_some_and(|f| f.generation() <= old) {
                            update.frame.take().unwrap().discard()?;
                        }
                    }
                    _ => return Err("Viewer 帧通道返回了无效命令".into()),
                }
            }
        }
        if let Some(closed) = frame_closed {
            if closed.elapsed() >= DEADLINE {
                return Err("Viewer 帧通道已关闭，未收到结束状态".into());
            }
            continue;
        }
        if !pending.is_empty() && pending_since.elapsed() > Duration::from_secs(8) {
            return Err("Viewer 未响应操作，会话已停止".into());
        }
        // A single pending request and a bounded/coalesced input queue; credits
        // in the worker additionally cover the actual asynchronous network send.
        if generation != 0
            && pending.is_empty()
            && last_command.elapsed() >= Duration::from_millis(5)
        {
            let command = commands.lock().unwrap().pop_front();
            match command {
                Some(command) => {
                    id = id.checked_add(1).ok_or("会话序号耗尽")?;
                    transport::send(
                        &mut stream,
                        &Request {
                            id,
                            session,
                            generation,
                            command,
                        },
                        DEADLINE,
                    )?;
                    pending.insert(id);
                    pending_since = Instant::now();
                    last_command = Instant::now();
                }
                None => {}
            }
        }
    }
}
