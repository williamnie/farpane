//! Bounded frame/lease messages with SCM_RIGHTS. Descriptor ownership is explicit
//! even for malformed/truncated packets; kernel duplicates are always CLOEXEC.
use crate::{
    frame::{Frame, SoftwareFrame},
    MAX_MESSAGE,
};
use serde::{Deserialize, Serialize};
use std::{
    io, mem,
    os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
    ptr,
};

const MAX_FDS: usize = 4;
const MARKER: u8 = 0x46;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub enum Packet {
    DmaBuf(Frame),
    Software(SoftwareFrame),
    Release { generation: u64, lease: u64 },
    Drain { generation: u64 },
}
impl Packet {
    fn validate(&self, files: usize) -> io::Result<()> {
        if files != self.descriptor_count() || files > MAX_FDS {
            return Err(invalid());
        }
        match self {
            Self::DmaBuf(frame) => frame
                .validate(files, frame.generation)
                .map_err(|_| invalid()),
            Self::Software(frame) => frame.byte_len().map(|_| ()).map_err(|_| invalid()),
            Self::Release { generation, lease } if *generation != 0 && *lease != 0 => Ok(()),
            Self::Drain { generation } if *generation != 0 => Ok(()),
            _ => Err(invalid()),
        }
    }
    fn descriptor_count(&self) -> usize {
        match self {
            Self::DmaBuf(frame) => frame.objects.len(),
            Self::Software(_) => 1,
            _ => 0,
        }
    }
}
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "Invalid frame channel message")
}

pub struct Channel(OwnedFd);
impl AsRawFd for Channel {
    fn as_raw_fd(&self) -> RawFd {
        self.0.as_raw_fd()
    }
}
impl Channel {
    pub fn pair() -> io::Result<(Self, Self)> {
        let mut fd = [-1; 2];
        if unsafe {
            libc::socketpair(
                libc::AF_UNIX,
                libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
                0,
                fd.as_mut_ptr(),
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe {
            (
                Self(OwnedFd::from_raw_fd(fd[0])),
                Self(OwnedFd::from_raw_fd(fd[1])),
            )
        })
    }
    pub fn from_owned(fd: OwnedFd) -> io::Result<Self> {
        let mut kind = 0;
        let mut domain = 0;
        let mut len = mem::size_of_val(&kind) as libc::socklen_t;
        if unsafe {
            libc::getsockopt(
                fd.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_TYPE,
                (&mut kind as *mut i32).cast(),
                &mut len,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        if unsafe {
            libc::getsockopt(
                fd.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_DOMAIN,
                (&mut domain as *mut i32).cast(),
                &mut len,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        if kind != libc::SOCK_SEQPACKET || domain != libc::AF_UNIX {
            return Err(invalid());
        }
        let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
        let fd_flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) };
        if flags < 0
            || fd_flags < 0
            || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
            || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, fd_flags | libc::FD_CLOEXEC) }
                < 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(fd))
    }
    pub fn send(&self, packet: &Packet, files: &[RawFd]) -> io::Result<()> {
        packet.validate(files.len())?;
        let bytes = serde_json::to_vec(packet).map_err(|_| invalid())?;
        if bytes.len() > MAX_MESSAGE {
            return Err(invalid());
        }
        send(self.as_raw_fd(), &bytes, files)
    }
    pub fn receive(&self) -> io::Result<(Packet, Vec<OwnedFd>)> {
        let (bytes, files) = receive(self.as_raw_fd(), MAX_MESSAGE, libc::MSG_DONTWAIT)?;
        let packet: Packet = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        packet.validate(files.len())?;
        Ok((packet, files))
    }
}

/// Pass a dedicated frame channel after the control Hello is authenticated and
/// before ordinary Request framing begins. Exactly one marker byte and one fd.
pub fn send_channel(control: &impl AsRawFd, channel: &Channel) -> io::Result<()> {
    send(control.as_raw_fd(), &[MARKER], &[channel.as_raw_fd()])
}
pub fn receive_channel(control: &impl AsRawFd) -> io::Result<Channel> {
    let (bytes, mut files) = receive(control.as_raw_fd(), 1, 0)?;
    if bytes != [MARKER] || files.len() != 1 {
        return Err(invalid());
    }
    Channel::from_owned(files.remove(0))
}

