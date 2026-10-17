//! Explicit per-session format/direction policy. No desktop clipboard in a worker.
use super::{clipboard_wire, viewer::State, viewer_ui::NativeUi};
use crate::ui_session_interface::Session;
use base::message_proto::Clipboard;
use farpane_protocol::{
    clipboard::{Category, Direction, Format, Part, Policy as Formats, Token},
    clipboard_link::Link,
    clipboard_socket::{Channel, Prepared},
    EventKind,
};
use hbb_common::{bail, ResultType};
use std::{
    io,
    sync::{atomic::Ordering, Arc, OnceLock},
    time::{Duration, Instant},
};

#[derive(Default)]
pub struct Policy {
    pub formats: Formats,
    pub revision: u64,
}
static LINK: OnceLock<Arc<Link>> = OnceLock::new();

pub fn start(channel: Channel, state: Arc<State>, session: Session<NativeUi>) -> ResultType<()> {
    // Direction is relative to the user's Viewer: core -> GUI is Receive.
    let link = match Link::new(Direction::Receive) {
        Ok(link) => link,
        Err(_) => {
            state.emit(EventKind::ClipboardStatus {
                available: false,
                detail: "无法启动剪贴板通道；画面继续".into(),
            });
            return Ok(());
        }
    };
    LINK.set(link.clone())
        .map_err(|_| hbb_common::anyhow::anyhow!("Clipboard owner already exists"))?;
    let _ = link.start(
        channel,
        Some(Box::new(move |contents| {
            let (formats, revision) = {
                let p = state.clipboard.lock().unwrap();
                (p.formats, p.revision)
            };
            let (category, _) = contents.offer().layout()?;
            let message = clipboard_wire::encode(&contents, revision, formats, Direction::Send)?;
            super::viewer_queue::send_clipboard(&session, &state, message, category, revision)
                .map_err(|_| io::Error::from(io::ErrorKind::PermissionDenied))
        })),
    );
    Ok(())
}
pub fn stop() {
    if let Some(link) = LINK.get() {
        link.stop();
    }
}
pub fn report(state: &State) {
    if let Some(link) = LINK.get() {
        if let Some(detail) = link.note() {
            state.emit(EventKind::ClipboardStatus {
                available: link.available(),
                detail: detail.into(),
            });
        }
    }
}
fn sync(state: &State) {
    if let Some(link) = LINK.get() {
        let p = state.clipboard.lock().unwrap();
        link.update(p.formats, p.revision, true, true);
    }
}
pub fn publish(state: &State) {
    let p = state.clipboard.lock().unwrap();
    state.emit(EventKind::ClipboardPolicy {
        policy: p.formats,
        revision: p.revision,
    });
}
pub fn revoke(state: &State) {
    let mut p = state.clipboard.lock().unwrap();
    p.formats = Formats::default();
    p.revision = p.revision.saturating_add(1);
    drop(p);
    sync(state);
    publish(state);
}
pub fn configure(session: &Session<NativeUi>, state: &State, formats: Formats) -> ResultType<()> {
    let result = (|| {
        let enabled = formats.any(Direction::Send) || formats.any(Direction::Receive);
        if enabled
            && (!state.authenticated.load(Ordering::Acquire)
                || !state.permissions.lock().unwrap().clipboard)
        {
            bail!("远端未允许剪贴板共享");
        }
        if enabled && !LINK.get().is_some_and(|l| l.available()) {
            bail!("剪贴板通道不可用，请重新连接后重试");
        }
        let mut p = state.clipboard.lock().unwrap();
        p.revision = p
            .revision
            .checked_add(1)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Clipboard revision exhausted"))?;
        p.formats = formats;
        drop(p);
        sync(state);
        if session.get_toggle_option("disable-clipboard".into()) == enabled {
            session.toggle_option("disable-clipboard".into());
        }
        Ok(())
    })();
    publish(state);
    result
}
pub fn allows_send(state: &State, category: Category, revision: u64) -> bool {
    if state.stopped.load(Ordering::Acquire)
        || !state.authenticated.load(Ordering::Acquire)
        || !state.permissions.lock().unwrap().clipboard
    {
        return false;
    }
    let p = state.clipboard.lock().unwrap();
    p.revision == revision && p.formats.allows(category, Direction::Send)
}
pub fn receive(values: Vec<Clipboard>) {
    let Some(state) = super::viewer::CURRENT.get() else {
        return;
    };
    if state.stopped.load(Ordering::Acquire)
        || state.file_only.load(Ordering::Acquire)
        || !state.authenticated.load(Ordering::Acquire)
        || !state.permissions.lock().unwrap().clipboard
    {
        return;
    }
    let Some(link) = LINK.get() else {
        return;
    };
    let stamp = link.stamp();
    let Ok(values) = clipboard_wire::select(values, stamp.policy, Direction::Receive) else {
        return;
    };
    let Ok(category) = clipboard_wire::preflight(&values, stamp.policy, Direction::Receive) else {
        return;
    };
    link.submit(stamp, category, move |token| {
        prepare_received(values, stamp.policy, token, &|| {
            !state.stopped.load(Ordering::Acquire)
                && state.authenticated.load(Ordering::Acquire)
                && state.permissions.lock().unwrap().clipboard
                && state.clipboard.lock().unwrap().revision == stamp.revision
        })
    });
}

