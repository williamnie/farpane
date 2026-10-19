//! Metrics are replaceable observations. They must never consume the last slot
//! needed by authentication, permissions, replies or lifecycle events.
use std::collections::VecDeque;

/// Called while the caller holds its queue lock, immediately before insertion.
/// A false result drops incoming metrics; critical-only overflow remains fatal.
pub fn admit<T>(
    queue: &mut VecDeque<T>,
    incoming_metrics: bool,
    is_metrics: impl Fn(&T) -> bool,
) -> bool {
    if incoming_metrics || queue.len() >= crate::MAX_EVENTS {
        queue.retain(|item| !is_metrics(item));
    }
    queue.len() < crate::MAX_EVENTS
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn metrics_flood_and_full_queue_keep_critical_events_in_order() {
        let mut queue = VecDeque::new();
        for n in 0..crate::MAX_EVENTS - 1 {
            assert!(admit(&mut queue, false, |item: &(usize, bool)| item.1));
            queue.push_back((n, false));
        }
        for n in 0..1000 {
            assert!(admit(&mut queue, true, |item| item.1));
            queue.push_back((n, true));
            assert_eq!(queue.len(), crate::MAX_EVENTS);
        }
        assert!(admit(&mut queue, false, |item| item.1));
        queue.push_back((crate::MAX_EVENTS - 1, false));
        assert_eq!(
            queue.into_iter().collect::<Vec<_>>(),
            (0..crate::MAX_EVENTS)
                .map(|n| (n, false))
                .collect::<Vec<_>>()
        );
    }
    #[test]
    fn metrics_do_not_displace_critical_events_or_mask_real_overflow() {
        let mut queue: VecDeque<_> = (0..crate::MAX_EVENTS).map(|n| (n, false)).collect();
        let original = queue.clone();
        assert!(!admit(&mut queue, true, |item| item.1));
        assert!(!admit(&mut queue, false, |item| item.1));
        assert_eq!(queue, original);
    }
}
