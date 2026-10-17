use farpane_protocol::{
    transport, Command, Event, EventKind, Hello, Permissions, Request, Role, VERSION,
};
use hbb_common::{bail, ResultType};
use std::{
    io::Read,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            fs::MetadataExt,
            net::{UnixListener, UnixStream},
        },
    },
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        OnceLock,
    },
    time::{Duration, Instant},
};

static GENERATION: OnceLock<u64> = OnceLock::new();
static CHANGES: AtomicU64 = AtomicU64::new(1);
static CONNECTIONS: AtomicUsize = AtomicUsize::new(0);
const TIMEOUT: Duration = Duration::from_secs(3);
pub fn generation() -> u64 {
    *GENERATION.get_or_init(|| hbb_common::rand::random::<u64>().max(1))
}
pub fn changed() {
    CHANGES.fetch_add(1, Ordering::Relaxed);
}

#[derive(Clone)]
struct Release {
    core: PathBuf,
    gui: PathBuf,
    name: String,
}
pub fn verify_release() -> ResultType<()> {
    Release::current().map(|_| ())
}
pub fn viewer_parent(session: u64) -> ResultType<UnixStream> {
    if session == 0 || unsafe { hbb_common::libc::geteuid() } == 0 {
        bail!("Viewer requires a desktop user and a nonzero session");
    }
    let release = Release::current()?;
    let fd = unsafe { hbb_common::libc::fcntl(0, hbb_common::libc::F_DUPFD_CLOEXEC, 3) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let mut stream = unsafe { UnixStream::from_raw_fd(fd) };
    let peer = transport::Peer::from_stream(&stream)?;
    peer.verify_executable(&release.gui)?;
    let hello: Hello = transport::receive(&mut stream, TIMEOUT)?;
    if hello.role != Role::Gui
        || hello.version != VERSION
        || hello.session != session
        || hello.release != release.name
    {
        bail!("Incompatible Viewer parent handshake");
    }
    transport::send(
        &mut stream,
        &Hello {
            version: VERSION,
            role: Role::Viewer,
            release: release.name,
            session,
        },
        TIMEOUT,
    )?;
    Ok(stream)
}
impl Release {
    fn current() -> ResultType<Self> {
        let core = transport::verify_release_executable(&std::env::current_exe()?)?;
        let libexec = core
            .parent()
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Missing core directory"))?;
        if core.file_name().and_then(|s| s.to_str()) != Some("farpane-core")
            || libexec.file_name().and_then(|s| s.to_str()) != Some("libexec")
        {
            bail!("Native core must run from an immutable release/libexec/farpane-core");
        }
        let root = libexec.parent().unwrap().to_path_buf();
        let gui = transport::verify_release_executable(&root.join("farpane"))?;
        let name = root.file_name().unwrap().to_string_lossy().into_owned();
        Ok(Self { core, gui, name })
    }
    fn hello(&self, role: Role) -> Hello {
        Hello {
            version: VERSION,
            role,
            release: self.name.clone(),
            session: 0,
        }
    }
    fn accept(&self, stream: &mut UnixStream, role: Role) -> ResultType<Role> {
        let peer = transport::Peer::from_stream(stream)?;
        let hello: Hello = transport::receive(stream, TIMEOUT)?;
        if hello.version != VERSION || hello.release != self.name || hello.session != 0 {
            bail!("Incompatible control handshake");
        }
        let expected = match hello.role {
            Role::Gui => &self.gui,
            Role::Config => &self.core,
            _ => bail!("Untrusted client role"),
        };
        peer.verify_executable(expected)?;
        transport::send(stream, &self.hello(role), TIMEOUT)?;
        Ok(hello.role)
    }
}

pub struct Listener {
    listener: UnixListener,
    path: PathBuf,
    inode: u64,
    release: Release,
}
impl Drop for Listener {
    fn drop(&mut self) {
        if std::fs::symlink_metadata(&self.path)
            .map(|m| m.ino() == self.inode)
            .unwrap_or(false)
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}
pub fn bind() -> ResultType<Listener> {
    let release = Release::current()?;
    let path = transport::runtime_directory()?.join("agent.sock");
    // The caller already owns the per-user config lock, so a socket left by a
    // crashed previous agent can be removed after verifying ownership and type.
    if let Ok(meta) = std::fs::symlink_metadata(&path) {
        use std::os::unix::fs::FileTypeExt;
        if !meta.file_type().is_socket() || meta.uid() != unsafe { hbb_common::libc::geteuid() } {
            bail!("Unexpected control endpoint");
        }
        match transport::connect(&path) {
            Ok(_) => bail!("Native agent endpoint is already active"),
            Err(error) if error.raw_os_error() == Some(hbb_common::libc::ECONNREFUSED) => {}
            Err(error) => return Err(error.into()),
        }
        let current = std::fs::symlink_metadata(&path)?;
        if current.dev() != meta.dev() || current.ino() != meta.ino() {
            bail!("Control endpoint changed during cleanup");
        }
        std::fs::remove_file(&path)?;
    }
    let listener = transport::bind(&path)?;
    let inode = std::fs::symlink_metadata(&path)?.ino();
    Ok(Listener {
        listener,
        path,
        inode,
        release,
    })
}
pub fn serve(bound: Listener) -> ResultType<()> {
    for stream in bound.listener.incoming() {
        let mut stream = stream?;
        if CONNECTIONS.fetch_add(1, Ordering::AcqRel) >= 8 {
            CONNECTIONS.fetch_sub(1, Ordering::AcqRel);
            continue;
        }
        let release = bound.release.clone();
        std::thread::Builder::new()
            .name("native-control".into())
            .spawn(move || {
                struct Count;
                impl Drop for Count {
                    fn drop(&mut self) {
                        CONNECTIONS.fetch_sub(1, Ordering::AcqRel);
                    }
                }
                let _count = Count;
                if let Err(error) = release
                    .accept(&mut stream, Role::Agent)
                    .and_then(|role| connection(&mut stream, role))
                {
                    hbb_common::log::debug!("Native control connection ended: {error}");
                }
            })?;
    }
    bail!("Native control listener ended")
}
fn send(stream: &mut UnixStream, sequence: &mut u64, event: EventKind) -> ResultType<()> {
    *sequence += 1;
    transport::send(
        stream,
        &Event {
            sequence: *sequence,
            session: 0,
            generation: generation(),
            event,
        },
        TIMEOUT,
    )?;
    Ok(())
}
fn connection(stream: &mut UnixStream, client: Role) -> ResultType<()> {
    let (mut sequence, mut last_id, mut subscribed, mut stamp) = (0, 0, false, 0);
    let mut last_snapshot = Instant::now();
    loop {
        let mut fd = hbb_common::libc::pollfd {
            fd: stream.as_raw_fd(),
            events: hbb_common::libc::POLLIN,
            revents: 0,
        };
        let rc = unsafe { hbb_common::libc::poll(&mut fd, 1, 200) };
        if rc < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        if rc > 0 {
            let request: Request = transport::receive(stream, TIMEOUT)?;
            if request.id <= last_id
                || request.session != 0
                || (request.generation != generation()
                    && !matches!(request.command, Command::Snapshot | Command::Subscribe))
            {
                bail!("Stale or replayed control request");
            }
            last_id = request.id;
            if matches!(request.command, Command::Subscribe) {
                subscribed = true;
            }
            let result = if client == Role::Config && !request.command.allowed_for(Role::Config) {
                Err(hbb_common::anyhow::anyhow!(
                    "Unavailable configuration command"
                ))
            } else {
                execute(&request.command, Role::Agent)
            };
            send(
                stream,
                &mut sequence,
                EventKind::Reply {
                    request: request.id,
                    revision: super::config::revision(),
                    error: result.err().map(|e| e.to_string()),
                },
            )?;
            send(
                stream,
                &mut sequence,
                EventKind::Snapshot(super::config::snapshot(Role::Agent)),
            )?;
            last_snapshot = Instant::now();
            stamp = CHANGES.load(Ordering::Relaxed);
        }
        let next_stamp = CHANGES.load(Ordering::Relaxed);
        if subscribed && (stamp != next_stamp || last_snapshot.elapsed() >= Duration::from_secs(1))
        {
            send(
                stream,
                &mut sequence,
                EventKind::Snapshot(super::config::snapshot(Role::Agent)),
            )?;
            last_snapshot = Instant::now();
            stamp = next_stamp;
        }
    }
}
fn same_permissions(a: &Permissions, b: &Permissions) -> bool {
    a == b
}
pub fn execute(command: &Command, role: Role) -> ResultType<()> {
    if !command.allowed_for(role) {
        bail!("Command is unavailable for this core role");
    }
    match command {
        Command::Snapshot | Command::Subscribe => {}
        Command::SetHost { .. }
        | Command::SetServer { .. }
        | Command::SetAuthentication { .. }
        | Command::SetHostAudio { .. }
        | Command::SetHostFiles { .. }
        | Command::SetHostClipboard { .. }
        | Command::RememberDevice { .. }
        | Command::SetDevice { .. }
        | Command::ForgetDevice { .. }
        | Command::SetGpu { .. } => {
            super::config::apply(command, role)?;
            if matches!(command, Command::SetHostFiles { .. }) && role == Role::Agent {
                super::files::stop_outdated()?;
            }
            changed();
        }
        Command::Approve {
            connection,
            permissions,
        } => {
            let current = super::cm::connections()
                .into_iter()
                .find(|c| c.id == *connection)
                .ok_or_else(|| hbb_common::anyhow::anyhow!("Connection is no longer pending"))?;
            if current.authorized {
                bail!("Connection is already authorized");
            }
            for (name, enabled, allowed) in [
                (
                    "keyboard",
                    permissions.keyboard,
                    current.permissions.keyboard,
                ),
                (
                    "clipboard",
                    permissions.clipboard,
                    current.permissions.clipboard,
                ),
                ("audio", permissions.audio, current.permissions.audio),
                ("file", permissions.file, current.permissions.file),
            ] {
                if enabled && !allowed {
                    bail!("Approval cannot grant a capability disabled by Host policy");
                }
                if enabled != allowed {
                    crate::ui_cm_interface::switch_permission(*connection, name.into(), enabled);
                }
            }
            wait_connection(*connection, |p| {
                same_permissions(&p.permissions, permissions)
            })?;
            crate::ui_cm_interface::authorize(*connection);
            if let Err(error) = wait_connection(*connection, |p| p.authorized) {
                crate::ui_cm_interface::close(*connection);
                return Err(error);
            }
        }
        Command::Reject { connection } | Command::DisconnectInbound { connection } => {
            crate::ui_cm_interface::close(*connection);
            let deadline = Instant::now() + Duration::from_secs(2);
            while super::cm::connections().iter().any(|c| c.id == *connection) {
                if Instant::now() >= deadline {
                    bail!("The backend has not confirmed disconnection");
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            super::files::stop_connection(*connection)?;
        }
        Command::Revoke {
            connection,
            permission,
        } => {
            use farpane_protocol::Permission::*;
            let name = match permission {
                Keyboard => "keyboard",
                Clipboard => "clipboard",
                Audio => "audio",
                File => "file",
            };
            if *permission == Clipboard {
                super::host_clipboard::revoke(*connection);
            }
            crate::ui_cm_interface::switch_permission(*connection, name.into(), false);
            wait_connection(*connection, |p| !match permission {
                Keyboard => p.permissions.keyboard,
                Clipboard => p.permissions.clipboard,
                Audio => p.permissions.audio,
                File => p.permissions.file,
            })?;
            if *permission == Clipboard {
                super::host_clipboard::barrier()?;
            }
            if *permission == File {
                super::files::stop_connection(*connection)?;
            }
        }
        Command::ConfirmTransfer {
            job,
            accept,
            overwrite,
        } => super::files::decide(*job, *accept, *overwrite)?,
        Command::CancelTransfer { job } => super::files::cancel(*job)?,
        _ => bail!("This operation is not implemented by the Host control interface"),
    }
    Ok(())
}
fn wait_connection(
    id: i32,
    predicate: impl Fn(&farpane_protocol::Inbound) -> bool,
) -> ResultType<()> {
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        let connection = super::cm::connections()
            .into_iter()
            .find(|c| c.id == id)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Connection ended"))?;
        if predicate(&connection) {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    bail!("The backend did not confirm the requested change")
}

pub fn config_cli() -> ResultType<()> {
    let mut data = Vec::new();
    std::io::stdin()
        .take((farpane_protocol::MAX_MESSAGE + 1) as u64)
        .read_to_end(&mut data)?;
    if data.len() > farpane_protocol::MAX_MESSAGE {
        bail!("Configuration request exceeds limit");
    }
    let command: Command = serde_json::from_slice(&data)
        .map_err(|_| hbb_common::anyhow::anyhow!("Invalid configuration request"))?;
    if !command.allowed_for(Role::Config) {
        bail!("Command is unavailable offline");
    }
    let result = config_request(command)?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}
pub fn config_command() -> ResultType<()> {
    // GUI passes a private Unix socket as stdin, never secrets on argv.
    let release = Release::current()?;
    let mut stream = unsafe { UnixStream::from_raw_fd(0) };
    release.accept(&mut stream, Role::Config)?;
    let request: Request = transport::receive(&mut stream, TIMEOUT)?;
    if request.session != 0 || !request.command.allowed_for(Role::Config) {
        bail!("Invalid offline configuration command");
    }
    let result = config_request(request.command);
    let (snapshot, error) = match result {
        Ok(snapshot) => (Some(snapshot), None),
        Err(error) => (None, Some(error.to_string())),
    };
    transport::send(
        &mut stream,
        &farpane_protocol::ConfigResponse {
            request: request.id,
            snapshot,
            error,
        },
        TIMEOUT,
    )?;
    Ok(())
}
fn config_request(command: Command) -> ResultType<farpane_protocol::Snapshot> {
    for _ in 0..3 {
        match super::config::OwnerLock::acquire() {
            Ok(_owner) => {
                super::config::initialize()?;
                execute(&command, Role::Config)?;
                return Ok(super::config::snapshot(Role::Config));
            }
            Err(error) => {
                // Only lock contention is a reason to forward. Unsafe paths or
                // permissions must not be turned into a different trust route.
                if !error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::WouldBlock)
                {
                    return Err(error);
                }
                match forward_config(command.clone()) {
                    Ok(snapshot) => return Ok(snapshot),
                    Err(error)
                        if error.downcast_ref::<std::io::Error>().is_some_and(|e| {
                            matches!(
                                e.kind(),
                                std::io::ErrorKind::NotFound
                                    | std::io::ErrorKind::ConnectionRefused
                            )
                        }) => {}
                    Err(error) => return Err(error),
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
    bail!("FarPane configuration owner is starting or unavailable; retry shortly")
}
fn forward_config(command: Command) -> ResultType<farpane_protocol::Snapshot> {
    let release = Release::current()?;
    let mut stream = transport::connect(&transport::runtime_directory()?.join("agent.sock"))?;
    let peer = transport::Peer::from_stream(&stream)?;
    peer.verify_executable(&release.core)?;
    transport::send(&mut stream, &release.hello(Role::Config), TIMEOUT)?;
    let hello: Hello = transport::receive(&mut stream, TIMEOUT)?;
    if hello.version != VERSION
        || hello.role != Role::Agent
        || hello.release != release.name
        || hello.session != 0
    {
        bail!("Agent version mismatch");
    }
    transport::send(
        &mut stream,
        &Request {
            id: 1,
            session: 0,
            generation: 0,
            command: Command::Snapshot,
        },
        TIMEOUT,
    )?;
    let first: Event = transport::receive(&mut stream, TIMEOUT)?;
    validate_reply(&first, 1, 1, None)?;
    let state: Event = transport::receive(&mut stream, TIMEOUT)?;
    validate_snapshot(&state, 2, first.generation)?;
    transport::send(
        &mut stream,
        &Request {
            id: 2,
            session: 0,
            generation: state.generation,
            command,
        },
        TIMEOUT,
    )?;
    let reply: Event = transport::receive(&mut stream, TIMEOUT)?;
    validate_reply(&reply, 2, 3, Some(state.generation))?;
    let snapshot: Event = transport::receive(&mut stream, TIMEOUT)?;
    validate_snapshot(&snapshot, 4, state.generation)?;
    match snapshot.event {
        EventKind::Snapshot(snapshot) => Ok(snapshot),
        _ => bail!("Unexpected agent response"),
    }
}

fn validate_reply(
    event: &Event,
    id: u64,
    sequence: u64,
    generation: Option<u64>,
) -> ResultType<()> {
    if event.sequence != sequence
        || event.session != 0
        || event.generation == 0
        || generation.is_some_and(|g| g != event.generation)
    {
        bail!("Invalid agent reply envelope");
    }
    match &event.event {
        EventKind::Reply { request, error, .. } if *request == id => {
            if let Some(error) = error {
                bail!("{error}");
            }
            Ok(())
        }
        _ => bail!("Unexpected agent reply"),
    }
}
fn validate_snapshot(event: &Event, sequence: u64, generation: u64) -> ResultType<()> {
    if event.sequence != sequence
        || event.session != 0
        || event.generation != generation
        || !matches!(event.event, EventKind::Snapshot(_))
    {
        bail!("Invalid agent snapshot");
    }
    Ok(())
}