/// Conversion stays on the existing clipboard owner. GDK receives encoded
/// bytes through its bounded provider, never an unbudgeted RGBA texture whose
/// built-in serializers can allocate another full image for each paste.
fn prepare_received(
    values: Vec<Clipboard>,
    policy: Formats,
    token: Token,
    valid: &impl Fn() -> bool,
) -> io::Result<Prepared> {
    let deadline = Instant::now() + Duration::from_secs(3);
    let permitted = || Instant::now() < deadline && valid();
    if !permitted() {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let parts = clipboard_wire::decode(values, policy, Direction::Receive)?;
    let parts = parts
        .into_iter()
        .map(|part| {
            if part.format == Format::Rgba {
                // Reuse the bounded, per-row cancelable encoder also used by the
                // Host platforms; this function has no X11 or desktop side effect.
                super::clipboard_x11_writer::rgba_png(part, &permitted).map(|bytes| Part {
                    format: Format::Png,
                    width: 0,
                    height: 0,
                    bytes,
                })
            } else {
                Ok(part)
            }
        })
        .collect::<io::Result<Vec<_>>>()?;
    if !permitted() {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let prepared = Prepared::new(token, &parts)?;
    if !permitted() {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(prepared)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::ClipboardFormat;
    use farpane_protocol::clipboard::{self, Directions};
    use farpane_protocol::clipboard_socket::Delivery;
    use std::{cell::Cell, path::Path};

    fn policy() -> Formats {
        Formats {
            image: Directions {
                send: true,
                receive: true,
            },
            ..Default::default()
        }
    }
    fn rgba(width: i32, height: i32, pixels: Vec<u8>) -> Clipboard {
        Clipboard {
            format: ClipboardFormat::ImageRgba.into(),
            width,
            height,
            content: pixels.into(),
            ..Default::default()
        }
    }
    fn delivered(value: Clipboard, valid: &impl Fn() -> bool) -> io::Result<Vec<u8>> {
        let (mut a, mut b) = Channel::pair()?;
        let prepared = prepare_received(vec![value], policy(), a.next_token(1)?, valid)?;
        a.send(&prepared, 1)?;
        let Delivery::Offer(incoming) = b.receive()? else {
            panic!("missing offer")
        };
        let contents = incoming.map(1, policy(), Direction::Receive)?;
        assert_eq!(contents.offer().items[0].format, Format::Png);
        let bytes = contents.part(0).unwrap().as_ref().to_vec();
        assert!(bytes.len() <= clipboard::IMAGE_LIMIT);
        Ok(bytes)
    }
    #[test]
    fn received_rgba_crosses_channel_as_lossless_png_and_cancels_during_encoding() {
        let pixels = vec![1, 2, 3, 0, 9, 8, 7, 255];
        let png = delivered(rgba(2, 1, pixels.clone()), &|| true).unwrap();
        assert_eq!(
            image::load_from_memory(&png).unwrap().to_rgba8().as_raw(),
            &pixels
        );
        let calls = Cell::new(0);
        let result = delivered(rgba(128, 32, vec![0x7f; 128 * 32 * 4]), &|| {
            calls.set(calls.get() + 1);
            calls.get() < 20
        });
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(calls.get(), 20);
        assert_eq!(
            delivered(rgba(2, 1, vec![0; 7]), &|| true)
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
    }
    #[test]
    #[ignore = "creates maximum-pixel fixtures only in the isolated test container"]
    fn maximum_rgba_conversion_fixture() {
        assert!(Path::new("/.dockerenv").is_file());
        let path = std::env::var("FARPANE_PRIVATE_RGBA_FIXTURE").unwrap();
        let path = Path::new(&path);
        assert!(path.starts_with("/workspace/Build/Linux/") && path.is_dir());
        for (name, width, height) in [("small", 2, 1), ("maximum", 7680, 4320)] {
            let pixels: Vec<u8> = (0..width * height)
                .flat_map(|index| {
                    [
                        (index % 251) as u8,
                        ((index / width) % 251) as u8,
                        ((index / 7) % 256) as u8,
                        255,
                    ]
                })
                .collect();
            let started = Instant::now();
            let png = delivered(rgba(width, height, pixels.clone()), &|| true).unwrap();
            let elapsed = started.elapsed().as_secs_f64();
            assert_eq!(
                clipboard::png_dimensions(&png).unwrap(),
                (width as u32, height as u32)
            );
            let decoded = image::load_from_memory(&png).unwrap().to_rgba8();
            assert_eq!(decoded.as_raw(), &pixels);
            std::fs::write(path.join(format!("{name}.png")), &png).unwrap();
            std::fs::write(
                path.join(format!("{name}.json")),
                serde_json::to_vec_pretty(&serde_json::json!({
                    "result": "pass", "width": width, "height": height, "rgba_bytes": pixels.len(),
                    "png_bytes": png.len(), "prepare_and_channel_seconds": elapsed,
                    "every_decoded_pixel_matches": true,
                        "production_deadline_applied": true,
                }))
                .unwrap(),
            )
            .unwrap();
        }
    }
}
