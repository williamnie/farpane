//! Dedicated clipboard channel. Never put payloads into the control/frame queue.
//! Call prepare/map/validate on a worker, not on the GTK thread. Every direction
//! has one in-flight offer until its exact receipt; receipts do not mean pasted.
use crate::{
    clipboard::{self, Direction, Offer, Part, Policy, Token, IMAGE_LIMIT},
    frame_socket, sealed,
};
use serde::{Deserialize, Serialize};
use std::{
    io,
    os::fd::{AsRawFd, OwnedFd, RawFd},
    sync::Arc,
    time::{Duration, Instant},
};

const METADATA_LIMIT: usize = 2048;
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Received,
    Ignored,
    Invalid,
}
#[derive(Serialize, Deserialize)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "snake_case",
    deny_unknown_fields
)]
enum Packet {
    Offer(Offer),
    Receipt { token: Token, status: Status },
}

pub struct Prepared {
    pub offer: Offer,
    file: OwnedFd,
}
impl Prepared {
    pub fn new<B: AsRef<[u8]>>(token: Token, parts: &[Part<B>]) -> io::Result<Self> {
        let offer = clipboard::describe(token, parts)?;
        let slices = parts.iter().map(|p| p.bytes.as_ref()).collect::<Vec<_>>();
        let file = sealed::create_parts(&slices, IMAGE_LIMIT, c"farpane-clipboard")?;
        Ok(Self { offer, file })
    }
}
pub struct Incoming {
    pub offer: Offer,
    file: OwnedFd,
}
impl Incoming {
    /// Grant/revision admission precedes mmap and payload access. The immutable
    /// descriptor is closed on any rejected, stale or malformed offer.
    pub fn map(self, revision: u64, policy: Policy, direction: Direction) -> io::Result<Contents> {
        let (category, length) = self.offer.layout()?;
        if self.offer.token.revision != revision || !policy.allows(category, direction) {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        let bytes = sealed::Bytes::map_with_limit(self.file, length, IMAGE_LIMIT)?;
        self.offer.validate(bytes.as_ref())?;
        Ok(Contents {
            offer: self.offer,
            bytes: Arc::new(bytes),
        })
    }
}
/// SharedPart can back a GBytes or network Bytes owner without a payload clone.
pub struct Contents {
    offer: Offer,
    bytes: Arc<sealed::Bytes>,
}
impl Contents {
    pub fn offer(&self) -> &Offer {
        &self.offer
    }
    pub fn part(&self, index: usize) -> Option<SharedPart> {
        let item = self.offer.items.get(index)?;
        Some(SharedPart {
            bytes: self.bytes.clone(),
            start: item.offset as usize,
            length: item.length as usize,
        })
    }
}
#[derive(Clone)]
pub struct SharedPart {
    bytes: Arc<sealed::Bytes>,
    start: usize,
    length: usize,
}
impl AsRef<[u8]> for SharedPart {
    fn as_ref(&self) -> &[u8] {
        &self.bytes.as_ref().as_ref()[self.start..self.start + self.length]
    }
}
pub enum Delivery {
    Offer(Incoming),
    Receipt {
        token: Token,
        status: Status,
        matched: bool,
    },
}
pub struct Channel {
    socket: frame_socket::Channel,
    sent: u64,
    received: u64,
    sending: Option<(Token, Instant)>,
    receiving: Option<Token>,
}
impl AsRawFd for Channel {
    fn as_raw_fd(&self) -> RawFd {
        self.socket.as_raw_fd()
    }
}
impl Channel {
    fn new(socket: frame_socket::Channel) -> Self {
        Self {
            socket,
            sent: 0,
            received: 0,
            sending: None,
            receiving: None,
        }
    }
    pub fn pair() -> io::Result<(Self, Self)> {
        let (a, b) = frame_socket::Channel::pair()?;
        Ok((Self::new(a), Self::new(b)))
    }
    /// Bootstrap only after same-release GUI/worker authentication, on the
    /// protected inherited control socket. It is separate from the frame fd.
    pub fn pass(&self, control: &impl AsRawFd) -> io::Result<()> {
        frame_socket::send_channel(control, &self.socket)
    }
    pub fn receive_channel(control: &impl AsRawFd) -> io::Result<Self> {
        frame_socket::receive_channel(control).map(Self::new)
    }
    pub fn next_token(&self, revision: u64) -> io::Result<Token> {
        if revision == 0 {
            return Err(clipboard::invalid());
        }
        if self.sending.is_some() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        Ok(Token {
            serial: self.sent.checked_add(1).ok_or_else(clipboard::invalid)?,
            revision,
        })
    }
    /// Does not wait for socket space. Retain at most one unsent Prepared value
    /// in the caller, replacing it when selection/policy/focus changes.
    pub fn send(&mut self, data: &Prepared, current_revision: u64) -> io::Result<()> {
        data.offer.layout()?;
        if self.sending.is_some() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        if data.offer.token.revision != current_revision
            || current_revision == 0
            || data.offer.token.serial != self.sent.checked_add(1).ok_or_else(clipboard::invalid)?
        {
            return Err(clipboard::invalid());
        }
        self.packet(&Packet::Offer(data.offer.clone()), &[data.file.as_raw_fd()])?;
        self.sent = data.offer.token.serial;
        self.sending = Some((data.offer.token, Instant::now()));
        Ok(())
    }
    pub fn receipt(&mut self, token: Token, status: Status) -> io::Result<()> {
        if self.receiving != Some(token) {
            return Err(clipboard::invalid());
        }
        self.packet(&Packet::Receipt { token, status }, &[])?;
        self.receiving = None;
        Ok(())
    }
    pub fn timed_out(&self, deadline: Duration) -> bool {
        self.sending
            .as_ref()
            .is_some_and(|(_, at)| at.elapsed() > deadline)
    }
    fn packet(&self, packet: &Packet, files: &[RawFd]) -> io::Result<()> {
        let bytes = serde_json::to_vec(packet).map_err(|_| clipboard::invalid())?;
        if bytes.len() > METADATA_LIMIT {
            return Err(clipboard::invalid());
        }
        frame_socket::send(self.as_raw_fd(), &bytes, files)
    }
    pub fn receive(&mut self) -> io::Result<Delivery> {
        let (bytes, mut files) =
            frame_socket::receive(self.as_raw_fd(), METADATA_LIMIT, libc::MSG_DONTWAIT)?;
        let packet: Packet = serde_json::from_slice(&bytes).map_err(|_| clipboard::invalid())?;
        match packet {
            Packet::Offer(offer) => {
                offer.layout()?;
                if files.len() != 1
                    || self.receiving.is_some()
                    || offer.token.serial <= self.received
                {
                    return Err(clipboard::invalid());
                }
                self.received = offer.token.serial;
                self.receiving = Some(offer.token);
                Ok(Delivery::Offer(Incoming {
                    offer,
                    file: files.remove(0),
                }))
            }
            Packet::Receipt { token, status } => {
                if !files.is_empty() || token.serial == 0 || token.revision == 0 {
                    return Err(clipboard::invalid());
                }
                let matched = self.sending.as_ref().is_some_and(|(t, _)| *t == token);
                if matched {
                    self.sending = None;
                }
                Ok(Delivery::Receipt {
                    token,
                    status,
                    matched,
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clipboard::{Directions, Format};
    use std::{
        fs::File,
        os::{fd::FromRawFd, unix::net::UnixStream},
        process::{Command, Stdio},
    };
    fn all() -> Policy {
        let d = Directions {
            send: true,
            receive: true,
        };
        Policy {
            text: d,
            rich_text: d,
            image: d,
        }
    }
    fn offer(channel: &mut Channel) -> Incoming {
        match channel.receive().unwrap() {
            Delivery::Offer(v) => v,
            _ => panic!("expected offer"),
        }
    }
    #[test]
    fn large_bundle_uses_one_sealed_fd_and_receipt_restores_credit() {
        let (mut a, mut b) = Channel::pair().unwrap();
        let parts = [
            Part::new(Format::Text, b"fallback".to_vec()),
            Part::new(Format::Html, vec![b'x'; 900_000]),
            Part::new(Format::Rtf, vec![b'y'; 900_000]),
        ];
        let token = a.next_token(7).unwrap();
        let p = Prepared::new(token, &parts).unwrap();
        assert!(
            serde_json::to_vec(&Packet::Offer(p.offer.clone()))
                .unwrap()
                .len()
                < 1024
        );
        assert_eq!(
            unsafe { libc::pwrite(p.file.as_raw_fd(), b"X".as_ptr().cast(), 1, 0) },
            -1
        );
        assert_eq!(unsafe { libc::ftruncate(p.file.as_raw_fd(), 1) }, -1);
        a.send(&p, 7).unwrap();
        assert!(a.next_token(7).is_err());
        assert!(a.send(&p, 7).is_err());
        let incoming = offer(&mut b);
        let mapped = incoming.map(7, all(), Direction::Receive).unwrap();
        for (i, part) in parts.iter().enumerate() {
            assert_eq!(mapped.part(i).unwrap().as_ref(), part.bytes);
        }
        b.receipt(token, Status::Received).unwrap();
        assert!(matches!(
            a.receive().unwrap(),
            Delivery::Receipt { matched: true, .. }
        ));
        assert_eq!(a.next_token(8).unwrap().serial, 2);
        let shared = mapped.part(1).unwrap();
        drop(mapped);
        drop(p);
        assert_eq!(shared.as_ref().len(), 900_000);
    }
    #[test]
    fn revoke_stale_receipt_replay_and_unsealed_data_cannot_bypass_admission() {
        let (mut a, mut b) = Channel::pair().unwrap();
        let p = Prepared::new(
            a.next_token(1).unwrap(),
            &[Part::new(Format::Text, b"private".to_vec())],
        )
        .unwrap();
        a.send(&p, 1).unwrap();
        let incoming = offer(&mut b);
        assert!(incoming.map(2, all(), Direction::Receive).is_err());
        b.receipt(p.offer.token, Status::Ignored).unwrap();
        a.receive().unwrap();
        let p2 = Prepared::new(
            a.next_token(2).unwrap(),
            &[Part::new(Format::Text, b"new".to_vec())],
        )
        .unwrap();
        a.send(&p2, 2).unwrap();
        b.packet(
            &Packet::Receipt {
                token: p.offer.token,
                status: Status::Received,
            },
            &[],
        )
        .unwrap();
        assert!(matches!(
            a.receive().unwrap(),
            Delivery::Receipt { matched: false, .. }
        ));
        assert!(a.next_token(2).is_err());
        assert!(offer(&mut b)
            .map(2, Policy::default(), Direction::Receive)
            .is_err());
        b.receipt(p2.offer.token, Status::Ignored).unwrap();
        a.receive().unwrap();
        a.packet(&Packet::Offer(p2.offer.clone()), &[p2.file.as_raw_fd()])
            .unwrap();
        assert!(b.receive().is_err());
        let p3 = Prepared::new(
            a.next_token(3).unwrap(),
            &[Part::new(Format::Text, b"bad".to_vec())],
        )
        .unwrap();
        let file = File::open("/dev/zero").unwrap();
        a.packet(&Packet::Offer(p3.offer.clone()), &[file.as_raw_fd()])
            .unwrap();
        assert!(offer(&mut b).map(3, all(), Direction::Receive).is_err());
    }
    #[test]
    fn invalid_metadata_and_descriptor_counts_are_rejected() {
        let (a, mut b) = Channel::pair().unwrap();
        let p = Prepared::new(
            a.next_token(1).unwrap(),
            &[Part::new(Format::Text, b"one".to_vec())],
        )
        .unwrap();
        a.packet(&Packet::Offer(p.offer.clone()), &[]).unwrap();
        assert!(b.receive().is_err());
        a.packet(
            &Packet::Offer(p.offer.clone()),
            &[p.file.as_raw_fd(), p.file.as_raw_fd()],
        )
        .unwrap();
        assert!(b.receive().is_err());
        frame_socket::send(
            a.as_raw_fd(),
            &vec![b'x'; METADATA_LIMIT + 1],
            &[p.file.as_raw_fd()],
        )
        .unwrap();
        assert!(b.receive().is_err());
        let mut invalid = p.offer.clone();
        invalid.items[0].length = u32::MAX;
        a.packet(&Packet::Offer(invalid), &[p.file.as_raw_fd()])
            .unwrap();
        assert!(b.receive().is_err());
        // All malformed offers left the channel usable and did not consume credit.
        a.packet(&Packet::Offer(p.offer.clone()), &[p.file.as_raw_fd()])
            .unwrap();
        assert!(offer(&mut b).map(1, all(), Direction::Receive).is_ok());
    }
    #[test]
    fn image_descriptor_crosses_an_actual_process_boundary_without_control_payload() {
        let (control, child_control) = UnixStream::pair().unwrap();
        let (mut a, b) = Channel::pair().unwrap();
        let p = Prepared::new(
            a.next_token(23).unwrap(),
            &[Part {
                format: Format::Rgba,
                width: 1024,
                height: 1024,
                bytes: vec![0x7d; 4 * 1024 * 1024],
            }],
        )
        .unwrap();
        a.send(&p, 23).unwrap();
        b.pass(&control).unwrap();
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "clipboard_socket::tests::child_receiver",
                "--nocapture",
            ])
            .env("FARPANE_CLIPBOARD_TEST_CHILD", "1")
            .stdin(Stdio::from(OwnedFd::from(child_control)))
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let end = Instant::now() + Duration::from_secs(5);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() >= end {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("clipboard child timed out");
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(status.success());
        assert!(matches!(
            a.receive().unwrap(),
            Delivery::Receipt {
                matched: true,
                status: Status::Received,
                ..
            }
        ));
    }
    #[test]
    fn child_receiver() {
        if std::env::var_os("FARPANE_CLIPBOARD_TEST_CHILD").is_none() {
            return;
        }
        let control = unsafe { UnixStream::from_raw_fd(0) };
        let mut channel = Channel::receive_channel(&control).unwrap();
        let incoming = offer(&mut channel);
        let token = incoming.offer.token;
        let contents = incoming.map(23, all(), Direction::Receive).unwrap();
        assert_eq!(contents.offer.items[0].width, 1024);
        assert!(contents
            .part(0)
            .unwrap()
            .as_ref()
            .iter()
            .all(|b| *b == 0x7d));
        channel.receipt(token, Status::Received).unwrap();
    }
}