pub(crate) fn send(fd: RawFd, bytes: &[u8], files: &[RawFd]) -> io::Result<()> {
    if bytes.is_empty() || files.len() > MAX_FDS {
        return Err(invalid());
    }
    let mut iov = libc::iovec {
        iov_base: bytes.as_ptr().cast_mut().cast(),
        iov_len: bytes.len(),
    };
    let mut message: libc::msghdr = unsafe { mem::zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    let size = unsafe { libc::CMSG_SPACE((files.len() * mem::size_of::<RawFd>()) as u32) } as usize;
    let mut ancillary = vec![0usize; size.div_ceil(mem::size_of::<usize>())];
    if !files.is_empty() {
        message.msg_control = ancillary.as_mut_ptr().cast();
        message.msg_controllen = size;
        unsafe {
            let header = libc::CMSG_FIRSTHDR(&message);
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len =
                libc::CMSG_LEN((files.len() * mem::size_of::<RawFd>()) as u32) as usize;
            ptr::copy_nonoverlapping(
                files.as_ptr().cast::<u8>(),
                libc::CMSG_DATA(header),
                files.len() * mem::size_of::<RawFd>(),
            );
        }
    }
    let result = unsafe { libc::sendmsg(fd, &message, libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT) };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    // Seqpacket is all-or-nothing; the control bootstrap is exactly one byte.
    if result as usize != bytes.len() {
        return Err(invalid());
    }
    Ok(())
}
pub(crate) fn receive(
    fd: RawFd,
    capacity: usize,
    flags: i32,
) -> io::Result<(Vec<u8>, Vec<OwnedFd>)> {
    let mut bytes = vec![0u8; capacity];
    let mut files = Vec::new();
    let mut iov = libc::iovec {
        iov_base: bytes.as_mut_ptr().cast(),
        iov_len: bytes.len(),
    };
    let size = unsafe { libc::CMSG_SPACE((MAX_FDS * mem::size_of::<RawFd>()) as u32) } as usize;
    let mut ancillary = vec![0usize; size.div_ceil(mem::size_of::<usize>())];
    let mut message: libc::msghdr = unsafe { mem::zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    message.msg_control = ancillary.as_mut_ptr().cast();
    message.msg_controllen = size;
    let result = unsafe { libc::recvmsg(fd, &mut message, flags | libc::MSG_CMSG_CLOEXEC) };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut unexpected = false;
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(&message);
        while !header.is_null() {
            if (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS {
                let header_len = libc::CMSG_LEN(0) as usize;
                if (*header).cmsg_len < header_len {
                    unexpected = true;
                    break;
                }
                let length = (*header).cmsg_len - header_len;
                if length % mem::size_of::<RawFd>() != 0 {
                    unexpected = true;
                }
                let data = libc::CMSG_DATA(header);
                for index in 0..length / mem::size_of::<RawFd>() {
                    let received = ptr::read_unaligned(
                        data.add(index * mem::size_of::<RawFd>()).cast::<RawFd>(),
                    );
                    files.push(OwnedFd::from_raw_fd(received));
                }
            } else {
                unexpected = true;
            }
            header = libc::CMSG_NXTHDR(&message, header);
        }
    }
    if unexpected
        || message.msg_flags & (libc::MSG_CTRUNC | libc::MSG_TRUNC) != 0
        || files.len() > MAX_FDS
    {
        return Err(invalid());
    }
    if result == 0 {
        return Err(io::ErrorKind::UnexpectedEof.into());
    }
    bytes.truncate(result as usize);
    Ok((bytes, files))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs::File, os::unix::net::UnixStream, time::Duration};
    #[test]
    fn channel_bootstrap_and_lease_return_preserve_ownership() {
        let (control_a, control_b) = UnixStream::pair().unwrap();
        control_b
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let (producer, consumer) = Channel::pair().unwrap();
        send_channel(&control_a, &consumer).unwrap();
        drop(consumer);
        let transferred = receive_channel(&control_b).unwrap();
        producer
            .send(
                &Packet::Release {
                    generation: 7,
                    lease: 3,
                },
                &[],
            )
            .unwrap();
        assert!(matches!(
            transferred.receive().unwrap().0,
            Packet::Release {
                generation: 7,
                lease: 3
            }
        ));
        assert!(matches!(
            transferred.receive().unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        ));
        drop(transferred);
        assert!(producer.receive().is_err());
    }
    #[test]
    fn malformed_payload_closes_received_descriptors_and_does_not_leak_secrets() {
        // Other protocol tests open descriptors too. Isolate this leak count
        // instead of relying on every cargo/CI caller disabling parallel tests.
        if std::env::var("FARPANE_FD_COUNT_TEST").as_deref() != Ok("1") {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "frame_socket::tests::malformed_payload_closes_received_descriptors_and_does_not_leak_secrets"])
                .env("FARPANE_FD_COUNT_TEST", "1").output().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stdout)
            );
            return;
        }
        let (a, b) = Channel::pair().unwrap();
        let file = File::open("/dev/null").unwrap();
        let fd_count = || std::fs::read_dir("/proc/self/fd").unwrap().count();
        let before = fd_count();
        send(
            a.as_raw_fd(),
            b"invalid secret payload",
            &[file.as_raw_fd()],
        )
        .unwrap();
        let error = b.receive().unwrap_err();
        assert!(!error.to_string().contains("secret payload"));
        assert_eq!(before, fd_count());
        send(
            a.as_raw_fd(),
            &vec![b'x'; MAX_MESSAGE + 1],
            &[file.as_raw_fd()],
        )
        .unwrap();
        assert!(b.receive().is_err());
        assert_eq!(before, fd_count());
    }
    #[test]
    fn transferred_descriptors_are_close_on_exec_and_must_match_metadata() {
        let (a, b) = Channel::pair().unwrap();
        let file = File::open("/dev/null").unwrap();
        send(a.as_raw_fd(), b"x", &[file.as_raw_fd()]).unwrap();
        let (_, files) = receive(b.as_raw_fd(), 1, libc::MSG_DONTWAIT).unwrap();
        assert_ne!(
            unsafe { libc::fcntl(files[0].as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
        assert!(a
            .send(
                &Packet::Release {
                    generation: 1,
                    lease: 1
                },
                &[file.as_raw_fd()]
            )
            .is_err());
        assert!(Channel::from_owned(File::open("/dev/null").unwrap().into()).is_err());
    }
}
