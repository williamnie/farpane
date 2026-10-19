use farpane_protocol::{Event, EventKind, Phase, Snapshot};

#[derive(Default)]
pub struct Model {
    pub snapshot: Snapshot,
    pub session: u64,
    pub generation: u64,
    pub sequence: u64,
    pub phase: Phase,
    pub detail: String,
    pub needs_snapshot: bool,
}

impl Model {
    pub fn start_session(&mut self, session: u64) {
        self.session = session;
        self.generation = 0;
        self.sequence = 0;
        self.phase = Phase::Resolving;
        self.detail.clear();
    }
    pub fn apply(&mut self, event: Event) -> bool {
        if event.session != self.session
            || event.generation < self.generation
            || event.sequence <= self.sequence
        {
            return false;
        }
        if event.generation > self.generation {
            self.generation = event.generation;
            if self.session != 0 {
                self.phase = Phase::AwaitingFrame;
            }
        }
        self.sequence = event.sequence;
        match event.event {
            EventKind::Snapshot(snapshot) => {
                self.snapshot = snapshot;
                self.needs_snapshot = false;
            }
            EventKind::Phase { phase, detail } => {
                // Only the local renderer can attest that a frame was presented.
                self.phase = if phase == Phase::Streaming {
                    Phase::AwaitingFrame
                } else {
                    phase
                };
                self.detail = detail;
            }
            EventKind::ResyncRequired => self.needs_snapshot = true,
            _ => {}
        }
        true
    }
    pub fn presented(&mut self, session: u64, generation: u64) -> bool {
        if session == 0
            || session != self.session
            || generation != self.generation
            || !matches!(
                self.phase,
                Phase::AwaitingFrame | Phase::Streaming | Phase::Recovering
            )
        {
            return false;
        }
        self.phase = Phase::Streaming;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn phase(session: u64, generation: u64, sequence: u64, phase: Phase) -> Event {
        Event {
            session,
            generation,
            sequence,
            event: EventKind::Phase {
                phase,
                detail: String::new(),
            },
        }
    }
    #[test]
    fn authentication_does_not_claim_picture_and_old_events_cannot_replace_new_session() {
        let mut model = Model::default();
        model.start_session(8);
        assert!(model.apply(phase(8, 1, 1, Phase::Streaming)));
        assert_eq!(model.phase, Phase::AwaitingFrame);
        assert!(!model.presented(7, 1));
        assert!(model.presented(8, 1));
        assert_eq!(model.phase, Phase::Streaming);
        model.start_session(9);
        assert!(!model.apply(phase(8, 2, 99, Phase::Failed)));
        assert_eq!(model.phase, Phase::Resolving);
    }
    #[test]
    fn stale_generation_replayed_sequence_and_frames_after_cancel_are_rejected() {
        let mut model = Model::default();
        model.start_session(3);
        assert!(model.apply(phase(3, 2, 4, Phase::AwaitingFrame)));
        assert!(!model.apply(phase(3, 1, 5, Phase::Failed)));
        assert!(!model.apply(phase(3, 2, 4, Phase::Failed)));
        assert!(model.apply(phase(3, 2, 5, Phase::Ended)));
        assert!(!model.presented(3, 2));
    }
}
