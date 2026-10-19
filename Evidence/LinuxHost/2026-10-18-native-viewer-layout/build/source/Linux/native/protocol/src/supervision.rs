//! Host maintenance policy. Unknown activity is never interpreted as idle.
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Activity {
    pub schema: u32,
    /// Process start ticks from /proc/self/stat; binds a snapshot to its owner.
    pub process_start: u64,
    pub generation: u64,
    /// CLOCK_MONOTONIC milliseconds, shared across these local processes.
    pub observed_ms: u64,
    pub inbound: u32,
    pub pending_approvals: u32,
    pub file_jobs: u32,
    pub media_owners: u32,
}
impl Activity {
    pub fn busy(&self) -> bool {
        self.inbound > 0
            || self.pending_approvals > 0
            || self.file_jobs > 0
            || self.media_owners > 0
    }
    pub fn valid_at(&self, now_ms: u64, process_start: u64) -> bool {
        self.schema == 1
            && self.process_start == process_start
            && self.generation > 0
            && now_ms
                .checked_sub(self.observed_ms)
                .is_some_and(|age| age <= 3_000)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Health {
    Responsive,
    /// A separate authenticated health probe timed out, not just a missing snapshot.
    TimedOut,
    /// Authentication/version errors require an operator or coordinated upgrade.
    Rejected,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Keep,
    RestartIdle,
    RecoverUnresponsive,
    ReapExited,
}

#[derive(Default)]
pub struct Supervisor {
    saw_activity: bool,
    unresponsive_since: Option<u64>,
    consecutive_timeouts: u32,
}
impl Supervisor {
    pub fn decide(
        &mut self,
        now_ms: u64,
        last_restart_ms: u64,
        process_start: u64,
        process_exited: bool,
        activity: Option<&Activity>,
        health: Health,
    ) -> Decision {
        if process_exited {
            return Decision::ReapExited;
        }
        if let Some(activity) = activity.filter(|a| a.valid_at(now_ms, process_start)) {
            self.unresponsive_since = None;
            self.consecutive_timeouts = 0;
            if activity.busy() {
                self.saw_activity = true;
                return Decision::Keep;
            }
            let elapsed = now_ms.saturating_sub(last_restart_ms);
            if elapsed >= 3_600_000 || (self.saw_activity && elapsed >= 60_000) {
                self.saw_activity = false;
                return Decision::RestartIdle;
            }
            return Decision::Keep;
        }
        match health {
            Health::TimedOut => {
                let since = *self.unresponsive_since.get_or_insert(now_ms);
                self.consecutive_timeouts = self.consecutive_timeouts.saturating_add(1);
                // Explicit failure recovery may interrupt a connection and must
                // be logged as such. It is not ordinary idle maintenance.
                if now_ms.saturating_sub(since) >= 60_000 && self.consecutive_timeouts >= 6 {
                    return Decision::RecoverUnresponsive;
                }
            }
            Health::Responsive | Health::Rejected => {
                self.unresponsive_since = None;
                self.consecutive_timeouts = 0;
            }
        }
        Decision::Keep
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot(now: u64) -> Activity {
        Activity {
            schema: 1,
            process_start: 42,
            generation: 1,
            observed_ms: now,
            ..Default::default()
        }
    }
    #[test]
    fn a_long_active_connection_survives_hourly_maintenance() {
        let mut supervisor = Supervisor::default();
        for now in [0, 60_001, 3_600_001, 7_200_001] {
            let mut activity = snapshot(now);
            activity.inbound = 1;
            assert_eq!(
                supervisor.decide(now, 0, 42, false, Some(&activity), Health::Responsive),
                Decision::Keep
            );
        }
        assert_eq!(
            supervisor.decide(
                7_200_002,
                0,
                42,
                false,
                Some(&snapshot(7_200_002)),
                Health::Responsive
            ),
            Decision::RestartIdle
        );
    }
    #[test]
    fn unknown_stale_wrong_owner_and_auth_rejection_never_become_idle() {
        for health in [Health::Responsive, Health::Rejected] {
            let mut supervisor = Supervisor::default();
            for now in [4_000_000, 8_000_000, 9_000_000] {
                assert_eq!(
                    supervisor.decide(now, 0, 42, false, None, health),
                    Decision::Keep
                );
                assert_eq!(
                    supervisor.decide(now, 0, 43, false, Some(&snapshot(now)), health),
                    Decision::Keep
                );
                assert_eq!(
                    supervisor.decide(now, 0, 42, false, Some(&snapshot(1)), health),
                    Decision::Keep
                );
            }
        }
    }
    #[test]
    fn approvals_files_and_retiring_media_all_prevent_maintenance() {
        for kind in 0..3 {
            let mut supervisor = Supervisor::default();
            let mut activity = snapshot(4_000_000);
            match kind {
                0 => activity.pending_approvals = 1,
                1 => activity.file_jobs = 1,
                _ => activity.media_owners = 1,
            }
            assert_eq!(
                supervisor.decide(4_000_000, 0, 42, false, Some(&activity), Health::Responsive),
                Decision::Keep
            );
        }
    }
    #[test]
    fn recovery_requires_sustained_independent_health_failures() {
        let mut supervisor = Supervisor::default();
        for i in 0..6 {
            assert_eq!(
                supervisor.decide(i * 10_000, 0, 42, false, None, Health::TimedOut),
                Decision::Keep
            );
        }
        assert_eq!(
            supervisor.decide(60_000, 0, 42, false, None, Health::TimedOut),
            Decision::RecoverUnresponsive
        );
        assert_eq!(
            supervisor.decide(60_001, 0, 42, false, None, Health::Responsive),
            Decision::Keep
        );
        assert_eq!(
            supervisor.decide(60_002, 0, 42, false, None, Health::TimedOut),
            Decision::Keep
        );
        assert_eq!(
            supervisor.decide(60_003, 0, 42, true, None, Health::Rejected),
            Decision::ReapExited
        );
    }
}
