use crate::MAX_MESSAGE;
use serde::{de::DeserializeOwned, Serialize};
use std::{
    fs,
    io::{self, Read, Write},
    mem,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::{
            fs::{DirBuilderExt, MetadataExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

/// AF_UNIX connect can otherwise block indefinitely on a full listen backlog.
/// Fail with WouldBlock when a local endpoint cannot accept immediately; the
/// caller retries through its normal bounded recovery policy.
pub fn connect(path: &Path) -> io::Result<UnixStream> {
    use std::os::unix::ffi::OsStrExt;
    let bytes = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { mem::zeroed() };
    if bytes.is_empty() || bytes.contains(&0) || bytes.len() >= address.sun_path.len() {
        return Err(invalid("invalid local endpoint path"));
    }
    address.sun_family = libc::AF_UNIX as _;
    unsafe {
        std::ptr::copy_nonoverlapping(
            bytes.as_ptr(),
            address.sun_path.as_mut_ptr().cast(),
            bytes.len(),
        );
    }
    let fd = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    if unsafe {
        libc::connect(
            fd,
            (&address as *const libc::sockaddr_un).cast(),
            mem::size_of_val(&address) as _,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    stream.set_nonblocking(false)?;
    Ok(stream)
}

pub fn send<T: Serialize>(stream: &mut UnixStream, value: &T, timeout: Duration) -> io::Result<()> {
    let payload = serde_json::to_vec(value).map_err(|_| invalid("cannot encode message"))?;
    if payload.is_empty() || payload.len() > MAX_MESSAGE {
        return Err(invalid("message exceeds limit"));
    }
    let mut packet = Vec::with_capacity(payload.len() + 4);
    packet.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    packet.extend_from_slice(&payload);
    let deadline = Instant::now() + timeout;
    let mut remaining = packet.as_slice();
    while !remaining.is_empty() {
        stream.set_write_timeout(Some(time_left(deadline)?))?;
        let n = stream.write(remaining)?;
        if n == 0 {
            return Err(io::ErrorKind::WriteZero.into());
        }
        remaining = &remaining[n..];
    }
    Ok(())
}

pub fn receive<T: DeserializeOwned>(stream: &mut UnixStream, timeout: Duration) -> io::Result<T> {
    let deadline = Instant::now() + timeout;
    let mut header = [0; 4];
    read_deadline(stream, &mut header, deadline)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_MESSAGE {
        return Err(invalid("message exceeds limit"));
    }
    let mut payload = vec![0; length];
    read_deadline(stream, &mut payload, deadline)?;
    // Do not include serde's error text: a malformed message can contain secrets.
    serde_json::from_slice(&payload).map_err(|_| invalid("invalid protocol message"))
}

fn time_left(deadline: Instant) -> io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or_else(|| io::ErrorKind::TimedOut.into())
}
fn read_deadline(
    stream: &mut UnixStream,
    mut buffer: &mut [u8],
    deadline: Instant,
) -> io::Result<()> {
    while !buffer.is_empty() {
        stream.set_read_timeout(Some(time_left(deadline)?))?;
        let n = stream.read(buffer)?;
        if n == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        buffer = &mut buffer[n..];
    }
    Ok(())
}

/// Never follows a symlink or chmods an existing foreign directory.
pub fn private_directory(path: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o777 != 0o700 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "unsafe runtime directory",
        ));
    }
    Ok(())
}

pub fn runtime_directory() -> io::Result<PathBuf> {
    let base = PathBuf::from(
        std::env::var_os("XDG_RUNTIME_DIR")
            .ok_or_else(|| invalid("XDG_RUNTIME_DIR is required"))?,
    );
    let meta = fs::symlink_metadata(&base)?;
    if !base.is_absolute()
        || !meta.is_dir()
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
    {
        return Err(invalid("unsafe XDG_RUNTIME_DIR"));
    }
    let path = base.join("farpane");
    private_directory(&path)?;
    Ok(path)
}

/// Caller owns lifecycle removal. Refusing an existing socket avoids stealing
/// an active endpoint or deleting a file after a failed probe.
pub fn bind(path: &Path) -> io::Result<UnixListener> {
    private_directory(path.parent().ok_or_else(|| invalid("missing parent"))?)?;
    let listener = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// A stable handle to the actual peer, not a PID obtained by a process scan.
pub struct Peer {
    pub pid: u32,
    pub uid: u32,
    pidfd: OwnedFd,
}
impl Peer {
    pub fn from_stream(stream: &UnixStream) -> io::Result<Self> {
        Self::from_fd_for_uid(stream.as_raw_fd(), unsafe { libc::geteuid() })
    }
    /// Core-only cross-UID supervision uses an explicit expected UID. The GUI
    /// control endpoint always uses from_stream and remains same-user only.
    pub fn from_fd_for_uid(socket: std::os::fd::RawFd, uid: u32) -> io::Result<Self> {
        let mut creds: libc::ucred = unsafe { mem::zeroed() };
        let mut len = mem::size_of_val(&creds) as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                socket,
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                &mut creds as *mut _ as *mut _,
                &mut len,
            )
        };
        if rc < 0 {
            return Err(io::Error::last_os_error());
        }
        if creds.pid <= 0 || creds.uid != uid {
            return Err(invalid("peer UID mismatch"));
        }
        // Linux 6.5+. Obtaining a pidfd by numeric PID after SO_PEERCRED races
        // process exit/reuse; SO_PEERPIDFD binds it to this socket's actual peer.
        const SO_PEERPIDFD: libc::c_int = 77;
        let mut fd: libc::c_int = -1;
        len = mem::size_of_val(&fd) as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                socket,
                libc::SOL_SOCKET,
                SO_PEERPIDFD,
                &mut fd as *mut _ as *mut _,
                &mut len,
            )
        };
        if rc < 0 {
            return Err(io::Error::last_os_error());
        }
        let peer = Self {
            pid: creds.pid as u32,
            uid: creds.uid,
            pidfd: unsafe { OwnedFd::from_raw_fd(fd) },
        };
        peer.ensure_alive()?;
        Ok(peer)
    }
    pub fn ensure_alive(&self) -> io::Result<()> {
        let mut fd = libc::pollfd {
            fd: self.pidfd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let rc = unsafe { libc::poll(&mut fd, 1, 0) };
        if rc == 0 {
            Ok(())
        } else if rc < 0 {
            Err(io::Error::last_os_error())
        } else {
            Err(invalid("peer exited"))
        }
    }
    pub fn verify_executable(&self, expected: &Path) -> io::Result<()> {
        self.ensure_alive()?;
        let actual = fs::read_link(format!("/proc/{}/exe", self.pid))?;
        if actual != expected {
            return Err(invalid("unexpected peer executable"));
        }
        self.ensure_alive()
    }
}

