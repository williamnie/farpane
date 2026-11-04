use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Completion {
    pub receiving: bool,
    pub directory: Option<PathBuf>,
    pub skipped: bool,
}

impl Completion {
    pub fn title(&self) -> &'static str {
        if self.skipped {
            "文件传输完成（部分内容已跳过）"
        } else if self.receiving {
            "文件接收成功"
        } else {
            "文件发送成功"
        }
    }
}

#[derive(Default)]
pub struct Tracker {
    active: HashMap<i32, Completion>,
}

impl Tracker {
    pub fn start(&mut self, job: i32, receiving: bool, directory: Option<PathBuf>) {
        self.active.entry(job).or_insert(Completion {
            receiving,
            directory: directory.filter(|p| p.is_absolute()),
            skipped: false,
        });
    }

    pub fn update(&mut self, job: i32, status: &str) -> Option<Completion> {
        match status {
            "completed" | "completed_with_skips" | "sent" => {
                let mut completion = self.active.remove(&job)?;
                completion.skipped = status == "completed_with_skips";
                Some(completion)
            }
            "failed" | "cancelled" | "rejected" | "skipped" | "timed_out" | "interrupted" => {
                self.active.remove(&job);
                None
            }
            _ => None,
        }
    }
}

#[derive(Default)]
pub struct HostTracker {
    seen: Option<HashSet<i32>>,
    tracker: Tracker,
}

impl HostTracker {
    pub fn update<'a>(
        &mut self,
        tasks: impl Iterator<Item = (i32, bool, Option<PathBuf>, &'a str)>,
    ) -> Vec<Completion> {
        let initial = self.seen.is_none();
        let seen = self.seen.get_or_insert_with(Default::default);
        let mut present = HashSet::new();
        let mut completions = Vec::new();
        for (id, receiving, directory, status) in tasks {
            present.insert(id);
            if seen.insert(id) {
                self.tracker.start(id, receiving, directory);
            }
            if let Some(completion) = self.tracker.update(id, status) {
                if !initial {
                    completions.push(completion);
                }
            }
        }
        seen.retain(|id| present.contains(id));
        self.tracker.active.retain(|id, _| present.contains(id));
        completions
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_ignores_history_and_handles_fast_jobs_and_changed_settings() {
        let mut tracker = HostTracker::default();
        assert!(tracker
            .update(
                [
                    (1, true, Some("/tmp/old".into()), "completed"),
                    (2, true, Some("/tmp/selected".into()), "receiving")
                ]
                .into_iter()
            )
            .is_empty());
        let completed = tracker.update(
            [
                (1, true, Some("/tmp/old".into()), "completed"),
                (2, true, Some("/tmp/changed".into()), "completed"),
                (3, false, None, "sent"),
            ]
            .into_iter(),
        );
        assert_eq!(completed.len(), 2);
        assert_eq!(completed[0].directory, Some("/tmp/selected".into()));
        assert!(!completed[1].receiving);
        assert!(tracker
            .update([(3, false, None, "sent")].into_iter())
            .is_empty());
    }

    #[test]
    fn completion_uses_each_jobs_destination_and_is_once_only() {
        let mut tracker = Tracker::default();
        tracker.start(1, true, Some("/tmp/first".into()));
        tracker.start(2, true, Some("/tmp/second".into()));
        assert!(tracker.update(1, "receiving").is_none());
        assert_eq!(
            tracker.update(2, "completed").unwrap().directory,
            Some("/tmp/second".into())
        );
        assert!(tracker.update(2, "completed").is_none());
        assert_eq!(
            tracker.update(1, "completed").unwrap().directory,
            Some("/tmp/first".into())
        );
    }

    #[test]
    fn failed_and_cancelled_jobs_never_notify_success() {
        for status in [
            "failed",
            "cancelled",
            "rejected",
            "skipped",
            "timed_out",
            "interrupted",
        ] {
            let mut tracker = Tracker::default();
            tracker.start(1, true, None);
            assert!(tracker.update(1, status).is_none());
            assert!(tracker.update(1, "completed").is_none());
        }
    }

    #[test]
    fn skipped_content_is_not_reported_as_full_success() {
        let mut tracker = Tracker::default();
        tracker.start(1, false, None);
        let completion = tracker.update(1, "completed_with_skips").unwrap();
        assert!(completion.skipped);
        assert!(!completion.receiving);
        assert!(completion.title().contains("跳过"));
        assert!(tracker.update(99, "completed").is_none());
    }
}
