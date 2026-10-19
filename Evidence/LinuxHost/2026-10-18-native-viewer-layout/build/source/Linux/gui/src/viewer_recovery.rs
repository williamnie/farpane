//! One user-authorized logical connection; replacements never overlap workers.
use crate::credentials::{Action, Key, Operation};
use farpane_protocol::{Snapshot, ViewerConfiguration};
use std::{
    cell::RefCell,
    time::{Duration, Instant},
};

const DELAYS_MS: [u64; 4] = [500, 1500, 3000, 6000];
#[derive(Default)]
struct Policy {
    session: u64,
    enabled: bool,
    streamed: bool,
    attempt: usize,
    due: Option<Instant>,
    deadline: Option<Instant>,
}
impl Policy {
    fn bind(&mut self, session: u64, now: Instant) {
        self.session = session;
        self.due = None;
        self.deadline = (self.enabled && self.attempt > 0).then_some(now + Duration::from_secs(30));
    }
    fn cancel(&mut self, session: u64) {
        if self.session == session {
            self.enabled = false;
            self.streamed = false;
            self.attempt = 0;
            self.due = None;
            self.deadline = None;
        }
    }
    fn presented(&mut self, session: u64) {
        if self.session == session {
            self.streamed = true;
            self.attempt = 0;
            self.due = None;
            self.deadline = None;
        }
    }
    fn terminal(&mut self, session: u64, retryable: bool, now: Instant) {
        if self.session != session {
            return;
        }
        if !retryable || !self.enabled || !self.streamed || self.attempt == DELAYS_MS.len() {
            self.cancel(session);
        } else if self.due.is_none() {
            self.deadline = None;
            self.due = Some(now + Duration::from_millis(DELAYS_MS[self.attempt]));
        }
    }
    fn take_due(&mut self, session: u64, reaped: bool, now: Instant) -> bool {
        if self.session != session
            || !self.enabled
            || !reaped
            || !self.due.is_some_and(|at| now >= at)
        {
            return false;
        }
        self.attempt += 1;
        self.due = None;
        // The retiring view cannot cancel its successor's explicit authorization.
        self.session = 0;
        true
    }
}

pub struct Recovery {
    policy: RefCell<Policy>,
    configuration: ViewerConfiguration,
    key: Result<Key, &'static str>,
}
impl Recovery {
    pub fn new(peer: &str, configuration: &ViewerConfiguration) -> Self {
        Self {
            policy: RefCell::new(Policy::default()),
            configuration: configuration.clone(),
            key: Key::new(peer, &configuration.server),
        }
    }
    pub fn bind(&self, session: u64) {
        self.policy.borrow_mut().bind(session, Instant::now());
    }
    pub fn enabled(&self) -> bool {
        self.policy.borrow().enabled
    }
    pub fn enable(&self, session: u64, value: bool, streaming: bool) {
        let mut p = self.policy.borrow_mut();
        if p.session != session {
            return;
        }
        p.cancel(session);
        p.enabled = value;
        p.streamed = streaming;
    }
    pub fn cancel(&self, session: u64) {
        self.policy.borrow_mut().cancel(session);
    }
    pub fn presented(&self, session: u64) {
        self.policy.borrow_mut().presented(session);
    }
    pub fn terminal(&self, session: u64, retryable: bool) {
        self.policy
            .borrow_mut()
            .terminal(session, retryable, Instant::now());
    }
    pub fn attempt(&self, session: u64) -> bool {
        let p = self.policy.borrow();
        p.session == session && p.enabled && p.attempt > 0 && p.deadline.is_some()
    }
    pub fn expired(&self, session: u64) -> bool {
        let p = self.policy.borrow();
        p.session == session && p.deadline.is_some_and(|at| Instant::now() >= at)
    }
    pub fn valid(&self, snapshot: &Snapshot) -> bool {
        snapshot.role.is_some()
            && snapshot.local_id == self.configuration.local_id
            && snapshot.server == self.configuration.server
    }
    pub fn lookup(&self, session: u64) -> Result<Operation, &'static str> {
        if !self.attempt(session) {
            return Err("自动重连授权已结束");
        }
        Operation::start(self.key.clone()?, Action::Lookup)
    }
    pub fn waiting(&self, session: u64) -> Option<usize> {
        let p = self.policy.borrow();
        (p.session == session && p.enabled && p.due.is_some()).then_some(p.attempt + 1)
    }
    pub fn take_due(&self, session: u64, reaped: bool) -> bool {
        self.policy
            .borrow_mut()
            .take_due(session, reaped, Instant::now())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn first_connection_and_nonretryable_close_require_user_action() {
        let now = Instant::now();
        let mut p = Policy::default();
        p.bind(1, now);
        p.enabled = true;
        p.terminal(1, true, now);
        assert!(!p.take_due(1, true, now + Duration::from_secs(1)));
        p.enabled = true;
        p.presented(1);
        p.terminal(1, false, now);
        assert!(!p.enabled);
    }
    #[test]
    fn four_delays_require_reaping_and_old_view_cannot_cancel_replacement() {
        let mut now = Instant::now();
        let mut p = Policy::default();
        p.bind(1, now);
        p.enabled = true;
        p.presented(1);
        for (i, delay) in DELAYS_MS.iter().enumerate() {
            let session = i as u64 + 1;
            p.terminal(session, true, now);
            assert!(!p.take_due(session, true, now));
            now += Duration::from_millis(*delay);
            assert!(!p.take_due(session, false, now));
            assert!(p.take_due(session, true, now));
            p.cancel(session);
            assert!(p.enabled);
            p.bind(session + 1, now);
            p.terminal(session, false, now);
            assert!(p.enabled);
        }
        p.terminal(5, true, now);
        assert!(!p.enabled);
        assert!(!p.take_due(5, true, now + Duration::from_secs(60)));
    }
    #[test]
    fn only_presentation_resets_budget_and_cancel_removes_deadline() {
        let now = Instant::now();
        let mut p = Policy::default();
        p.bind(1, now);
        p.enabled = true;
        p.presented(1);
        p.terminal(1, true, now);
        assert!(p.take_due(1, true, now + Duration::from_secs(1)));
        p.bind(2, now);
        assert_eq!(p.attempt, 1);
        assert!(p.deadline.is_some());
        p.presented(1);
        assert_eq!(p.attempt, 1);
        p.presented(2);
        assert_eq!(p.attempt, 0);
        assert!(p.deadline.is_none());
        p.terminal(2, true, now);
        p.cancel(2);
        assert!(p.due.is_none());
        assert!(!p.take_due(2, true, now + Duration::from_secs(60)));
    }
}