/// Verify an immutable release before trusting an executable pathname. All
/// ancestors must be root-owned and not group/world writable.
pub fn verify_release_executable(path: &Path) -> io::Result<PathBuf> {
    let canonical = fs::canonicalize(path)?;
    let file = fs::metadata(&canonical)?;
    if !file.is_file() || file.mode() & 0o111 == 0 {
        return Err(invalid("not an executable"));
    }
    for ancestor in canonical.ancestors() {
        let meta = fs::symlink_metadata(ancestor)?;
        if meta.uid() != 0 || meta.mode() & 0o022 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "release is writable by an untrusted user",
            ));
        }
    }
    Ok(canonical)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Command, Request};
    #[test]
    fn saturated_listener_never_blocks_the_caller() {
        let path = std::env::temp_dir().join(format!("farpane-backlog-{}", std::process::id()));
        let listener = UnixListener::bind(&path).unwrap();
        assert_eq!(unsafe { libc::listen(listener.as_raw_fd(), 1) }, 0);
        let start = Instant::now();
        let mut accepted = Vec::new();
        let mut refused = false;
        for _ in 0..8 {
            match connect(&path) {
                Ok(stream) => accepted.push(stream),
                Err(error) => {
                    assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
                    refused = true;
                    break;
                }
            }
        }
        assert!(refused && start.elapsed() < Duration::from_secs(1));
        fs::remove_file(path).unwrap();
    }
    #[test]
    fn bounded_transport_and_peer_identity() {
        let (mut a, mut b) = UnixStream::pair().unwrap();
        let peer = Peer::from_stream(&a).unwrap();
        assert!(Peer::from_fd_for_uid(a.as_raw_fd(), u32::MAX).is_err());
        peer.verify_executable(&fs::read_link("/proc/self/exe").unwrap())
            .unwrap();
        assert!(peer
            .verify_executable(Path::new("/wrong/executable"))
            .is_err());
        let value = Request {
            id: 1,
            session: 0,
            generation: 0,
            command: Command::Snapshot,
        };
        send(&mut a, &value, Duration::from_secs(1)).unwrap();
        assert_eq!(
            receive::<Request>(&mut b, Duration::from_secs(1))
                .unwrap()
                .id,
            1
        );
        a.write_all(&((MAX_MESSAGE + 1) as u32).to_be_bytes())
            .unwrap();
        assert_eq!(
            receive::<Request>(&mut b, Duration::from_secs(1))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
    }
    #[test]
    fn malformed_json_does_not_leak_payload() {
        let (mut a, mut b) = UnixStream::pair().unwrap();
        let secret = b"{this is a secret password}";
        a.write_all(&(secret.len() as u32).to_be_bytes()).unwrap();
        a.write_all(secret).unwrap();
        let error = receive::<Request>(&mut b, Duration::from_secs(1)).unwrap_err();
        assert!(!error.to_string().contains("secret password"));
    }
    #[test]
    fn incomplete_message_has_a_deadline() {
        let (_a, mut b) = UnixStream::pair().unwrap();
        let start = Instant::now();
        assert!(receive::<Request>(&mut b, Duration::from_millis(30)).is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
    }
    #[test]
    fn runtime_directory_rejects_symlinks_and_public_permissions() {
        let path = std::env::temp_dir().join(format!("farpane-protocol-{}", std::process::id()));
        private_directory(&path).unwrap();
        let link = path.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(private_directory(&link).is_err());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(private_directory(&path).is_err());
        fs::remove_file(link).unwrap();
        fs::remove_dir(path).unwrap();
    }
}
