//! GDK owns the local selection. Async MIME reads have byte, lifetime and policy bounds.
use adw::prelude::*;
use farpane_protocol::{
    clipboard::{Category, Direction, Directions, Format, Part, Policy},
    clipboard_link::Link,
    clipboard_socket::{Contents, Prepared},
    Command,
};
use gtk::{gdk, glib};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::Arc,
    time::Duration,
};
const SUMMARY: &str = "文本 64 KiB · 富文本各 1 MiB\n图片 128 MiB · SVG 4 MiB";

pub struct Controls {
    widget: glib::WeakRef<gtk::Widget>,
    clipboard: gdk::Clipboard,
    changed: RefCell<Option<glib::SignalHandlerId>>,
    active: RefCell<Option<(glib::WeakRef<gtk::Window>, glib::SignalHandlerId)>>,
    task: RefCell<Option<glib::JoinHandle<()>>>,
    serial: Cell<u64>,
    revision: Cell<u64>,
    policy: Cell<Policy>,
    allowed: Cell<bool>,
    updating: Cell<bool>,
    pending: Cell<bool>,
    checks: [[gtk::CheckButton; 2]; 3],
    status: gtk::Label,
    // A weak provider identity prevents echoes without retaining old image data.
    last: glib::WeakRef<gdk::ContentProvider>,
    link: Arc<Link>,
    command: Box<dyn Fn(Command)>,
}
impl Controls {
    pub fn smoke_set(&self, enabled: bool) {
        if crate::viewer::smoke_directory().is_some() {
            self.set_checks(Policy {
                text: Directions {
                    send: enabled,
                    receive: enabled,
                },
                ..Default::default()
            });
            self.request();
        }
    }
    pub fn smoke_policy(&self, policy: Policy) {
        if crate::viewer::smoke_directory().is_some() {
            self.set_checks(policy);
            self.request();
        }
    }
    pub fn new(
        widget: &impl IsA<gtk::Widget>,
        button: &gtk::MenuButton,
        link: Arc<Link>,
        command: impl Fn(Command) + 'static,
    ) -> Rc<Self> {
        let widget = widget.as_ref();
        let panel = gtk::Grid::builder()
            .row_spacing(12)
            .column_spacing(16)
            .margin_top(16)
            .margin_bottom(16)
            .margin_start(16)
            .margin_end(16)
            .build();
        panel.attach(&gtk::Label::new(Some("同步类型")), 0, 0, 1, 1);
        panel.attach(&gtk::Label::new(Some("发送到远端")), 1, 0, 1, 1);
        panel.attach(&gtk::Label::new(Some("接收到本机")), 2, 0, 1, 1);
        let checks = std::array::from_fn(|row| {
            std::array::from_fn(|col| {
                let checkbox = gtk::CheckButton::new();
                checkbox.set_widget_name(&format!("clipboard-{row}-{col}"));
                checkbox.set_tooltip_text(Some(&format!(
                    "{}{}",
                    ["文本", "富文本", "图片"][row],
                    ["发送到远端", "接收到本机"][col]
                )));
                panel.attach(&checkbox, col as i32 + 1, row as i32 + 1, 1, 1);
                checkbox
            })
        });
        for (row, label) in ["文本", "富文本（HTML / RTF）", "图片（PNG / RGBA / SVG）"]
            .into_iter()
            .enumerate()
        {
            let label = gtk::Label::new(Some(label));
            label.set_xalign(0.);
            panel.attach(&label, 0, row as i32 + 1, 1, 1);
        }
        let status = gtk::Label::new(Some("共享默认关闭，请按需开启"));
        status.set_xalign(0.);
        status.set_wrap(true);
        status.set_max_width_chars(48);
        panel.attach(&status, 0, 4, 3, 1);
        let limits = gtk::Label::new(Some(SUMMARY));
        limits.set_xalign(0.);
        limits.add_css_class("dim-label");
        panel.attach(&limits, 0, 5, 3, 1);
        let popover = gtk::Popover::new();
        popover.set_child(Some(&panel));
        button.set_popover(Some(&popover));
        let this = Rc::new(Self {
            widget: widget.downgrade(),
            clipboard: widget.clipboard(),
            changed: RefCell::new(None),
            active: RefCell::new(None),
            task: RefCell::new(None),
            serial: Cell::new(0),
            revision: Cell::new(0),
            policy: Cell::new(Policy::default()),
            allowed: Cell::new(false),
            updating: Cell::new(false),
            pending: Cell::new(false),
            checks,
            status,
            last: glib::WeakRef::new(),
            link,
            command: Box::new(command),
        });
        this.permission(false);
        for checkbox in this.checks.iter().flatten() {
            let weak = Rc::downgrade(&this);
            checkbox.connect_toggled(move |_| {
                if let Some(c) = weak.upgrade() {
                    if !c.updating.get() {
                        c.request();
                    }
                }
            });
        }
        let weak = Rc::downgrade(&this);
        *this.changed.borrow_mut() = Some(this.clipboard.connect_changed(move |_| {
            if let Some(c) = weak.upgrade() {
                c.read();
            }
        }));
        let weak = Rc::downgrade(&this);
        widget.connect_realize(move |widget| {
            if let Some(c) = weak.upgrade() {
                if let Some(window) = widget.root().and_downcast::<gtk::Window>() {
                    let weak = Rc::downgrade(&c);
                    let id = window.connect_is_active_notify(move |window| {
                        if let Some(c) = weak.upgrade() {
                            c.cancel();
                            c.sync();
                            if window.is_active() {
                                c.poll();
                                c.read();
                            }
                        }
                    });
                    *c.active.borrow_mut() = Some((window.downgrade(), id));
                }
            }
        });
        this
    }
    fn focused(&self) -> bool {
        self.widget
            .upgrade()
            .and_then(|w| w.root())
            .and_downcast::<gtk::Window>()
            .is_some_and(|w| w.is_active())
    }
    fn set_checks(&self, p: Policy) {
        self.updating.set(true);
        for (row, d) in self.checks.iter().zip([p.text, p.rich_text, p.image]) {
            row[0].set_active(d.send);
            row[1].set_active(d.receive);
        }
        self.updating.set(false);
    }
    fn sensitive(&self, value: bool) {
        for c in self.checks.iter().flatten() {
            c.set_sensitive(value);
        }
    }
    fn request(&self) {
        let d = |i: usize| Directions {
            send: self.checks[i][0].is_active(),
            receive: self.checks[i][1].is_active(),
        };
        let policy = Policy {
            text: d(0),
            rich_text: d(1),
            image: d(2),
        };
        self.cancel();
        self.pending.set(true);
        self.sync();
        self.sensitive(false);
        (self.command)(Command::SetClipboard { policy });
    }
    fn cancel(&self) {
        self.serial.set(self.serial.get().wrapping_add(1));
        if let Some(task) = self.task.borrow_mut().take() {
            task.abort();
        }
        self.link.cancel_outgoing();
    }
    fn sync(&self) {
        let ready = self.allowed.get() && !self.pending.get();
        self.link.update(
            self.policy.get(),
            self.revision.get(),
            ready && self.focused(),
            ready,
        );
    }
    pub fn permission(&self, allowed: bool) {
        self.allowed.set(allowed);
        self.sensitive(allowed && self.link.available() && !self.pending.get());
        if !allowed {
            self.cancel();
            self.policy.set(Policy::default());
            self.pending.set(false);
            self.set_checks(Policy::default());
        }
        self.sync();
    }
    pub fn policy(self: &Rc<Self>, policy: Policy, revision: u64) {
        self.cancel();
        self.revision.set(revision);
        self.policy.set(policy);
        self.pending.set(false);
        self.set_checks(policy);
        self.sensitive(self.allowed.get() && self.link.available());
        self.sync();
        self.status.set_text(
            if policy.any(Direction::Send) || policy.any(Direction::Receive) {
                "已按所选类型和方向共享"
            } else {
                "剪贴板共享已关闭"
            },
        );
        self.read();
    }
    pub fn status(&self, available: bool, detail: &str) {
        self.status.set_text(detail);
        if !available {
            self.cancel();
            self.link
                .update(Policy::default(), self.revision.get(), false, false);
            self.sensitive(false);
        }
    }
    /// Called after control events so revocation wins over an unconsumed offer.
    pub fn poll(&self) {
        if let Some(note) = self.link.note() {
            self.status(self.link.available(), note);
        }
        if !self.focused() || !self.allowed.get() || self.pending.get() {
            return;
        }
        if let Some(contents) = self.link.take() {
            match provider(&contents) {
                Ok(provider) => {
                    self.cancel();
                    self.last.set(Some(&provider));
                    if self.clipboard.set_content(Some(&provider)).is_err() {
                        self.status.set_text("无法写入本机剪贴板，本次未同步");
                    }
                }
                Err(_) => self.status.set_text("剪贴板格式不可用，本次未同步"),
            }
        }
    }
    fn read(self: &Rc<Self>) {
        self.cancel();
        if !self.allowed.get()
            || self.pending.get()
            || !self.policy.get().any(Direction::Send)
            || !self.focused()
            || !self.link.available()
        {
            return;
        }
        if self.clipboard.is_local()
            && self
                .clipboard
                .content()
                .is_some_and(|p| self.last.upgrade().as_ref() == Some(&p))
        {
            return;
        }
        let serial = self.serial.get();
        let stamp = self.link.stamp();
        let clipboard = self.clipboard.clone();
        let weak = Rc::downgrade(self);
        let task = glib::MainContext::default().spawn_local(async move {
            let result = glib::future_with_timeout(
                Duration::from_secs(3),
                read_selection(clipboard, stamp.policy),
            )
            .await;
            let Some(c) = weak.upgrade() else {
                return;
            };
            if c.serial.get() != serial
                || c.revision.get() != stamp.revision
                || !c.allowed.get()
                || c.pending.get()
                || !c.focused()
            {
                return;
            }
            match result {
                Ok(Ok(Some((category, parts)))) => {
                    c.link
                        .submit(stamp, category, move |token| Prepared::new(token, &parts));
                }
                Ok(Ok(None)) => {}
                Ok(Err(reason)) => c.status.set_text(reason),
                Err(_) => c.status.set_text("读取本机剪贴板超时，本次未同步"),
            }
        });
        *self.task.borrow_mut() = Some(task);
    }
}
fn provider(contents: &Contents) -> Result<gdk::ContentProvider, ()> {
    let mut values = Vec::new();
    let mut size = 0;
    for (i, item) in contents.offer().items.iter().enumerate() {
        // The worker converts RGBA with bounded, cancelable encoding before
        // IPC. Never let a texture bypass the byte provider's storage and
        // output permits, including for an unexpected same-release offer.
        if item.format == Format::Rgba {
            return Err(());
        }
        let bytes = glib::Bytes::from_owned(contents.part(i).ok_or(())?);
        size += bytes.len();
        let mimes: &[&str] = match item.format {
            Format::Text => &["text/plain;charset=utf-8", "text/plain"],
            Format::Html => &["text/html"],
            Format::Rtf => &["application/rtf", "text/rtf"],
            Format::Png => &["image/png"],
            Format::Svg => &["image/svg+xml"],
            Format::Rgba => unreachable!(),
        };
        for mime in mimes {
            values.push((*mime, bytes.clone()));
        }
    }
    crate::clipboard_provider::new(values, size)
}
async fn read_selection(
    clipboard: gdk::Clipboard,
    policy: Policy,
) -> Result<Option<(Category, Vec<Part>)>, &'static str> {
    let original = clipboard.formats();
    let formats = original.clone().union_serialize_mime_types();
    let has = |s: &str| formats.contain_mime_type(s);
    if policy.image.send {
        for (mime, format) in [("image/png", Format::Png), ("image/svg+xml", Format::Svg)] {
            if original.contain_mime_type(mime) {
                return Ok(Some((
                    Category::Image,
                    vec![read_part(&clipboard, mime, format).await?],
                )));
            }
        }
        // A local Texture may only advertise a GType. Serialize that as PNG,
        // but never pick a synthesized PNG ahead of an actual SVG MIME offer.
        if has("image/png") {
            return Ok(Some((
                Category::Image,
                vec![read_part(&clipboard, "image/png", Format::Png).await?],
            )));
        }
    }
    let plain = ["text/plain;charset=utf-8", "text/plain"]
        .into_iter()
        .find(|s| has(s));
    if policy.rich_text.send && (has("text/html") || has("application/rtf") || has("text/rtf")) {
        let mut parts = Vec::new();
        if has("text/html") {
            parts.push(read_part(&clipboard, "text/html", Format::Html).await?);
        }
        if let Some(mime) = ["application/rtf", "text/rtf"].into_iter().find(|s| has(s)) {
            parts.push(read_part(&clipboard, mime, Format::Rtf).await?);
        }
        if let Some(mime) = plain {
            parts.push(read_part(&clipboard, mime, Format::Text).await?);
        }
        return Ok(Some((Category::RichText, parts)));
    }
    if policy.text.send {
        if let Some(mime) = plain {
            return Ok(Some((
                Category::Text,
                vec![read_part(&clipboard, mime, Format::Text).await?],
            )));
        }
    }
    Ok(None)
}
async fn read_part(
    clipboard: &gdk::Clipboard,
    mime: &str,
    format: Format,
) -> Result<Part, &'static str> {
    let (stream, _) = clipboard
        .read_future(&[mime], glib::Priority::DEFAULT)
        .await
        .map_err(|_| "无法读取所选剪贴板格式")?;
    let limit = format.limit();
    let mut bytes = Vec::new();
    loop {
        let chunk = stream
            .read_bytes_future(
                (64 * 1024).min(limit + 1 - bytes.len()),
                glib::Priority::DEFAULT,
            )
            .await
            .map_err(|_| "读取本机剪贴板失败")?;
        if chunk.is_empty() {
            break;
        }
        let needed = bytes.len() + chunk.len();
        if needed > limit {
            return Err("剪贴板内容超过该格式上限，本次未同步");
        }
        if needed > bytes.capacity() {
            let capacity = needed.max(bytes.capacity().saturating_mul(2)).min(limit);
            bytes
                .try_reserve_exact(capacity - bytes.len())
                .map_err(|_| "没有足够内存读取剪贴板")?;
        }
        bytes.extend_from_slice(chunk.as_ref());
    }
    let _ = stream.close_future(glib::Priority::DEFAULT).await;
    if bytes.is_empty() {
        return Err("剪贴板内容为空，本次未同步");
    }
    Ok(Part::new(format, bytes))
}
impl Drop for Controls {
    fn drop(&mut self) {
        self.cancel();
        self.link.stop();
        if let Some(id) = self.changed.get_mut().take() {
            self.clipboard.disconnect(id);
        }
        if let Some((window, id)) = self.active.get_mut().take() {
            if let Some(window) = window.upgrade() {
                if unsafe {
                    glib::gobject_ffi::g_signal_handler_is_connected(
                        window.as_ptr().cast(),
                        id.as_raw(),
                    )
                } != 0
                {
                    window.disconnect(id);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use farpane_protocol::clipboard_socket::{Channel, Delivery};
    use std::path::Path;

    fn policy() -> Policy {
        Policy {
            image: Directions {
                send: true,
                receive: true,
            },
            ..Default::default()
        }
    }
    fn mapped(part: Part) -> Contents {
        let (mut a, mut b) = Channel::pair().unwrap();
        let prepared = Prepared::new(a.next_token(1).unwrap(), &[part]).unwrap();
        a.send(&prepared, 1).unwrap();
        let Delivery::Offer(incoming) = b.receive().unwrap() else {
            panic!("missing mapping")
        };
        incoming.map(1, policy(), Direction::Receive).unwrap()
    }

    #[test]
    #[ignore = "requires the isolated Xvfb test container and core-generated PNG fixtures"]
    fn rgba_is_preconverted_and_png_provider_is_bounded() {
        assert_eq!(
            std::env::var("FARPANE_PRIVATE_CLIPBOARD_TEST").as_deref(),
            Ok("1")
        );
        let root = std::env::var("FARPANE_PRIVATE_RGBA_FIXTURE").unwrap();
        let root = Path::new(&root);
        gtk::init().unwrap();
        let clipboard = gdk::Display::default().unwrap().clipboard();
        let raw = mapped(Part {
            format: Format::Rgba,
            width: 1,
            height: 1,
            bytes: vec![0; 4],
        });
        assert!(
            provider(&raw).is_err(),
            "raw RGBA must not bypass bounded PNG provider"
        );
        drop(raw);
        glib::MainContext::default().block_on(async {
            crate::clipboard_provider::verify_streaming_limits().await;
            for (name, width, height) in [("small", 2, 1), ("maximum", 7680, 4320)] {
                let bytes = std::fs::read(root.join(format!("{name}.png"))).unwrap();
                let contents = mapped(Part::new(Format::Png, bytes.clone()));
                let value = provider(&contents).unwrap();
                clipboard.set_content(Some(&value)).unwrap();
                drop(contents);
                drop(value);
                let png = read_part(&clipboard, "image/png", Format::Png).await.unwrap();
                assert_eq!(png.bytes, bytes, "provider must preserve core-encoded PNG");
                let texture = glib::future_with_timeout(
                    Duration::from_secs(3), clipboard.read_texture_future(),
                ).await.unwrap().unwrap().unwrap();
                let mut download = gdk::TextureDownloader::new(&texture);
                download.set_format(gdk::MemoryFormat::R8g8b8a8);
                let (pixels, stride) = download.download_bytes();
                assert_eq!((texture.width(), texture.height()), (width, height));
                for row in 0..height as usize {
                    for col in 0..width as usize {
                        let index = row * width as usize + col;
                        assert_eq!(&pixels[row * stride + col * 4..row * stride + col * 4 + 4],
                            &[(index % 251) as u8, (row % 251) as u8, ((index / 7) % 256) as u8, 255]);
                    }
                }
                clipboard.set_content(None::<&gdk::ContentProvider>).unwrap();
                println!("PASS: worker {name} RGBA -> actual memfd -> GDK PNG read -> every decoded pixel");
            }
            let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"1\"></svg>";
            clipboard.set_content(Some(&gdk::ContentProvider::for_bytes(
                "image/svg+xml", &glib::Bytes::from_static(svg)))).unwrap();
            let (category, parts) = read_selection(clipboard.clone(), policy()).await.unwrap().unwrap();
            assert_eq!(category, Category::Image);
            assert_eq!(parts.len(), 1);
            assert_eq!(parts[0].format, Format::Svg);
            assert_eq!(parts[0].bytes, svg);
            clipboard.set_content(None::<&gdk::ContentProvider>).unwrap();
        });
        let mut retained = Vec::new();
        for index in 0..3 {
            let contents = mapped(Part::new(
                Format::Png,
                std::fs::read(root.join("max-bytes.png")).unwrap(),
            ));
            let next = provider(&contents);
            if index < 2 {
                retained.push(next.unwrap());
            } else {
                assert!(
                    next.is_err(),
                    "third retained maximum image bypassed provider storage limit"
                );
            }
        }
        drop(retained);
        let contents = mapped(Part::new(
            Format::Png,
            std::fs::read(root.join("max-bytes.png")).unwrap(),
        ));
        assert!(
            provider(&contents).is_ok(),
            "storage must recover when old readers release"
        );
        println!("PASS: raw RGBA refused, third retained 128 MiB PNG refused, storage recovers after release");
    }
}
