//! Bounded, blocking I/O runs on one worker; GTK never waits for a core call.
use farpane_protocol::{
    transport, Command, ConfigResponse, Event, EventKind, Hello, Request, Role, Snapshot, VERSION,
};
use std::{
    io,
    os::{fd::OwnedFd, unix::net::UnixStream},
    path::PathBuf,
    process::{Command as Process, Stdio},
    sync::{
        mpsc::{self, SyncSender},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
const DEADLINE: Duration = Duration::from_secs(6);

#[derive(Default)]
pub struct Update {
    pub snapshot: Option<Snapshot>,
    pub generation: Option<u64>,
    pub error: Option<String>,
    pub finished: bool,
    pub disconnected: bool,
}
#[derive(Clone)]
pub struct Bridge {
    commands: SyncSender<Pending>,
    updates: Arc<Mutex<Update>>,
}
struct Pending {
    command: Command,
    generation: u64,
}
impl Bridge {
    pub fn start() -> Self {
        let (tx, rx) = mpsc::sync_channel(8);
        let updates = Arc::new(Mutex::new(Update::default()));
        let output = updates.clone();
        thread::Builder::new()
            .name("farpane-control".into())
            .spawn(move || {
                let release = match Release::current() {
                    Ok(release) => release,
                    Err(error) => {
                        output.lock().unwrap().error =
                            Some(format!("尚未找到完整安装的 FarPane 后台：{error}"));
                        return;
                    }
                };
                let mut connection = None;
                let mut next_refresh = Instant::now();
                loop {
                    let command = match rx
                        .recv_timeout(next_refresh.saturating_duration_since(Instant::now()))
                    {
                        Ok(command) => command,
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(mpsc::RecvTimeoutError::Timeout) => Pending {
                            command: Command::Snapshot,
                            generation: 0,
                        },
                    };
                    let mutation = !matches!(command.command, Command::Snapshot);
                    let result = request(
                        &release,
                        &mut connection,
                        command.command,
                        command.generation,
                    );
                    let online = connection.is_some();
                    let mut update = output.lock().unwrap();
                    match result {
                        Ok((snapshot, error)) => {
                            update.snapshot = Some(snapshot);
                            update.generation =
                                Some(connection.as_ref().map_or(0, |a| a.generation));
                            if error.is_some() {
                                update.error = error;
                            }
                        }
                        Err(error) => {
                            connection = None;
                            update.snapshot = None;
                            update.generation = None;
                            update.error = Some(error.to_string());
                            update.disconnected = true;
                        }
                    }
                    update.finished |= mutation;
                    drop(update);
                    next_refresh = Instant::now() + Duration::from_secs(if online { 1 } else { 5 });
                }
            })
            .expect("control worker");
        Self {
            commands: tx,
            updates,
        }
    }
    pub fn send(&self, command: Command, generation: u64) -> std::result::Result<(), &'static str> {
        self.commands
            .try_send(Pending {
                command,
                generation,
            })
            .map_err(|_| "后台正在处理其他操作，请稍后重试")
    }
    pub fn take(&self) -> Update {
        std::mem::take(&mut *self.updates.lock().unwrap())
    }
}

pub(crate) struct Release {
    pub core: PathBuf,
    pub name: String,
}
impl Release {
    pub(crate) fn current() -> Result<Self> {
        let gui = transport::verify_release_executable(&std::env::current_exe()?)?;
        let root = gui.parent().ok_or("缺少安装目录")?;
        if gui.file_name().and_then(|s| s.to_str()) != Some("farpane") {
            return Err("无效的 FarPane 程序路径".into());
        }
        let core = transport::verify_release_executable(&root.join("libexec/farpane-core"))?;
        Ok(Self {
            core,
            name: root
                .file_name()
                .ok_or("缺少版本目录")?
                .to_string_lossy()
                .into_owned(),
        })
    }
    fn hello(&self) -> Hello {
        Hello {
            version: VERSION,
            release: self.name.clone(),
            role: Role::Gui,
            session: 0,
        }
    }
    fn verify(&self, hello: &Hello, role: Role) -> Result<()> {
        if hello.version != VERSION
            || hello.role != role
            || hello.release != self.name
            || hello.session != 0
        {
            return Err("后台与界面版本不一致，请使用同一完整安装包".into());
        }
        Ok(())
    }
}
struct Agent {
    stream: UnixStream,
    id: u64,
    sequence: u64,
    generation: u64,
}
impl Agent {
    fn connect(release: &Release) -> Result<Self> {
        let mut stream = transport::connect(&transport::runtime_directory()?.join("agent.sock"))?;
        let peer = transport::Peer::from_stream(&stream)?;
        peer.verify_executable(&release.core)?;
        transport::send(&mut stream, &release.hello(), DEADLINE)?;
        let hello: Hello = transport::receive(&mut stream, DEADLINE)?;
        release.verify(&hello, Role::Agent)?;
        Ok(Self {
            stream,
            id: 0,
            sequence: 0,
            generation: 0,
        })
    }
    fn event(&mut self) -> Result<EventKind> {
        let event: Event = transport::receive(&mut self.stream, DEADLINE)?;
        if event.session != 0
            || event.sequence != self.sequence + 1
            || event.generation == 0
            || (self.generation != 0 && event.generation != self.generation)
        {
            return Err("后台状态已更换，请重新读取".into());
        }
        self.sequence = event.sequence;
        self.generation = event.generation;
        Ok(event.event)
    }
    fn request(&mut self, command: Command) -> Result<(Snapshot, Option<String>)> {
        self.id += 1;
        transport::send(
            &mut self.stream,
            &Request {
                id: self.id,
                session: 0,
                generation: self.generation,
                command,
            },
            DEADLINE,
        )?;
        let error = match self.event()? {
            EventKind::Reply { request, error, .. } if request == self.id => error,
            _ => return Err("后台响应顺序无效".into()),
        };
        let snapshot = match self.event()? {
            EventKind::Snapshot(snapshot) => snapshot,
            _ => return Err("后台没有返回状态".into()),
        };
        Ok((snapshot, error))
    }
}
fn request(
    release: &Release,
    agent: &mut Option<Agent>,
    command: Command,
    observed_generation: u64,
) -> Result<(Snapshot, Option<String>)> {
    if agent.is_none() {
        match Agent::connect(release) {
            Ok(mut connection) => {
                connection.request(Command::Snapshot)?;
                *agent = Some(connection);
            }
            Err(error)
                if error.downcast_ref::<io::Error>().is_some_and(|e| {
                    matches!(
                        e.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                    )
                }) => {}
            Err(error) => return Err(error),
        }
    }
    if let Some(agent) = agent {
        if !matches!(command, Command::Snapshot | Command::Subscribe)
            && ((observed_generation != 0 && observed_generation != agent.generation)
                || (observed_generation == 0 && !command.allowed_for(Role::Config)))
        {
            return Err("后台已更换，此次操作未执行；请刷新后重新确认".into());
        }
        return agent.request(command);
    }
    if !command.allowed_for(Role::Config) {
        return Err("Host 后台未运行，此操作暂不可用".into());
    }
    let (mut stream, child_stream) = UnixStream::pair()?;
    let child_fd: OwnedFd = child_stream.into();
    let mut child = Process::new(&release.core)
        .arg("--config-command")
        .stdin(Stdio::from(child_fd))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    // The socketpair is created by this GUI. The child authenticates its peer;
    // the parent trusts its own spawned immutable executable and private pipe,
    // not socketpair SO_PEERCRED (which still names the creating GUI).
    let result = (|| {
        transport::send(&mut stream, &release.hello(), DEADLINE)?;
        let hello: Hello = transport::receive(&mut stream, DEADLINE)?;
        release.verify(&hello, Role::Config)?;
        transport::send(
            &mut stream,
            &Request {
                id: 1,
                session: 0,
                generation: 0,
                command,
            },
            DEADLINE,
        )?;
        let response: ConfigResponse = transport::receive(&mut stream, DEADLINE)?;
        if response.request != 1 {
            return Err("配置响应无效".into());
        }
        if let Some(error) = response.error {
            return Err(error.into());
        }
        Ok((response.snapshot.ok_or("没有收到配置快照")?, None))
    })();
    // Even a failed/blocked helper has a bounded lifetime. No process-name kill.
    drop(stream);
    let deadline = Instant::now() + Duration::from_millis(300);
    while child.try_wait()?.is_none() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    if child.try_wait()?.is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    #[test]
    fn stale_approval_is_not_sent_to_a_new_agent_generation() {
        // A reconnect has obtained generation 52, while the widget still shows
        // generation 41. Even if connection IDs are reused, nothing is sent.
        for observed in [0, 41] {
            let (stream, mut peer) = UnixStream::pair().unwrap();
            peer.set_nonblocking(true).unwrap();
            let mut agent = Some(Agent {
                stream,
                id: 1,
                sequence: 2,
                generation: 52,
            });
            let release = Release {
                core: PathBuf::from("/unused/core"),
                name: "test".into(),
            };
            let error = request(
                &release,
                &mut agent,
                Command::Approve {
                    connection: 1,
                    permissions: farpane_protocol::Permissions::default(),
                },
                observed,
            )
            .unwrap_err();
            assert!(error.to_string().contains("此次操作未执行"));
            assert_eq!(
                peer.read(&mut [0]).unwrap_err().kind(),
                io::ErrorKind::WouldBlock
            );
        }
    }
}
