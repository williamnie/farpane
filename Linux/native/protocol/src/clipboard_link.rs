//! One background owner per clipboard endpoint. The latest unsent selection
//! and latest unapplied offer are each bounded to one. No GUI/control I/O waits.
use crate::{
    clipboard::{Category, Direction, Policy, Token},
    clipboard_socket::{Channel, Contents, Delivery, Prepared, Status},
};
use std::{
    io,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

type Prepare = Box<dyn FnOnce(Token) -> io::Result<Prepared> + Send>;
pub type Sink = Box<dyn Fn(Contents) -> io::Result<()> + Send>;
#[derive(Clone, Copy)]
pub struct Stamp {
    pub policy: Policy,
    pub revision: u64,
    epoch: u64,
}
struct Job {
    stamp: Stamp,
    category: Category,
    prepare: Prepare,
}
struct State {
    policy: Policy,
    revision: u64,
    epoch: u64,
    outgoing: bool,
    incoming: bool,
    stop: bool,
    job: Option<Job>,
    contents: Option<Contents>,
    note: Option<&'static str>,
    available: bool,
}
impl Default for State {
    fn default() -> Self {
        Self {
            policy: Policy::default(),
            revision: 0,
            epoch: 0,
            outgoing: false,
            incoming: false,
            stop: false,
            job: None,
            contents: None,
            note: None,
            available: true,
        }
    }
}
pub struct Link {
    state: Mutex<State>,
    wake: OwnedFd,
    direction: Direction,
    finished: AtomicBool,
    started: AtomicBool,
}
impl Link {
    pub fn new(direction: Direction) -> io::Result<Arc<Self>> {
        let fd = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Arc::new(Self {
            state: Mutex::new(State::default()),
            wake: unsafe { OwnedFd::from_raw_fd(fd) },
            direction,
            finished: AtomicBool::new(true),
            started: AtomicBool::new(false),
        }))
    }
    fn wake(&self) {
        unsafe {
            libc::write(self.wake.as_raw_fd(), (&1u64 as *const u64).cast(), 8);
        }
    }
    fn incoming_direction(&self) -> Direction {
        match self.direction {
            Direction::Send => Direction::Receive,
            Direction::Receive => Direction::Send,
        }
    }
    pub fn stamp(&self) -> Stamp {
        let s = self.state.lock().unwrap();
        Stamp {
            policy: s.policy,
            revision: s.revision,
            epoch: s.epoch,
        }
    }
    pub fn available(&self) -> bool {
        self.state.lock().unwrap().available
    }
    pub fn finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }
    pub fn note(&self) -> Option<&'static str> {
        self.state.lock().unwrap().note.take()
    }
    pub fn warn(&self, text: &'static str) {
        self.state.lock().unwrap().note = Some(text);
    }
    pub fn update(&self, policy: Policy, revision: u64, outgoing: bool, incoming: bool) {
        let mut s = self.state.lock().unwrap();
        if s.policy != policy || s.revision != revision || s.outgoing != outgoing {
            s.epoch = s.epoch.wrapping_add(1);
            s.job = None;
        }
        if s.policy != policy || s.revision != revision || !incoming {
            s.contents = None;
        }
        s.policy = policy;
        s.revision = revision;
        s.outgoing = outgoing;
        s.incoming = incoming;
        drop(s);
        self.wake();
    }
    pub fn cancel_outgoing(&self) {
        let mut s = self.state.lock().unwrap();
        s.epoch = s.epoch.wrapping_add(1);
        s.job = None;
        drop(s);
        self.wake();
    }
    fn permits_job(&self, s: &State, j: &Job) -> bool {
        !s.stop
            && s.available
            && s.outgoing
            && s.revision == j.stamp.revision
            && s.epoch == j.stamp.epoch
            && s.policy.allows(j.category, self.direction)
    }
    pub fn submit(
        &self,
        stamp: Stamp,
        category: Category,
        prepare: impl FnOnce(Token) -> io::Result<Prepared> + Send + 'static,
    ) -> bool {
        let job = Job {
            stamp,
            category,
            prepare: Box::new(prepare),
        };
        let mut s = self.state.lock().unwrap();
        if !self.permits_job(&s, &job) {
            return false;
        }
        s.job = Some(job);
        drop(s);
        self.wake();
        true
    }
    pub fn take(&self) -> Option<Contents> {
        let mut s = self.state.lock().unwrap();
        let value = s.contents.take()?;
        let (category, _) = value.offer().layout().ok()?;
        (!s.stop
            && s.incoming
            && value.offer().token.revision == s.revision
            && s.policy.allows(category, self.incoming_direction()))
        .then_some(value)
    }
    pub fn stop(&self) {
        let mut s = self.state.lock().unwrap();
        s.stop = true;
        s.job = None;
        s.contents = None;
        s.epoch = s.epoch.wrapping_add(1);
        drop(s);
        self.wake();
    }
    pub fn start(self: &Arc<Self>, channel: Channel, sink: Option<Sink>) -> io::Result<()> {
        if self.started.swap(true, Ordering::AcqRel) {
            return Err(io::ErrorKind::AlreadyExists.into());
        }
        self.finished.store(false, Ordering::Release);
        let link = self.clone();
        if let Err(error) = std::thread::Builder::new()
            .name("farpane-clipboard".into())
            .stack_size(128 * 1024)
            .spawn(move || {
                struct Finish(Arc<Link>);
                impl Drop for Finish {
                    fn drop(&mut self) {
                        let mut s = self.0.state.lock().unwrap();
                        s.available = false;
                        s.job = None;
                        s.contents = None;
                        if !s.stop {
                            s.note = Some("剪贴板通道不可用；画面继续，重新连接后可重试");
                        }
                        drop(s);
                        self.0.finished.store(true, Ordering::Release);
                    }
                }
                let _finish = Finish(link.clone());
                let _ = link.run(channel, sink);
            })
        {
            self.finished.store(true, Ordering::Release);
            let mut s = self.state.lock().unwrap();
            s.available = false;
            s.note = Some("无法启动剪贴板工作线程；画面继续");
            return Err(error);
        }
        Ok(())
    }
    fn run(&self, mut channel: Channel, sink: Option<Sink>) -> io::Result<()> {
        let mut pending: Option<(Job, Prepared)> = None;
        let mut receipt = None;
        loop {
            if self.state.lock().unwrap().stop {
                return Ok(());
            }
            if channel.timed_out(Duration::from_secs(5)) {
                return Err(io::ErrorKind::TimedOut.into());
            }
            if let Some((token, status)) = receipt {
                match channel.receipt(token, status) {
                    Ok(()) => receipt = None,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                    Err(e) => return Err(e),
                }
            }
            // Take only after credit returns. Latest selection replaces the
            // queued closure, never accumulates a history of large payloads.
            if pending.is_none() {
                let next = {
                    let mut s = self.state.lock().unwrap();
                    channel.next_token(s.revision).ok().and_then(|token| {
                        s.job
                            .take()
                            .filter(|j| self.permits_job(&s, j))
                            .map(|job| (token, job))
                    })
                };
                if let Some((token, mut job)) = next {
                    let prepare = std::mem::replace(
                        &mut job.prepare,
                        Box::new(|_| Err(io::ErrorKind::Interrupted.into())),
                    );
                    match prepare(token) {
                        Ok(value) => pending = Some((job, value)),
                        Err(_) => self.warn("剪贴板内容无效或超过上限，本次未同步"),
                    }
                }
            }
            if let Some((job, value)) = &pending {
                let s = self.state.lock().unwrap();
                if !self.permits_job(&s, job) {
                    drop(s);
                    pending = None;
                } else {
                    match channel.send(value, s.revision) {
                        Ok(()) => {
                            drop(s);
                            pending = None;
                        }
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                        Err(e) => return Err(e),
                    }
                }
            }
            let mut descriptors = [
                libc::pollfd {
                    fd: channel.as_raw_fd(),
                    events: libc::POLLIN
                        | if pending.is_some() || receipt.is_some() {
                            libc::POLLOUT
                        } else {
                            0
                        },
                    revents: 0,
                },
                libc::pollfd {
                    fd: self.wake.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            // Only active transfers need a deadline tick. Disabled/idle links
            // sleep in poll until policy, selection, close or a peer event.
            let waiting = channel.next_token(self.stamp().revision.max(1)).is_err();
            let n =
                unsafe { libc::poll(descriptors.as_mut_ptr(), 2, if waiting { 250 } else { -1 }) };
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }
            if descriptors[1].revents != 0 {
                let mut v = 0u64;
                unsafe {
                    libc::read(self.wake.as_raw_fd(), (&mut v as *mut u64).cast(), 8);
                }
            }
            if descriptors[0].revents & libc::POLLIN != 0 && receipt.is_none() {
                match channel.receive()? {
                    Delivery::Receipt {
                        status,
                        matched: true,
                        ..
                    } if status != Status::Received => self.warn("对端未接受本次剪贴板内容"),
                    Delivery::Receipt { .. } => {}
                    Delivery::Offer(value) => {
                        let token = value.offer.token;
                        let stamp = self.stamp();
                        let allowed = {
                            let s = self.state.lock().unwrap();
                            s.incoming && !s.stop
                        };
                        let mut status = Status::Ignored;
                        if allowed {
                            match value.map(stamp.revision, stamp.policy, self.incoming_direction())
                            {
                                Ok(contents) => {
                                    let (category, _) = contents.offer().layout()?;
                                    let mut s = self.state.lock().unwrap();
                                    if !s.stop
                                        && s.incoming
                                        && s.revision == token.revision
                                        && s.policy.allows(category, self.incoming_direction())
                                    {
                                        if let Some(sink) = &sink {
                                            drop(s);
                                            status = if sink(contents).is_ok() {
                                                Status::Received
                                            } else {
                                                Status::Ignored
                                            };
                                        } else {
                                            s.contents = Some(contents);
                                            status = Status::Received;
                                        }
                                    }
                                }
                                Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {}
                                Err(_) => {
                                    status = Status::Invalid;
                                    self.warn("已忽略无效或超过上限的剪贴板内容");
                                }
                            }
                        }
                        receipt = Some((token, status));
                    }
                }
            }
            if descriptors[0].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                return Err(io::ErrorKind::BrokenPipe.into());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clipboard::{Directions, Format, Part};
    use std::{sync::mpsc, thread, time::Instant};
    fn policy() -> Policy {
        Policy {
            text: Directions {
                send: true,
                receive: true,
            },
            ..Default::default()
        }
    }
    fn until(mut predicate: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !predicate() {
            assert!(
                Instant::now() < deadline,
                "clipboard owner did not progress"
            );
            thread::sleep(Duration::from_millis(2));
        }
    }
    fn receive(channel: &mut Channel) -> Delivery {
        let mut value = None;
        until(|| match channel.receive() {
            Ok(v) => {
                value = Some(v);
                true
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => false,
            Err(e) => panic!("{e}"),
        });
        value.unwrap()
    }
    fn offer(channel: &mut Channel) -> crate::clipboard_socket::Incoming {
        match receive(channel) {
            Delivery::Offer(v) => v,
            _ => panic!("expected offer"),
        }
    }
    fn submit(link: &Arc<Link>, value: &'static [u8]) {
        assert!(
            link.submit(link.stamp(), Category::Text, move |token| Prepared::new(
                token,
                &[Part::new(Format::Text, value.to_vec())]
            ))
        );
    }
    struct Owner(Arc<Link>);
    impl Drop for Owner {
        fn drop(&mut self) {
            self.0.stop();
            until(|| self.0.finished());
        }
    }
    #[test]
    fn credit_coalesces_unsent_selections_without_blocking_another_socket() {
        use std::{
            io::{Read, Write},
            os::unix::net::UnixStream,
        };
        let (a, mut peer) = Channel::pair().unwrap();
        let link = Link::new(Direction::Send).unwrap();
        let _owner = Owner(link.clone());
        link.update(policy(), 1, true, true);
        link.start(a, None).unwrap();
        submit(&link, b"first");
        let first = offer(&mut peer);
        let token = first.offer.token;
        assert_eq!(
            first
                .map(1, policy(), Direction::Receive)
                .unwrap()
                .part(0)
                .unwrap()
                .as_ref(),
            b"first"
        );
        for _ in 0..40 {
            submit(&link, b"replaced");
        }
        submit(&link, b"latest");
        assert_eq!(
            peer.receive().err().unwrap().kind(),
            io::ErrorKind::WouldBlock
        );
        let (mut control, mut worker) = UnixStream::pair().unwrap();
        control.write_all(b"input").unwrap();
        let mut bytes = [0; 5];
        worker.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, b"input");
        peer.receipt(token, Status::Received).unwrap();
        let last = offer(&mut peer);
        let token = last.offer.token;
        assert_eq!(
            last.map(1, policy(), Direction::Receive)
                .unwrap()
                .part(0)
                .unwrap()
                .as_ref(),
            b"latest"
        );
        peer.receipt(token, Status::Received).unwrap();
    }
    #[test]
    fn revision_change_during_preparation_cancels_old_bytes_and_accepts_new_work() {
        let (a, mut peer) = Channel::pair().unwrap();
        let link = Link::new(Direction::Send).unwrap();
        let _owner = Owner(link.clone());
        link.update(policy(), 1, true, true);
        link.start(a, None).unwrap();
        let (started, ready) = mpsc::channel();
        let (resume, release) = mpsc::channel();
        assert!(link.submit(link.stamp(), Category::Text, move |token| {
            started.send(()).unwrap();
            release.recv_timeout(Duration::from_secs(2)).unwrap();
            Prepared::new(token, &[Part::new(Format::Text, b"revoked".to_vec())])
        }));
        ready.recv_timeout(Duration::from_secs(2)).unwrap();
        let old = link.stamp();
        link.update(policy(), 2, true, true);
        assert!(!link.submit(old, Category::Text, |_| panic!("stale job executed")));
        submit(&link, b"current");
        resume.send(()).unwrap();
        let next = offer(&mut peer);
        assert_eq!(next.offer.token.revision, 2);
        assert_eq!(
            next.map(2, policy(), Direction::Receive)
                .unwrap()
                .part(0)
                .unwrap()
                .as_ref(),
            b"current"
        );
    }
    #[test]
    fn incoming_selection_is_rechecked_before_the_gui_takes_ownership() {
        let (a, mut peer) = Channel::pair().unwrap();
        let link = Link::new(Direction::Send).unwrap();
        let _owner = Owner(link.clone());
        link.update(policy(), 7, true, true);
        link.start(a, None).unwrap();
        let token = peer.next_token(7).unwrap();
        peer.send(
            &Prepared::new(token, &[Part::new(Format::Text, b"waiting".to_vec())]).unwrap(),
            7,
        )
        .unwrap();
        assert!(matches!(
            receive(&mut peer),
            Delivery::Receipt {
                matched: true,
                status: Status::Received,
                ..
            }
        ));
        assert!(link.state.lock().unwrap().contents.is_some());
        link.update(Policy::default(), 8, false, false);
        assert!(link.take().is_none());
        let token = peer.next_token(8).unwrap();
        peer.send(
            &Prepared::new(token, &[Part::new(Format::Text, b"disabled".to_vec())]).unwrap(),
            8,
        )
        .unwrap();
        assert!(matches!(
            receive(&mut peer),
            Delivery::Receipt {
                status: Status::Ignored,
                ..
            }
        ));
        assert!(link.take().is_none());
    }
    #[test]
    fn peer_failure_stops_only_the_clipboard_owner_and_idle_stop_finishes() {
        let (a, peer) = Channel::pair().unwrap();
        let link = Link::new(Direction::Send).unwrap();
        let _owner = Owner(link.clone());
        link.start(a, None).unwrap();
        drop(peer);
        until(|| link.finished());
        assert!(!link.available());
        assert!(link.note().is_some());
        let (a, _peer) = Channel::pair().unwrap();
        let second = Link::new(Direction::Send).unwrap();
        second.start(a, None).unwrap();
        second.stop();
        until(|| second.finished());
        assert!(second.note().is_none());
    }
}
