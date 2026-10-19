//! Choose one paste chord from the currently focused X11/Xwayland application.
//! Never change focus, inspect clipboard contents, or retry with a second chord.
use enigo::Key;
use hbb_common::ResultType;
use std::sync::{mpsc, OnceLock};
use std::time::{Duration, Instant};
use x11rb::{connection::Connection, protocol::xproto::*, rust_connection::RustConnection, NONE};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shortcut { ShiftInsert, ControlShiftV }

impl Shortcut {
    pub fn keys(self) -> Vec<Key> {
        match self {
            Self::ShiftInsert => vec![Key::Shift, Key::Raw(evdev::Key::KEY_INSERT.code() + 8)],
            Self::ControlShiftV => vec![Key::Control, Key::Shift, Key::Layout('v')],
        }
    }
}

fn is_warp(class: &[u8]) -> bool {
    // Actual public Stable build's WM_CLASS, checked in the offline Warp test.
    // Exact matching avoids changing shortcuts for unrelated applications.
    class == b"dev.warp.Warp\0dev.warp.Warp\0"
}

fn focused_shortcut(connection: &RustConnection) -> ResultType<Shortcut> {
    let mut window = connection.get_input_focus()?.reply()?.focus;
    // Core focus None/PointerRoot is not evidence of an active X11 app. In
    // particular, never reuse the last Xwayland app while a Wayland app owns focus.
    for _ in 0..8 {
        if window <= 1 || connection.setup().roots.iter().any(|root| root.root == window) {
            break;
        }
        let class = connection.get_property(false, window, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 64)?.reply()?;
        if class.format == 8 && class.bytes_after == 0 && is_warp(&class.value) {
            return Ok(Shortcut::ControlShiftV);
        }
        // A class-bearing window is already the application boundary. Only
        // classless input children may inherit the parent's application class.
        if class.type_ != NONE { break; }
        let parent = connection.query_tree(window)?.reply()?.parent;
        if parent == window { break; }
        window = parent;
    }
    Ok(Shortcut::ShiftInsert)
}

struct Request { deadline: Instant, reply: mpsc::SyncSender<Shortcut> }
static WORKER: OnceLock<Option<mpsc::SyncSender<Request>>> = OnceLock::new();

fn receive_fresh(response: mpsc::Receiver<Shortcut>, deadline: Instant) -> Shortcut {
    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
        return Shortcut::ShiftInsert;
    };
    match response.recv_timeout(remaining) {
        Ok(shortcut) if Instant::now() < deadline => shortcut,
        _ => Shortcut::ShiftInsert,
    }
}

pub fn current() -> Shortcut {
    // A stalled local X server must not stall remote input or cause unbounded
    // per-commit threads. One process-owned worker, one pending request, and
    // fresh one-shot responses; timed-out focus results are never cached/reused.
    let worker = WORKER.get_or_init(|| {
        let (send, receive) = mpsc::sync_channel::<Request>(1);
        std::thread::Builder::new().name("native-paste-target".into()).spawn(move || {
            let mut connection = None;
            while let Ok(request) = receive.recv() {
                if Instant::now() >= request.deadline { continue; }
                if connection.is_none() { connection = RustConnection::connect(None).ok().map(|v| v.0); }
                let result = connection.as_ref().map(focused_shortcut);
                let shortcut = match result {
                    Some(Ok(shortcut)) => shortcut,
                    _ => { connection = None; Shortcut::ShiftInsert }
                };
                if Instant::now() < request.deadline { let _ = request.reply.try_send(shortcut); }
            }
        }).ok().map(|_| send)
    });
    let Some(worker) = worker else { return Shortcut::ShiftInsert; };
    let limit = Duration::from_millis(100);
    let deadline = Instant::now() + limit;
    let (reply, response) = mpsc::sync_channel(1);
    if worker.try_send(Request { deadline, reply }).is_err() {
        return Shortcut::ShiftInsert;
    }
    receive_fresh(response, deadline)
}

#[cfg(test)]
mod tests {
    use super::*;
    use x11rb::wrapper::ConnectionExt as _;

    #[test]
    fn expired_focus_reply_is_not_used_even_if_already_queued() {
        for expired in [false, true] {
            let (send, response) = mpsc::sync_channel(1);
            send.send(Shortcut::ControlShiftV).unwrap();
            let deadline = if expired { Instant::now() - Duration::from_secs(1) }
                           else { Instant::now() + Duration::from_secs(1) };
            assert_eq!(receive_fresh(response, deadline),
                if expired { Shortcut::ShiftInsert } else { Shortcut::ControlShiftV });
        }
    }

    #[test]
    fn class_requires_the_exact_complete_pair() {
        assert!(is_warp(b"dev.warp.Warp\0dev.warp.Warp\0"));
        for other in [b"warp\0Warp\0".as_slice(), b"dev.warp.Warp\0Chrome\0",
            b"dev.warp.Warp\0dev.warp.Warp", b"dev.warp.Warp\0dev.warp.Warp\0extra"] {
            assert!(!is_warp(other));
        }
    }

    #[test]
    #[ignore = "requires an owned Xvfb with FARPANE_PRIVATE_PASTE_TARGET_TEST=1"]
    fn private_x11_focus_and_application_boundary() {
        assert!(std::path::Path::new("/.dockerenv").is_file());
        assert_eq!(std::env::var("FARPANE_PRIVATE_PASTE_TARGET_TEST").as_deref(), Ok("1"));
        assert!(!std::path::Path::new("/dev/uinput").exists());
        let (connection, screen) = RustConnection::connect(None).unwrap();
        let root = connection.setup().roots[screen].root;
        let parent = connection.generate_id().unwrap();
        let child = connection.generate_id().unwrap();
        for (window, ancestor) in [(parent, root), (child, parent)] {
            connection.create_window(0, window, ancestor, 0, 0, 10, 10, 0,
                WindowClass::INPUT_OUTPUT, 0, &CreateWindowAux::new()).unwrap().check().unwrap();
            connection.map_window(window).unwrap().check().unwrap();
        }
        let class = |window, value: &[u8]| connection.change_property8(PropMode::REPLACE,
            window, AtomEnum::WM_CLASS, AtomEnum::STRING, value).unwrap().check().unwrap();
        class(parent, b"dev.warp.Warp\0dev.warp.Warp\0");
        connection.set_input_focus(InputFocus::PARENT, child, x11rb::CURRENT_TIME).unwrap().check().unwrap();
        assert_eq!(focused_shortcut(&connection).unwrap(), Shortcut::ControlShiftV);
        assert_eq!(current(), Shortcut::ControlShiftV);
        class(child, b"test\0GtkEntry\0");
        assert_eq!(focused_shortcut(&connection).unwrap(), Shortcut::ShiftInsert);
        connection.delete_property(child, AtomEnum::WM_CLASS.into()).unwrap().check().unwrap();
        class(parent, b"dev.warp.Warp\0Chrome\0");
        assert_eq!(current(), Shortcut::ShiftInsert);
        class(parent, b"dev.warp.Warp\0dev.warp.Warp\0");
        connection.set_input_focus(InputFocus::POINTER_ROOT, NONE, x11rb::CURRENT_TIME).unwrap().check().unwrap();
        assert_eq!(current(), Shortcut::ShiftInsert);
        connection.destroy_window(parent).unwrap().check().unwrap();
    }
}
