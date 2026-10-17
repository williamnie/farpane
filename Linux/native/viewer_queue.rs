//! Credits cover the entire legacy async send, not just the GUI control socket.
use crate::client::Data;
use hbb_common::protobuf::Message as _;
use std::sync::{Arc, Mutex};
const MAX_ITEMS: usize = 256;
const MAX_BYTES: usize = 1024 * 1024;
#[derive(Default)]
pub struct Budget {
    items: usize,
    bytes: usize,
}
pub struct Credit {
    budget: Arc<Mutex<Budget>>,
    bytes: usize,
    clipboard: Option<(farpane_protocol::clipboard::Category, u64)>,
}
impl Credit {
    /// Recheck just before the network send, after any queueing delay.
    pub fn valid(&self) -> bool {
        self.clipboard.is_none_or(|(category, revision)| {
            super::viewer::CURRENT.get().is_some_and(|state| {
                super::viewer_clipboard::allows_send(state, category, revision)
            })
        })
    }
}
impl Drop for Credit {
    fn drop(&mut self) {
        let mut b = self.budget.lock().unwrap();
        b.items -= 1;
        b.bytes -= self.bytes;
    }
}
impl Budget {
    fn reserve(budget: &Arc<Mutex<Self>>, bytes: usize) -> Option<Arc<Credit>> {
        Self::reserve_with(budget, bytes, MAX_ITEMS, MAX_BYTES, None)
    }
    fn reserve_with(
        budget: &Arc<Mutex<Self>>,
        bytes: usize,
        max_items: usize,
        max_bytes: usize,
        clipboard: Option<(farpane_protocol::clipboard::Category, u64)>,
    ) -> Option<Arc<Credit>> {
        let mut b = budget.lock().unwrap();
        if b.items >= max_items || bytes > max_bytes || b.bytes > max_bytes - bytes {
            return None;
        }
        b.items += 1;
        b.bytes += bytes;
        Some(Arc::new(Credit {
            budget: budget.clone(),
            bytes,
            clipboard,
        }))
    }
}
/// A separate one-item budget keeps clipboard bursts out of input/auth credits.
/// The clipboard owner may wait; the network and GTK threads never wait here.
pub fn send_clipboard(
    session: &crate::ui_session_interface::Session<super::viewer_ui::NativeUi>,
    state: &super::viewer::State,
    message: base::message_proto::Message,
    category: farpane_protocol::clipboard::Category,
    revision: u64,
) -> hbb_common::ResultType<()> {
    use std::time::{Duration, Instant};
    let bytes = message.compute_size() as usize + 128;
    let began = Instant::now();
    loop {
        if !super::viewer_clipboard::allows_send(state, category, revision) {
            hbb_common::bail!("Clipboard permission changed");
        }
        if let Some(credit) = Budget::reserve_with(
            &state.clipboard_budget,
            bytes,
            1,
            farpane_protocol::clipboard::IMAGE_LIMIT + 4096,
            Some((category, revision)),
        ) {
            let sender = session
                .sender
                .read()
                .unwrap()
                .clone()
                .ok_or_else(|| hbb_common::anyhow::anyhow!("Clipboard network is not ready"))?;
            sender
                .send(Data::NativeQueued(Box::new(Data::Message(message)), credit))
                .map_err(|_| hbb_common::anyhow::anyhow!("Clipboard network ended"))?;
            return Ok(());
        }
        if began.elapsed() >= Duration::from_secs(2) {
            hbb_common::bail!("Clipboard network queue stalled");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
pub fn wrap(data: Data) -> Option<Data> {
    let state = super::viewer::CURRENT.get()?;
    let bytes = match &data {
        Data::Message(message) => message.compute_size() as usize + 128,
        Data::Close | Data::ContinueInsecureConnection | Data::RejectInsecureConnection => 128,
        Data::Login((a, b, c, _)) => a.len() + b.len() + c.len() + 128,
        Data::NativeQueued(..) => {
            state.fail("Nested Viewer command envelope");
            return None;
        }
        _ => 64 * 1024,
    };
    let credit = Budget::reserve(&state.command_budget, bytes);
    if credit.is_none() {
        state.fail("Viewer network command queue exceeded its budget");
    }
    credit.map(|credit| Data::NativeQueued(Box::new(data), credit))
}
pub fn unwrap(data: Data) -> (Data, Option<Arc<Credit>>) {
    match data {
        Data::NativeQueued(data, credit) => (*data, Some(credit)),
        data => (data, None),
    }
}
/// File I/O runs outside the network loop and waits for credits instead of
/// overflowing the upstream unbounded channel. Credits survive the actual send.
pub fn send_file(
    session: &crate::ui_session_interface::Session<super::viewer_ui::NativeUi>,
    state: &super::viewer::State,
    message: base::message_proto::Message,
) -> hbb_common::ResultType<()> {
    use std::{
        sync::atomic::Ordering,
        time::{Duration, Instant},
    };
    let bytes = message.compute_size() as usize + 128;
    if bytes > super::files::PACKET_LIMIT {
        hbb_common::bail!("File packet exceeds limit");
    }
    let began = Instant::now();
    loop {
        if state.stopped.load(Ordering::Acquire) || !state.permissions.lock().unwrap().file {
            hbb_common::bail!("File session ended or permission was revoked");
        }
        if let Some(credit) = Budget::reserve(&state.command_budget, bytes) {
            let sender = session
                .sender
                .read()
                .unwrap()
                .clone()
                .ok_or_else(|| hbb_common::anyhow::anyhow!("File network is not ready"))?;
            sender
                .send(Data::NativeQueued(Box::new(Data::Message(message)), credit))
                .map_err(|_| hbb_common::anyhow::anyhow!("File network ended"))?;
            return Ok(());
        }
        if began.elapsed() >= Duration::from_secs(2) {
            hbb_common::bail!("File network queue stalled");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn network_credits_remain_charged_until_last_consumer_finishes() {
        let budget = Arc::new(Mutex::new(Budget::default()));
        let credit = Budget::reserve(&budget, MAX_BYTES).unwrap();
        let active_send = credit.clone();
        drop(credit);
        assert!(Budget::reserve(&budget, 1).is_none());
        drop(active_send);
        assert_eq!(budget.lock().unwrap().bytes, 0);
        let credits: Vec<_> = (0..MAX_ITEMS)
            .map(|_| Budget::reserve(&budget, 1).unwrap())
            .collect();
        assert!(Budget::reserve(&budget, 1).is_none());
        drop(credits);
        assert_eq!(budget.lock().unwrap().items, 0);
    }
    #[test]
    fn clipboard_credit_has_its_own_single_slot_and_policy_is_checked_again() {
        use farpane_protocol::clipboard::{Category, Directions};
        use std::sync::atomic::Ordering;
        let state = super::super::viewer::State::default();
        state.authenticated.store(true, Ordering::Release);
        {
            let mut p = state.clipboard.lock().unwrap();
            p.formats.image = Directions {
                send: true,
                receive: false,
            };
            p.revision = 3;
        }
        assert!(super::super::viewer_clipboard::allows_send(
            &state,
            Category::Image,
            3
        ));
        let limit = farpane_protocol::clipboard::IMAGE_LIMIT + 4096;
        let credit = Budget::reserve_with(
            &state.clipboard_budget,
            limit,
            1,
            limit,
            Some((Category::Image, 3)),
        )
        .unwrap();
        assert!(Budget::reserve_with(&state.clipboard_budget, 1, 1, limit, None).is_none());
        let input = Budget::reserve(&state.command_budget, 128).unwrap();
        assert!(input.valid());
        state.clipboard.lock().unwrap().revision = 4;
        assert!(!super::super::viewer_clipboard::allows_send(
            &state,
            Category::Image,
            3
        ));
        state.permissions.lock().unwrap().clipboard = false;
        assert!(!super::super::viewer_clipboard::allows_send(
            &state,
            Category::Image,
            4
        ));
        drop(credit);
        assert_eq!(state.clipboard_budget.lock().unwrap().bytes, 0);
        assert_eq!(state.command_budget.lock().unwrap().bytes, 128);
    }
}
