#[path = "hud_smoke.rs"]
mod hud_smoke;
use crate::{
    app::label,
    model::Model,
    viewer_bridge::{Bridge, Frame},
};
use adw::prelude::*;
use farpane_protocol::{
    frame_socket::Packet, Command, EventKind, Phase, Secret, ViewerConfiguration,
};
use gtk::{gdk, glib};
use std::{
    cell::{Cell, RefCell},
    rc::{Rc, Weak},
    time::Duration,
};

pub struct View {
    pub root: gtk::Box,
    bridge: Bridge,
    model: RefCell<Model>,
    status: gtk::Label,
    toolbar_toggle: gtk::ToggleButton,
    picture: gtk::Picture,
    canvas: gtk::Stack,
    gpu: Rc<crate::gpu_renderer::View>,
    backend: gtk::Label,
    hud: crate::viewer_hud::Hud,
    diagnostics: Rc<crate::diagnostics::Log>,
    displays: gtk::DropDown,
    display_ids: RefCell<Vec<i32>>,
    updating: Cell<bool>,
    authentication: gtk::Box,
    password: gtk::PasswordEntry,
    prompt: gtk::Label,
    submit: gtk::Button,
    secrets: Rc<crate::auth_secrets::Controls>,
    challenge: Cell<u8>,
    closing: Cell<bool>,
    exited: Cell<bool>,
    pending_frame: RefCell<Option<Frame>>,
    painted_generation: Cell<u64>,
    painted_received: Cell<Option<std::time::Instant>>,
    presentation_skipped: Cell<u64>,
    clock: RefCell<Option<(gdk::FrameClock, glib::SignalHandlerId)>>,
    home: Box<dyn Fn()>,
    connected: Box<dyn Fn(&str)>,
    peer_name: RefCell<String>,
    title: adw::WindowTitle,
    peer: String,
    remembered: Cell<bool>,
    retry: gtk::Button,
    reconnect: Box<dyn Fn(bool, bool)>,
    recovery: Rc<crate::viewer_recovery::Recovery>,
    recovery_toggle: gtk::CheckButton,
    recovery_lookup: RefCell<Option<crate::credentials::Operation>>,
    recovery_password_attempted: Cell<bool>,
    retryable: Cell<bool>,
    host: Weak<crate::host::Ui>,
    input: RefCell<Option<Rc<crate::viewer_input::Controls>>>,
    permissions: RefCell<farpane_protocol::Permissions>,
    audio: gtk::ToggleButton,
    clipboard: RefCell<Option<Rc<crate::viewer_clipboard::Controls>>>,
    cursors: crate::viewer_cursor::Cursors,
    smoke: RefCell<Option<Smoke>>,
}
pub(crate) fn smoke_directory() -> Option<std::path::PathBuf> {
    test_directory("FARPANE_VIEWER_SMOKE_DIR")
}
pub(crate) fn test_directory(variable: &str) -> Option<std::path::PathBuf> {
    let directory = std::env::var_os(variable)?;
    if !std::path::Path::new("/.dockerenv").exists()
        || !std::env::current_exe()
            .ok()?
            .starts_with("/opt/farpane-native-test/releases/")
    {
        return None;
    }
    Some(directory.into())
}
pub(crate) fn smoke_trim(directory: &std::path::Path, stage: &str) {
    if smoke_directory().is_none()
        || std::env::var("FARPANE_NATIVE_MEMORY_PROBE").as_deref() != Ok("trim")
    {
        return;
    }
    let _ = std::fs::read("/proc/self/smaps").and_then(|bytes| {
        std::fs::write(directory.join(format!("{stage}-pre-trim-smaps.txt")), bytes)
    });
    #[cfg(target_env = "gnu")]
    {
        let began = std::time::Instant::now();
        let released = unsafe { libc::malloc_trim(0) };
        let report = serde_json::json!({"released":released,"milliseconds":began.elapsed().as_secs_f64()*1000.});
        let _ = std::fs::write(
            directory.join(format!("{stage}-trim.json")),
            serde_json::to_vec_pretty(&report).unwrap(),
        );
    }
}
struct Smoke {
    cycle: u32,
    directory: std::path::PathBuf,
    events: Vec<serde_json::Value>,
    passwords: u32,
    frames: u32,
    gpu_frames: u32,
    first_paint: Option<std::time::Instant>,
    last_report: usize,
    captured: bool,
    clipboard_configured: bool,
    clipboard_disabled: bool,
    secret_requested: bool,
    secret_cancelled: bool,
    secret_confirmed: bool,
}
impl View {
    pub fn new(
        peer: String,
        audio: bool,
        configuration: ViewerConfiguration,
        recovery: Rc<crate::viewer_recovery::Recovery>,
        host: &Rc<crate::host::Ui>,
        connected: impl Fn(&str) + 'static,
        reconnect: impl Fn(bool, bool) + 'static,
        home: impl Fn() + 'static,
    ) -> Result<Rc<Self>, Box<dyn std::error::Error + Send + Sync>> {
        let file_configuration = configuration.clone();
        let secret_key = crate::credentials::Key::new(&peer, &configuration.server);
        let file_peer = peer.clone();
        let bridge = Bridge::start(peer.clone(), audio, configuration)?;
        recovery.bind(bridge.session);
        let mut model = Model::default();
        model.start_session(bridge.session);
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let header = adw::HeaderBar::new();
        let title = adw::WindowTitle::new("FarPane", &peer);
        header.set_title_widget(Some(&title));
        let back = gtk::Button::with_label("断开并返回");
        header.pack_start(&back);
        let fullscreen = gtk::Button::from_icon_name("view-fullscreen-symbolic");
        fullscreen.set_tooltip_text(Some("全屏"));
        fullscreen.connect_clicked(|button| {
            if let Some(window) = button.root().and_downcast::<gtk::Window>() {
                if window.is_fullscreen() {
                    window.unfullscreen();
                } else {
                    window.fullscreen();
                }
            }
        });
        header.pack_end(&fullscreen);
        let toolbar_toggle = gtk::ToggleButton::builder()
            .icon_name("pan-up-symbolic")
            .tooltip_text("收起工具栏")
            .build();
        toolbar_toggle.set_widget_name("viewer-toolbar-toggle");
        header.pack_end(&toolbar_toggle);
        header.pack_end(&host.sessions_button());
        root.append(&header);
        let tools = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let toolbar_revealer = gtk::Revealer::builder()
            .reveal_child(true)
            .transition_type(gtk::RevealerTransitionType::None)
            .child(&tools)
            .build();
        toolbar_revealer.set_widget_name("viewer-toolbar");
        let toolbar = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        toolbar.set_margin_start(16);
        toolbar.set_margin_end(16);
        toolbar.set_margin_top(8);
        toolbar.set_margin_bottom(8);
        let status = label("正在连接…", "status-pill");
        status.set_hexpand(true);
        status.set_ellipsize(gtk::pango::EllipsizeMode::End);
        toolbar.append(&status);
        let retry = gtk::Button::with_label("重新连接");
        retry.add_css_class("suggested-action");
        retry.set_visible(false);
        toolbar.append(&retry);
        let displays = gtk::DropDown::from_strings(&["等待显示器"]);
        displays.set_sensitive(false);
        toolbar.append(&displays);
        let exclusive = gtk::ToggleButton::with_label("独占键盘");
        toolbar.append(&exclusive);
        let clipboard = gtk::MenuButton::builder()
            .icon_name("edit-paste-symbolic")
            .tooltip_text("剪贴板共享")
            .build();
        toolbar.append(&clipboard);
        let sound = gtk::ToggleButton::with_label("音频");
        sound.set_active(audio);
        toolbar.append(&sound);
        let files = gtk::Button::with_label("文件");
        files.connect_clicked(move |button| {
            if let Some(parent) = button.root().and_downcast::<gtk::Window>() {
                if let Err(error) =
                    crate::file_view::open(&parent, file_peer.clone(), file_configuration.clone())
                {
                    let dialog = adw::MessageDialog::new(
                        Some(&parent),
                        Some("文件连接未启动"),
                        Some(&error.to_string()),
                    );
                    dialog.add_response("close", "关闭");
                    dialog.present();
                }
            }
        });
        toolbar.append(&files);
        let refresh = gtk::Button::from_icon_name("view-refresh-symbolic");
        refresh.set_widget_name("viewer-refresh");
        refresh.set_tooltip_text(Some("刷新画面"));
        toolbar.append(&refresh);
        let metrics = gtk::ToggleButton::with_label("HUD");
        metrics.set_widget_name("viewer-hud-toggle");
        toolbar.append(&metrics);
        let diagnostics = crate::diagnostics::Log::new();
        toolbar.append(&diagnostics.button());
        tools.append(&toolbar);
        let recovery_toggle =
            gtk::CheckButton::with_label("断线后使用系统密码库自动重连（最多 4 次）");
        recovery_toggle.set_widget_name("viewer-auto-reconnect");
        recovery_toggle.set_margin_start(12);
        recovery_toggle.set_margin_bottom(6);
        recovery_toggle.set_tooltip_text(Some("仅对当前设备和服务器生效。没有已保存密码、密码库锁定或需要再次确认时停止；取消勾选可随时关闭。"));
        recovery_toggle.set_active(recovery.enabled());
        tools.append(&recovery_toggle);
        root.append(&toolbar_revealer);
        let authentication = gtk::Box::new(gtk::Orientation::Vertical, 12);
        authentication.add_css_class("card");
        authentication.set_halign(gtk::Align::Center);
        authentication.set_margin_top(24);
        let prompt = label("输入远端设备的密码", "card-title");
        let password = gtk::PasswordEntry::builder().show_peek_icon(true).build();
        let submit = gtk::Button::with_label("验证并连接");
        let secrets = crate::auth_secrets::Controls::new(&password, secret_key);
        submit.add_css_class("suggested-action");
        authentication.append(&prompt);
        authentication.append(&password);
        authentication.append(&secrets.root);
        authentication.append(&submit);
        authentication.set_visible(false);
        root.append(&authentication);
        let overlay = gtk::Overlay::new();
        overlay.set_vexpand(true);
        overlay.set_hexpand(true);
        overlay.add_css_class("viewer-background");
        let picture = gtk::Picture::builder()
            .can_shrink(true)
            .content_fit(gtk::ContentFit::Contain)
            .build();
        let gpu = crate::gpu_renderer::View::new();
        let canvas = gtk::Stack::new();
        canvas.set_transition_type(gtk::StackTransitionType::None);
        canvas.add_named(&gpu.area, Some("gpu"));
        canvas.add_named(&picture, Some("software"));
        canvas.set_visible_child_name("gpu");
        overlay.set_child(Some(&canvas));
        let hud = crate::viewer_hud::Hud::new();
        overlay.add_overlay(&hud.label);
        root.append(&overlay);
        let backend = label("正在协商媒体后端", "muted");
        backend.set_margin_start(16);
        backend.set_margin_top(8);
        backend.set_margin_bottom(8);
        root.append(&backend);
        let cursors = crate::viewer_cursor::Cursors::new(&canvas);
        let view = Rc::new(Self {
            root,
            bridge,
            model: RefCell::new(model),
            status,
            toolbar_toggle: toolbar_toggle.clone(),
            picture,
            canvas,
            gpu,
            backend,
            hud,
            diagnostics,
            displays,
            display_ids: RefCell::new(vec![]),
            updating: Cell::new(false),
            authentication,
            password,
            prompt,
            submit,
            secrets,
            challenge: Cell::new(0),
            closing: Cell::new(false),
            exited: Cell::new(false),
            pending_frame: RefCell::new(None),
            painted_generation: Cell::new(0),
            painted_received: Cell::new(None),
            presentation_skipped: Cell::new(0),
            clock: RefCell::new(None),
            home: Box::new(home),
            connected: Box::new(connected),
            peer_name: RefCell::new(String::new()),
            title,
            peer,
            remembered: Cell::new(false),
            retry: retry.clone(),
            reconnect: Box::new(reconnect),
            recovery,
            recovery_toggle: recovery_toggle.clone(),
            recovery_lookup: RefCell::new(None),
            recovery_password_attempted: Cell::new(false),
            retryable: Cell::new(false),
            host: Rc::downgrade(host),
            input: RefCell::new(None),
            permissions: RefCell::new(farpane_protocol::Permissions::default()),
            audio: sound.clone(),
            clipboard: RefCell::new(None),
            cursors,
            smoke: RefCell::new(smoke_directory().map(|directory| Smoke {
                cycle: {
                    static CYCLE: std::sync::atomic::AtomicU32 =
                        std::sync::atomic::AtomicU32::new(0);
                    CYCLE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                },
                directory,
                events: vec![],
                passwords: 0,
                frames: 0,
                gpu_frames: 0,
                first_paint: None,
                last_report: usize::MAX,
                captured: false,
                clipboard_configured: false,
                clipboard_disabled: false,
                secret_requested: false,
                secret_cancelled: false,
                secret_confirmed: false,
            })),
        });
        let weak = Rc::downgrade(&view);
        toolbar_toggle.connect_toggled(move |button| {
            let collapsed = button.is_active();
            button.set_icon_name(if collapsed {
                "pan-down-symbolic"
            } else {
                "pan-up-symbolic"
            });
            button.set_tooltip_text(Some(if collapsed {
                "展开工具栏"
            } else {
                "收起工具栏"
            }));
            // Changing the image allocation must not carry held input or a
            // shortcut inhibitor into the next coordinate transform.
            if let Some(view) = weak.upgrade() {
                if let Some(input) = view.input.borrow().as_ref() {
                    input.release();
                }
            }
            toolbar_revealer.set_reveal_child(!collapsed);
            // With transition type None the revealer can retain its measured
            // height. Remove it from layout as well as hiding its children.
            toolbar_revealer.set_visible(!collapsed);
        });
        let ready = Rc::downgrade(&view);
        let painted = Rc::downgrade(&view);
        let failed = Rc::downgrade(&view);
        view.gpu.bind(
            move |renderer, reason| {
                if let Some(v) = ready.upgrade() {
                    let software = renderer.software;
                    if let Some(smoke) = v.smoke.borrow().as_ref() {
                        let _ = std::fs::write(
                            smoke.directory.join("renderer.json"),
                            serde_json::to_vec_pretty(&renderer).unwrap(),
                        );
                    }
                    v.backend.set_text(reason);
                    v.backend.set_tooltip_text(Some(reason));
                    v.bridge.renderer_ready(renderer);
                    if software {
                        // No DMA-BUF work was submitted. Release the unused GLArea
                        // context instead of keeping it alive behind the picture.
                        let weak = Rc::downgrade(&v);
                        glib::idle_add_local_once(move || {
                            if let Some(v) = weak.upgrade() {
                                v.canvas.set_visible_child_name("software");
                                v.canvas.remove(&v.gpu.area);
                            }
                        });
                    }
                }
            },
            move |generation, width, height, received| {
                if let Some(v) = painted.upgrade() {
                    v.pending_paint(generation, received);
                    if let Some(smoke) = v.smoke.borrow_mut().as_mut() {
                        smoke.frames += 1;
                        smoke.gpu_frames += 1;
                    }
                    if let Some(input) = v.input.borrow().as_ref() {
                        input.set_image(width, height);
                    }
                }
            },
            move |reason| {
                if let Some(v) = failed.upgrade() {
                    v.fail(reason);
                }
            },
        );
        let weak = Rc::downgrade(&view);
        retry.connect_clicked(move |_| {
            if let Some(v) = weak.upgrade() {
                if !v.closing.get()
                    && matches!(v.model.borrow().phase, Phase::Ended | Phase::Failed)
                {
                    (v.reconnect)(false, v.audio.is_active());
                }
            }
        });
        let weak = Rc::downgrade(&view);
        recovery_toggle.connect_toggled(move |button| {
            if let Some(v) = weak.upgrade() {
                let was_enabled = v.recovery.enabled();
                v.recovery_lookup.borrow_mut().take();
                v.recovery.enable(
                    v.bridge.session,
                    button.is_active(),
                    v.model.borrow().phase == Phase::Streaming,
                );
                if was_enabled && !button.is_active() {
                    v.status.set_text("自动重连已关闭，可手动继续连接");
                }
            }
        });
        let weak = Rc::downgrade(&view);
        *view.input.borrow_mut() = Some(crate::viewer_input::Controls::new(
            &view.canvas,
            &overlay,
            &exclusive,
            move |input| {
                if let Some(v) = weak.upgrade() {
                    v.send(Command::Input(input));
                }
            },
        ));
        let weak = Rc::downgrade(&view);
        *view.clipboard.borrow_mut() = Some(crate::viewer_clipboard::Controls::new(
            &view.canvas,
            &clipboard,
            view.bridge
                .clipboard
                .clone()
                .expect("Viewer clipboard endpoint"),
            move |command| {
                if let Some(v) = weak.upgrade() {
                    v.send(command);
                }
            },
        ));
        let weak = Rc::downgrade(&view);
        back.connect_clicked(move |_| {
            if let Some(v) = weak.upgrade() {
                v.close();
            }
        });
        let weak = Rc::downgrade(&view);
        view.submit.connect_clicked(move |_| {
            if let Some(v) = weak.upgrade() {
                v.authenticate();
            }
        });
        let weak = Rc::downgrade(&view);
        view.password.connect_activate(move |_| {
            if let Some(v) = weak.upgrade() {
                v.authenticate();
            }
        });
        let weak = Rc::downgrade(&view);
        refresh.connect_clicked(move |_| {
            if let Some(v) = weak.upgrade() {
                v.send(Command::RefreshFrame);
            }
        });
        let weak = Rc::downgrade(&view);
        sound.connect_toggled(move |button| {
            if let Some(v) = weak.upgrade() {
                if v.updating.get() {
                    return;
                }
                v.send(Command::SetAudio {
                    enabled: button.is_active(),
                });
            }
        });
        let weak = Rc::downgrade(&view);
        metrics.connect_toggled(move |button| {
            if let Some(v) = weak.upgrade() {
                v.hud.enable(button.is_active());
                v.diagnostics.mark(if button.is_active() {
                    "HUD 指标采样已开启"
                } else {
                    "HUD 指标采样已关闭"
                });
                v.send(Command::Metrics {
                    enabled: button.is_active(),
                });
            }
        });
        let weak = Rc::downgrade(&view);
        view.displays.connect_selected_notify(move |dropdown| {
            if let Some(v) = weak.upgrade() {
                if !v.updating.get() {
                    if let Some(index) = v.display_ids.borrow().get(dropdown.selected() as usize) {
                        v.send(Command::SelectDisplay { index: *index });
                    }
                }
            }
        });
        let weak = Rc::downgrade(&view);
        view.canvas.connect_realize(move |picture| {
            if let Some(v) = weak.upgrade() {
                if let Some(clock) = picture.frame_clock() {
                    let weak = Rc::downgrade(&v);
                    let handler = clock.connect_after_paint(move |_| {
                        if let Some(v) = weak.upgrade() {
                            let generation = v.painted_generation.replace(0);
                            let received = v.painted_received.take();
                            if generation != 0
                                && v.canvas.is_mapped()
                                && v.model.borrow_mut().presented(v.bridge.session, generation)
                            {
                                v.hud.presented(received);
                                v.recovery.presented(v.bridge.session);
                                v.status.set_text("已连接 · 画面正常");
                                if !v.remembered.replace(true) {
                                    (v.connected)(&v.peer_name.borrow());
                                }
                                if let Some(input) = v.input.borrow().as_ref() {
                                    input.set_ready(v.permissions.borrow().keyboard);
                                }
                                if let Some(smoke) = v.smoke.borrow_mut().as_mut() {
                                    smoke
                                        .first_paint
                                        .get_or_insert_with(std::time::Instant::now);
                                }
                            } else if generation != 0 {
                                v.presentation_skipped
                                    .set(v.presentation_skipped.get().saturating_add(1));
                            }
                        }
                    });
                    *v.clock.borrow_mut() = Some((clock, handler));
                }
            }
        });
        hud_smoke::attach(&view);
        let weak = Rc::downgrade(&view);
        glib::timeout_add_local(Duration::from_millis(16), move || {
            let Some(v) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            v.poll();
            glib::ControlFlow::Continue
        });
        Ok(view)
    }
    pub fn close(&self) {
        self.recovery.cancel(self.bridge.session);
        self.recovery_lookup.borrow_mut().take();
        self.hud.enable(false);
        self.diagnostics.mark("用户请求结束会话");
        self.secrets.stop();
        self.closing.set(true);
        self.cursors.clear();
        self.retry.set_sensitive(false);
        if let Some(clipboard) = self.clipboard.borrow().as_ref() {
            clipboard.permission(false);
        }
        if let Some(input) = self.input.borrow().as_ref() {
            input.set_ready(false);
        }
        self.gpu.stop();
        self.bridge.stop();
        self.status.set_text("正在结束会话…");
        if self.has_exited() {
            (self.home)();
        }
    }
    pub fn has_exited(&self) -> bool {
        self.exited.get() && self.gpu.idle()
    }
    fn send(&self, command: Command) {
        let input = matches!(command, Command::Input(_));
        if let Err(error) = self.bridge.send(command) {
            if input {
                self.fail(&error.to_string());
            } else {
                self.status.set_text(&error.to_string());
            }
        }
    }
    fn authenticate(&self) {
        self.authenticate_with_recovery(false);
    }
    fn authenticate_with_recovery(&self, automatic: bool) {
        if !automatic && self.recovery.attempt(self.bridge.session) {
            self.stop_recovery("已改为手动认证");
        }
        let text = self.password.text().to_string();
        if self.challenge.get() == 2 && !crate::auth_secrets::valid_two_factor(&text) {
            self.prompt
                .set_text(crate::auth_secrets::TWO_FACTOR_FORMAT_ERROR);
            self.password.grab_focus();
            return;
        }
        if self.challenge.get() != 3 && (text.is_empty() || text.len() > 4096) {
            return;
        }
        self.secrets.attempt(self.challenge.get(), &text);
        let command = match self.challenge.get() {
            1 => Command::Password {
                password: Secret(text),
            },
            2 => Command::TwoFactor { code: Secret(text) },
            3 => Command::ConfirmInsecure { accept: true },
            _ => return,
        };
        self.send(command);
        self.password.set_text("");
        self.authentication.set_visible(false);
        self.challenge.set(0);
    }
    fn challenge(&self, kind: u8, detail: &str) {
        self.secrets.challenge(kind == 1);
        self.challenge.set(kind);
        self.prompt.set_text(detail);
        self.password.set_visible(kind != 3);
        self.submit.set_label(if kind == 3 {
            "允许本次连接"
        } else {
            "验证并连接"
        });
        self.authentication.set_visible(true);
        self.password.grab_focus();
    }
    fn pending_paint(&self, generation: u64, received: std::time::Instant) {
        if self.painted_received.replace(Some(received)).is_some() {
            self.presentation_skipped
                .set(self.presentation_skipped.get().saturating_add(1));
        }
        self.painted_generation.set(generation);
    }
    fn poll(&self) {
        self.hud.tick(
            self.bridge
                .skipped()
                .saturating_add(self.presentation_skipped.get()),
            self.gpu.loans(),
        );
        self.diagnostics.tick(&self.hud);
        self.secrets.poll();
        self.gpu.tick();
        let update = self.bridge.take();
        for event in update.events {
            if let Some(smoke) = self.smoke.borrow_mut().as_mut() {
                if smoke.events.len() < 128 {
                    smoke.events.push(serde_json::to_value(&event).unwrap());
                }
            }
            if !self.model.borrow_mut().apply(event.clone()) {
                continue;
            }
            self.diagnostics.record(&event.event);
            match event.event {
                EventKind::ConnectionEnded { retryable } => self.retryable.set(retryable),
                EventKind::Peer { name } => {
                    self.title.set_subtitle(&if name.is_empty() {
                        self.peer.clone()
                    } else {
                        format!("{name} · {}", self.peer)
                    });
                    *self.peer_name.borrow_mut() = name;
                }
                EventKind::Phase { phase, detail } => {
                    if phase != Phase::Streaming {
                        self.toolbar_toggle.set_active(false);
                    }
                    if phase == Phase::Authenticating && self.challenge.get() == 1 {
                        // Password submission or remote manual approval ends
                        // the previous password prompt. Preserve any already
                        // submitted save candidate, invalidate late lookups.
                        self.challenge.set(0);
                        self.password.set_text("");
                        self.authentication.set_visible(false);
                        self.secrets.challenge(false);
                    }
                    if phase == Phase::AwaitingFrame {
                        self.recovery_lookup.borrow_mut().take();
                        self.challenge.set(0);
                        self.password.set_text("");
                        self.authentication.set_visible(false);
                        self.secrets.authenticated();
                    }
                    self.status.set_text(&detail);
                    if let Some(clipboard) = self.clipboard.borrow().as_ref() {
                        clipboard.permission(
                            matches!(phase, Phase::AwaitingFrame | Phase::Streaming)
                                && self.permissions.borrow().clipboard,
                        );
                    }
                    self.audio.set_sensitive(
                        matches!(phase, Phase::AwaitingFrame | Phase::Streaming)
                            && self.permissions.borrow().audio,
                    );
                    if phase == Phase::PasswordRequired {
                        self.challenge(1, &detail);
                        if self.recovery.attempt(self.bridge.session) {
                            if self.recovery_password_attempted.replace(true) {
                                self.stop_recovery("已保存密码未通过验证，请手动输入");
                            } else {
                                match self.recovery.lookup(self.bridge.session) {
                                    Ok(operation) => {
                                        *self.recovery_lookup.borrow_mut() = Some(operation);
                                        self.status.set_text("自动重连：正在读取已保存密码…");
                                    }
                                    Err(error) => self.stop_recovery(error),
                                }
                            }
                        }
                    }
                    if matches!(phase, Phase::Failed | Phase::Ended) {
                        self.recovery_lookup.borrow_mut().take();
                        self.recovery
                            .terminal(self.bridge.session, self.retryable.replace(false));
                        self.challenge.set(0);
                        self.password.set_text("");
                        self.secrets.stop();
                        self.cursors.clear();
                        self.retry.set_visible(true);
                        self.authentication.set_visible(false);
                        if let Some(clipboard) = self.clipboard.borrow().as_ref() {
                            clipboard.permission(false);
                        }
                    }
                    if phase != Phase::Streaming {
                        if let Some(input) = self.input.borrow().as_ref() {
                            input.set_ready(false);
                        }
                    }
                }
                EventKind::AuthenticationChallenge {
                    two_factor,
                    insecure,
                    detail,
                } => {
                    self.stop_recovery("需要用户确认，自动重连已停止");
                    if two_factor {
                        self.challenge(2, &detail);
                    } else if insecure {
                        self.challenge(3, &detail);
                    }
                }
                EventKind::Reply {
                    error: Some(error), ..
                } => self.status.set_text(&error),
                EventKind::Media { backend, detail } => {
                    self.backend.set_text(&format!("{backend} · {detail}"))
                }
                EventKind::Displays { displays, selected } => {
                    if let Some(input) = self.input.borrow().as_ref() {
                        input.set_display(displays.iter().find(|d| d.index == selected).cloned());
                    }
                    self.updating.set(true);
                    let names: Vec<String> = displays
                        .iter()
                        .map(|d| format!("{} · {}×{}", d.name, d.width, d.height))
                        .collect();
                    self.displays.set_model(Some(&gtk::StringList::new(
                        &names.iter().map(String::as_str).collect::<Vec<_>>(),
                    )));
                    self.displays.set_selected(
                        displays
                            .iter()
                            .position(|d| d.index == selected)
                            .map_or(gtk::INVALID_LIST_POSITION, |i| i as u32),
                    );
                    *self.display_ids.borrow_mut() = displays.iter().map(|d| d.index).collect();
                    self.displays.set_sensitive(displays.len() > 1);
                    self.updating.set(false);
                }
                EventKind::Permissions(permissions) => {
                    if let Some(clipboard) = self.clipboard.borrow().as_ref() {
                        clipboard.permission(
                            permissions.clipboard
                                && matches!(
                                    self.model.borrow().phase,
                                    Phase::AwaitingFrame | Phase::Streaming
                                ),
                        );
                    }
                    if let Some(input) = self.input.borrow().as_ref() {
                        input.set_ready(
                            permissions.keyboard && self.model.borrow().phase == Phase::Streaming,
                        );
                    }
                    self.updating.set(true);
                    self.audio.set_sensitive(
                        permissions.audio
                            && matches!(
                                self.model.borrow().phase,
                                Phase::AwaitingFrame | Phase::Streaming
                            ),
                    );
                    if !permissions.audio {
                        self.audio.set_active(false);
                    }
                    self.updating.set(false);
                    *self.permissions.borrow_mut() = permissions;
                }
                EventKind::Audio { status, detail, .. } => {
                    self.audio.set_tooltip_text(Some(&detail));
                    self.audio.set_label(match status.as_str() {
                        "playing" => "音频 · 播放中",
                        "unavailable" => "音频 · 不可用",
                        "starting" | "waiting" => "音频 · 等待",
                        _ => "音频",
                    });
                }
                EventKind::ClipboardPolicy { policy, revision } => {
                    if let Some(clipboard) = self.clipboard.borrow().as_ref() {
                        clipboard.policy(policy, revision);
                    }
                }
                EventKind::ClipboardStatus { available, detail } => {
                    if let Some(clipboard) = self.clipboard.borrow().as_ref() {
                        clipboard.status(available, &detail);
                    }
                }
                EventKind::Cursor {
                    id,
                    width,
                    height,
                    hot_x,
                    hot_y,
                    rgba,
                    premultiplied,
                    ..
                } => {
                    if !self.closing.get()
                        && matches!(
                            self.model.borrow().phase,
                            Phase::AwaitingFrame | Phase::Streaming
                        )
                    {
                        self.cursors
                            .update(id, width, height, hot_x, hot_y, &rgba, premultiplied);
                    }
                }
                EventKind::Metrics(m) => self.hud.metrics(m),
                _ => {}
            }
        }
        if let Some(clipboard) = self.clipboard.borrow().as_ref() {
            clipboard.poll();
        }
        if let Some(frame) = update.frame {
            if let Some(unread) = self.pending_frame.borrow_mut().replace(frame) {
                if let Err(error) = unread.discard() {
                    self.fail(&error.to_string());
                }
            }
        }
        let generation = self.model.borrow().generation;
        if self
            .pending_frame
            .borrow()
            .as_ref()
            .is_some_and(|f| f.generation() <= generation)
        {
            let frame = self.pending_frame.borrow_mut().take().unwrap();
            if frame.generation() < generation {
                if let Err(error) = frame.discard() {
                    self.fail(&error.to_string());
                }
            } else if let Err(error) = self.present(frame) {
                self.fail(&error.to_string());
            }
        }
        if let Some(error) = update.error {
            if let Some(smoke) = self.smoke.borrow().as_ref() {
                let _ = std::fs::write(smoke.directory.join("bridge-error.txt"), &error);
            }
            if !matches!(self.model.borrow().phase, Phase::Ended | Phase::Failed) {
                self.fail(&error);
            }
        }
        if update.exited && !self.exited.replace(true) {
            self.hud.enable(false);
            self.secrets.stop();
            self.authentication.set_visible(false);
            self.pending_frame.borrow_mut().take();
            if let Some(smoke) = self.smoke.borrow().as_ref() {
                let report = serde_json::json!({"events":smoke.events,"password_attempts":smoke.passwords,"frames":smoke.frames,"gpu_frames":smoke.gpu_frames,"gpu_completed":self.gpu.completed(),
                    "presented":smoke.first_paint.is_some(),"worker_reaped":true,"session":self.bridge.session,"cycle":smoke.cycle,
                    "authentication_visible":self.authentication.is_visible(),"challenge":self.challenge.get()});
                let _ = std::fs::write(
                    smoke.directory.join(format!("cycle-{}.json", smoke.cycle)),
                    serde_json::to_vec_pretty(&report).unwrap(),
                );
                let _ = std::fs::write(
                    smoke.directory.join("viewer.json"),
                    serde_json::to_vec_pretty(&report).unwrap(),
                );
            }
        }
        if self.closing.get() && self.has_exited() {
            (self.home)();
            return;
        }
        if self.poll_recovery() {
            return;
        }
        if !self.closing.get()
            && self.has_exited()
            && self.model.borrow().phase == Phase::Failed
            && std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("retry")
            && self.smoke.borrow().as_ref().is_some_and(|s| s.cycle == 0)
        {
            self.retry.emit_clicked();
            return;
        }
        let mut authenticate = None;
        let mut close = false;
        if let Some(smoke) = self.smoke.borrow_mut().as_mut() {
            if std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("auto-reconnect") {
                for (name, value) in [("auto-enable", true), ("auto-disable", false)] {
                    let path = smoke.directory.join(name);
                    if path.exists() {
                        let _ = std::fs::remove_file(path);
                        self.recovery_toggle.set_active(value);
                    }
                }
                let report = serde_json::json!({"session":self.bridge.session,"cycle":smoke.cycle,
                    "phase":self.model.borrow().phase,"presented":smoke.first_paint.is_some(),"frames":smoke.frames,
                    "enabled":self.recovery.enabled(),"lookup":self.recovery_lookup.borrow().is_some(),
                    "challenge":self.challenge.get(),"status":self.status.text().as_str()});
                let temporary = smoke.directory.join("auto-progress.tmp");
                let _ = std::fs::write(&temporary, report.to_string()).and_then(|_| {
                    std::fs::rename(temporary, smoke.directory.join("auto-progress.json"))
                });
            }
            if std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("clipboard") {
                if smoke.first_paint.is_some() && !smoke.clipboard_configured {
                    smoke.clipboard_configured = true;
                    if let Some(clipboard) = self.clipboard.borrow().as_ref() {
                        clipboard.smoke_set(true);
                    }
                }
                let policy_file = smoke.directory.join("clipboard-policy.json");
                if let Ok(bytes) = std::fs::read(&policy_file) {
                    if let Ok(policy) =
                        serde_json::from_slice::<farpane_protocol::clipboard::Policy>(&bytes)
                    {
                        let _ = std::fs::remove_file(&policy_file);
                        if let Some(clipboard) = self.clipboard.borrow().as_ref() {
                            clipboard.smoke_policy(policy);
                        }
                    }
                }
                if !smoke.clipboard_disabled && smoke.directory.join("disable-clipboard").exists() {
                    smoke.clipboard_disabled = true;
                    if let Some(clipboard) = self.clipboard.borrow().as_ref() {
                        clipboard.smoke_set(false);
                    }
                }
            }
            if std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("audio") {
                let refresh = smoke.directory.join("audio-refresh-video");
                if refresh.exists() {
                    std::fs::remove_file(refresh).ok();
                    self.send(Command::RefreshFrame);
                }
                for (file, enabled) in [("audio-on", true), ("audio-off", false)] {
                    let path = smoke.directory.join(file);
                    if path.exists() {
                        std::fs::remove_file(path).ok();
                        self.audio.set_active(enabled);
                    }
                }
            }
            if !smoke.captured
                && smoke
                    .first_paint
                    .is_some_and(|at| at.elapsed() > Duration::from_secs(1))
            {
                smoke.captured = true;
                smoke_trim(&smoke.directory, "viewer");
                let _ = std::fs::read("/proc/self/smaps_rollup").and_then(|bytes| {
                    std::fs::write(smoke.directory.join("gui-memory.txt"), bytes)
                });
                let _ = std::fs::read("/proc/self/smaps").and_then(|bytes| {
                    std::fs::write(smoke.directory.join("gui-pre-capture-smaps.txt"), bytes)
                });
                if let Some(window) = self.root.root().and_downcast::<gtk::Window>() {
                    if std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("input") {
                        if let Some(bounds) =
                            hud_smoke::find(self.root.upcast_ref(), "viewer-hud-toggle")
                                .and_then(|button| button.compute_bounds(&window))
                        {
                            let scale = window.scale_factor() as f32;
                            let target = serde_json::json!({"hud":[
                                (bounds.x()+bounds.width()/2.)*scale,
                                (bounds.y()+bounds.height()/2.)*scale,
                            ]});
                            let _ = std::fs::write(
                                smoke.directory.join("input-targets.json"),
                                serde_json::to_vec_pretty(&target).unwrap(),
                            );
                        }
                    }
                    let snapshot = gtk::Snapshot::new();
                    let paintable = gtk::WidgetPaintable::new(Some(&window));
                    paintable.snapshot(&snapshot, window.width() as f64, window.height() as f64);
                    if let (Some(node), Some(renderer)) = (snapshot.to_node(), window.renderer()) {
                        let _ = renderer
                            .render_texture(&node, None)
                            .save_to_png(smoke.directory.join("viewer-window.png"));
                    }
                }
            }
            let report_serial = smoke.events.len().saturating_add(
                if std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("recovery") {
                    smoke.frames as usize
                } else {
                    0
                },
            );
            if smoke.last_report != report_serial {
                let report = serde_json::json!({"events":smoke.events,"password_attempts":smoke.passwords,"frames":smoke.frames,"gpu_frames":smoke.gpu_frames,"gpu_completed":self.gpu.completed(),
                    "presented":smoke.first_paint.is_some(),"worker_reaped":self.exited.get(),"phase":self.model.borrow().phase,
                    "authentication_visible":self.authentication.is_visible(),"challenge":self.challenge.get(),"hud_enabled":self.hud.enabled()});
                let _ = std::fs::write(
                    smoke.directory.join("viewer-progress.json"),
                    serde_json::to_vec_pretty(&report).unwrap(),
                );
                smoke.last_report = report_serial;
            }
            if self.challenge.get() == 1
                && !(std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("auto-reconnect")
                    && smoke.cycle > 0)
                && !matches!(
                    std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref(),
                    Ok("approval" | "desktop")
                )
            {
                if std::env::var_os("FARPANE_SECRET_ROUND").is_some() {
                    let dialogs: Vec<_> = gtk::Window::list_toplevels()
                        .into_iter()
                        .filter_map(|w| w.downcast::<adw::MessageDialog>().ok())
                        .map(|d| d.heading().map(|h| h.to_string()))
                        .collect();
                    let _ = std::fs::write(
                        smoke.directory.join("secret-progress.json"),
                        serde_json::to_vec_pretty(&serde_json::json!({
                            "status": self.secrets.note.text().as_str(),
                            "dialogs": dialogs,
                            "requested": smoke.secret_requested,
                            "cancelled": smoke.secret_cancelled
                        }))
                        .unwrap(),
                    );
                }
                match std::env::var("FARPANE_SECRET_ROUND").as_deref() {
                    Ok("save") => {
                        self.secrets.save.set_active(true);
                        if smoke.passwords == 0
                            || smoke.directory.join("wrong-password-not-stored").exists()
                        {
                            smoke.passwords += 1;
                            authenticate = Some(if smoke.passwords == 1 {
                                "incorrect-smoke-password"
                            } else {
                                "native-viewer-smoke"
                            });
                        }
                    }
                    Ok("load") => {
                        if !smoke.secret_requested {
                            self.secrets.load.emit_clicked();
                            smoke.secret_requested = true;
                        }
                        if !self.password.text().is_empty() {
                            smoke.passwords += 1;
                            self.authenticate();
                        }
                    }
                    Ok("cancel") => {
                        if !smoke.secret_requested {
                            self.secrets.load.emit_clicked();
                            smoke.secret_requested = true;
                            let _ =
                                std::fs::write(smoke.directory.join("secret-started"), b"started");
                        } else if !smoke.secret_cancelled
                            && smoke.directory.join("cancel-keyring").exists()
                        {
                            self.secrets.cancel.emit_clicked();
                            smoke.secret_cancelled = true;
                        } else if smoke.secret_cancelled
                            && self.secrets.note.text().contains("已取消")
                        {
                            let _ = std::fs::write(
                                smoke.directory.join("secret-cancelled"),
                                b"cancelled",
                            );
                            smoke.passwords += 1;
                            authenticate = Some("native-viewer-smoke");
                        }
                    }
                    Ok("delete") => {
                        if !smoke.secret_requested {
                            self.secrets.forget.emit_clicked();
                            smoke.secret_requested = true;
                        }
                        if !smoke.secret_confirmed {
                            if let Some(dialog) = gtk::Window::list_toplevels()
                                .into_iter()
                                .filter_map(|w| w.downcast::<adw::MessageDialog>().ok())
                                .find(|d| d.heading().as_deref() == Some("忘记已保存密码？"))
                            {
                                smoke.secret_confirmed = true;
                                dialog.response("forget");
                            }
                        }
                        if self.secrets.note.text().starts_with("已忘记") {
                            smoke.passwords += 1;
                            authenticate = Some("native-viewer-smoke");
                        }
                    }
                    Ok("stale") => {
                        if !smoke.secret_requested {
                            self.secrets.load.emit_clicked();
                            smoke.secret_requested = true;
                            let _ =
                                std::fs::write(smoke.directory.join("secret-started"), b"started");
                        } else if smoke.directory.join("submit-manually").exists() {
                            self.secrets.save.set_active(true);
                            smoke.passwords += 1;
                            authenticate = Some("native-viewer-smoke");
                            let _ = std::fs::write(
                                smoke.directory.join("manual-submitted"),
                                b"submitted",
                            );
                        }
                    }
                    Ok("unavailable" | "locked") => {
                        if !smoke.secret_requested {
                            self.secrets.load.emit_clicked();
                            smoke.secret_requested = true;
                        }
                        if self.secrets.note.text().contains("不可用")
                            || self.secrets.note.text().contains("被锁定")
                        {
                            smoke.passwords += 1;
                            authenticate = Some("native-viewer-smoke");
                        }
                    }
                    _ => {
                        smoke.passwords += 1;
                        authenticate = Some(if smoke.passwords == 1 {
                            "incorrect-smoke-password"
                        } else {
                            "native-viewer-smoke"
                        });
                    }
                }
            }
            close = smoke.directory.join("clipboard-complete").exists()
                || smoke.first_paint.is_some_and(|at| {
                    at.elapsed()
                        > Duration::from_secs(
                            match std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() {
                                Ok("input") => 8,
                                Ok("clipboard") => 90,
                                Ok("cursor") => 10,
                                Ok("audio") => 25,
                                Ok("approval") => 38,
                                Ok("hud") => 48,
                                Ok("recovery") => 120,
                                Ok("auto-reconnect") => 180,
                                _ => 3,
                            },
                        )
                });
        }
        if self.smoke.borrow().is_some() && self.challenge.get() == 3 {
            self.authenticate();
        }
        if let Some(password) = authenticate {
            self.password.set_text(password);
            self.authenticate();
        }
        if close && !self.closing.get() {
            self.close();
        }
    }
    fn stop_recovery(&self, detail: &str) {
        self.recovery.cancel(self.bridge.session);
        self.recovery_lookup.borrow_mut().take();
        self.recovery_toggle.set_active(false);
        self.status.set_text(detail);
    }
    fn poll_recovery(&self) -> bool {
        if self.closing.get() {
            return false;
        }
        if !self.recovery.enabled() {
            self.recovery_toggle.set_active(false);
            return false;
        }
        let (valid, network_wait) = self.host.upgrade().map_or((false, false), |host| {
            let model = host.model.borrow();
            (
                self.recovery.valid(&model.snapshot),
                matches!(
                    model.snapshot.recovery.phase,
                    farpane_protocol::RecoveryPhase::Suspended
                        | farpane_protocol::RecoveryPhase::WaitingNetwork
                ),
            )
        });
        if !valid {
            self.stop_recovery("设备或服务器设置已变化，自动重连已停止");
            return false;
        }
        if self.recovery.expired(self.bridge.session) {
            self.fail_with_recovery("自动重连等待画面超时", true);
        }
        let result = self
            .recovery_lookup
            .borrow_mut()
            .as_mut()
            .and_then(|op| op.poll());
        if let Some(result) = result {
            self.recovery_lookup.borrow_mut().take();
            if self.recovery.attempt(self.bridge.session) && self.challenge.get() == 1 {
                match result {
                    Ok(crate::credentials::Outcome::Password(Some(password))) => {
                        self.password.set_text(&password.value().0);
                        self.authenticate_with_recovery(true);
                    }
                    Ok(_) => self.stop_recovery("没有可用的已保存密码，请手动输入"),
                    Err(error) => self.stop_recovery(error),
                }
            }
        }
        if let Some(attempt) = self.recovery.waiting(self.bridge.session) {
            self.status.set_text(&if network_wait {
                "等待系统或网络恢复，可取消自动重连".into()
            } else {
                format!("连接中断，准备自动重连（{attempt}/4），可取消")
            });
            if !network_wait
                && self
                    .recovery
                    .take_due(self.bridge.session, self.has_exited())
            {
                (self.reconnect)(true, self.audio.is_active());
                return true;
            }
        }
        false
    }
    fn fail(&self, error: &str) {
        self.fail_with_recovery(error, false);
    }
    fn fail_with_recovery(&self, error: &str, retryable: bool) {
        self.toolbar_toggle.set_active(false);
        self.recovery_lookup.borrow_mut().take();
        self.recovery.terminal(self.bridge.session, retryable);
        self.cursors.clear();
        self.status.set_text(error);
        self.retry.set_visible(true);
        self.model.borrow_mut().phase = Phase::Failed;
        if let Some(input) = self.input.borrow().as_ref() {
            input.set_ready(false);
        }
        if let Some(clipboard) = self.clipboard.borrow().as_ref() {
            clipboard.permission(false);
        }
        self.gpu.stop();
        self.bridge.stop();
    }
    fn present(&self, mut frame: Frame) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if matches!(&frame.packet, Packet::DmaBuf(_)) {
            self.canvas.set_visible_child_name("gpu");
            self.picture.set_paintable(None::<&gdk::Paintable>);
            self.gpu.queue(frame)?;
            return Ok(());
        }
        let Packet::Software(info) = &frame.packet else {
            return Err("无效的画面消息".into());
        };
        self.canvas.set_visible_child_name("software");
        let info = info.clone();
        let length = info.byte_len().map_err(|_| "无效画面尺寸")?;
        let pixels = farpane_protocol::sealed::Bytes::map(frame.files.remove(0), length)?;
        let bytes = glib::Bytes::from_owned(pixels);
        let texture = gdk::MemoryTexture::new(
            info.width as i32,
            info.height as i32,
            gdk::MemoryFormat::B8g8r8a8,
            &bytes,
            info.stride as usize,
        );
        if let Some(smoke) = self.smoke.borrow_mut().as_mut() {
            if smoke.frames == 0 {
                texture.save_to_png(smoke.directory.join("remote-frame.png"))?;
            }
            smoke.frames += 1;
        }
        // Software pixels are immutable and held by the GDK texture. No mutable
        // decoder surface is reused by this acknowledgement.
        frame.release()?;
        self.picture.set_paintable(Some(&texture));
        if let Some(input) = self.input.borrow().as_ref() {
            input.set_image(info.width, info.height);
        }
        self.pending_paint(info.generation, frame.received);
        Ok(())
    }
}
impl Drop for View {
    fn drop(&mut self) {
        if let Some(input) = self.input.get_mut().as_ref() {
            input.detach();
        }
        if let Some((clock, handler)) = self.clock.get_mut().take() {
            // GTK can dispose the shared frame clock during window teardown,
            // removing its handlers before this Rust owner is dropped.
            if unsafe {
                glib::gobject_ffi::g_signal_handler_is_connected(
                    clock.as_ptr().cast(),
                    handler.as_raw(),
                )
            } != 0
            {
                clock.disconnect(handler);
            }
        }
        self.bridge.stop();
    }
}
