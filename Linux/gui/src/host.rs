use crate::{
    app::{card, label, page},
    bridge::Bridge,
    model::Model,
};
use adw::prelude::*;
use farpane_protocol::{
    Authentication, Command, Permission, Role, Secret, ServerSettings, Snapshot,
};
use gtk::glib;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

struct Binding {
    anchor: Option<glib::WeakRef<gtk::Widget>>,
    update: Box<dyn Fn(&Snapshot, bool)>,
}
pub struct Ui {
    pub model: Rc<RefCell<Model>>,
    startup: Rc<crate::startup_ui::Settings>,
    bridge: Bridge,
    bindings: RefCell<Vec<Binding>>,
    updating: Cell<bool>,
    busy: Cell<bool>,
    generation: Cell<u64>,
    history: RefCell<Option<(String, ServerSettings, String)>>,
    toast: glib::WeakRef<adw::ToastOverlay>,
    connections_dialog: RefCell<glib::WeakRef<adw::MessageDialog>>,
    pub on_connect: RefCell<Option<Box<dyn Fn(String, bool)>>>,
}
impl Ui {
    pub fn new(model: Rc<RefCell<Model>>, toast: &adw::ToastOverlay) -> Rc<Self> {
        Rc::new(Self {
            model,
            startup: crate::startup_ui::Settings::new(),
            bridge: Bridge::start(),
            bindings: RefCell::new(Vec::new()),
            updating: Cell::new(false),
            busy: Cell::new(false),
            generation: Cell::new(0),
            history: RefCell::new(None),
            toast: toast.downgrade(),
            connections_dialog: RefCell::new(glib::WeakRef::new()),
            on_connect: RefCell::new(None),
        })
    }
    pub(crate) fn notice(&self, message: &str) {
        if let Some(directory) = crate::viewer::test_directory("FARPANE_FILES_SMOKE_DIR") {
            let _ = std::fs::write(
                directory.join("host-notice.json"),
                serde_json::json!({"notice":message}).to_string(),
            );
        }
        if let Some(toast) = self.toast.upgrade() {
            toast.add_toast(adw::Toast::new(message));
        }
    }
    pub(crate) fn send(&self, command: Command) {
        if let Some(directory) = crate::viewer::test_directory("FARPANE_FILES_SMOKE_DIR") {
            let _ = std::fs::write(directory.join("host-command.json"), serde_json::json!({"command":format!("{command:?}"),"updating":self.updating.get(),"busy":self.busy.get()}).to_string());
        }
        if self.updating.get() {
            return;
        }
        if self.model.borrow().snapshot.role.is_none() {
            self.notice("尚未读取后台状态，请稍后重试");
            return;
        }
        if self.busy.replace(true) {
            return;
        }
        if let Err(error) = self.bridge.send(command, self.generation.get()) {
            self.busy.set(false);
            self.notice(error);
        }
    }
    pub fn poll(&self, status: Option<&gtk::Label>) {
        let update = self.bridge.take();
        if update.disconnected {
            self.model.borrow_mut().snapshot.role = None;
            self.generation.set(0);
        }
        if update.finished {
            self.busy.set(false);
        }
        if let Some(snapshot) = update.snapshot {
            self.generation.set(update.generation.unwrap_or(0));
            self.model.borrow_mut().snapshot = snapshot;
        }
        if let Some(error) = update.error {
            self.notice(&error);
        }
        let model = self.model.borrow();
        if let Some(status) = status {
            let text = match model.snapshot.role {
                Some(Role::Agent) if !model.snapshot.host_enabled => "已关闭被控",
                Some(Role::Agent)
                    if model.snapshot.recovery.phase
                        == farpane_protocol::RecoveryPhase::Suspended =>
                {
                    "准备休眠"
                }
                Some(Role::Agent)
                    if model.snapshot.recovery.phase
                        == farpane_protocol::RecoveryPhase::WaitingNetwork =>
                {
                    "等待网络"
                }
                Some(Role::Agent)
                    if matches!(
                        model.snapshot.recovery.phase,
                        farpane_protocol::RecoveryPhase::Waiting
                            | farpane_protocol::RecoveryPhase::Registering
                    ) =>
                {
                    "正在恢复后台"
                }
                Some(Role::Agent) if model.snapshot.registered => "后台在线",
                Some(Role::Agent) => "等待服务器",
                Some(Role::Config) => "后台未运行",
                _ => "后台未连接",
            };
            status.set_text(text);
            let state = match text {
                "后台在线" => "online",
                "后台未运行" | "后台未连接" => "",
                _ => "warning",
            };
            for class in ["online", "warning"] {
                if class == state {
                    status.add_css_class(class);
                } else {
                    status.remove_css_class(class);
                }
            }
        }
        self.updating.set(true);
        let ready = model.snapshot.role.is_some() && !self.busy.get();
        self.bindings
            .borrow_mut()
            .retain(|b| b.anchor.as_ref().is_none_or(|a| a.upgrade().is_some()));
        for binding in self.bindings.borrow().iter() {
            (binding.update)(&model.snapshot, ready);
        }
        self.updating.set(false);
        let revision = model.snapshot.revision;
        drop(model);
        if ready {
            let pending = self.history.borrow_mut().take();
            if let Some((peer, server, name)) = pending {
                self.send(Command::RememberDevice {
                    peer,
                    server,
                    name,
                    revision,
                });
            }
        }
    }
    pub fn remember(&self, peer: String, server: ServerSettings, name: String) {
        *self.history.borrow_mut() = Some((peer, server, name));
    }
    pub fn select(self: &Rc<Self>, index: i32) -> gtk::Box {
        // Transient connection controls stay live across Home/Viewer switches.
        // Their weak widget anchors also prevent accumulating dead dialog bindings.
        self.bindings
            .borrow_mut()
            .retain(|b| b.anchor.as_ref().is_some_and(|a| a.upgrade().is_some()));
        match index {
            1 => self.security(),
            2 => self.sharing(),
            _ => self.devices(),
        }
    }
    pub(crate) fn bind(&self, binding: impl Fn(&Snapshot, bool) + 'static) {
        self.bindings.borrow_mut().push(Binding {
            anchor: None,
            update: Box::new(binding),
        });
    }
    fn bind_scoped(
        &self,
        widget: &impl IsA<gtk::Widget>,
        binding: impl Fn(&Snapshot, bool) + 'static,
    ) {
        self.bindings.borrow_mut().push(Binding {
            anchor: Some(widget.as_ref().downgrade()),
            update: Box::new(binding),
        });
    }
    pub(crate) fn sessions_button(self: &Rc<Self>) -> gtk::Button {
        let button = gtk::Button::with_label("本机连接");
        button.set_widget_name("inbound-manager");
        button.set_tooltip_text(Some("处理连接本机的请求、撤销权限或断开入站会话"));
        let weak = button.downgrade();
        self.bind_scoped(&button, move |s, _| {
            if let Some(button) = weak.upgrade() {
                let pending = s.inbound.iter().filter(|c| !c.authorized).count();
                button.set_label(&if pending > 0 {
                    format!("本机连接 · {pending} 待批准")
                } else if !s.inbound.is_empty() {
                    format!("本机连接 · {}", s.inbound.len())
                } else {
                    "本机连接".into()
                });
            }
        });
        let weak = Rc::downgrade(self);
        button.connect_clicked(move |button| {
            let Some(ui) = weak.upgrade() else {
                return;
            };
            if let Some(window) = button.root().and_downcast::<gtk::Window>() {
                ui.show_sessions(&window);
            }
        });
        button
    }
    pub(crate) fn show_sessions(self: &Rc<Self>, window: &impl IsA<gtk::Window>) {
        if let Some(dialog) = self.connections_dialog.borrow().upgrade() {
            if dialog.is_visible() {
                dialog.present();
                return;
            }
        }
        let dialog = adw::MessageDialog::new(
            Some(window),
            Some("本机连接与权限"),
            Some("这些请求来自连接本机的设备，与当前远程画面相互独立。"),
        );
        let scroll = gtk::ScrolledWindow::builder()
            .max_content_height(440)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&self.sessions())
            .build();
        dialog.set_extra_child(Some(&scroll));
        dialog.add_response("close", "关闭");
        dialog.set_close_response("close");
        dialog.set_destroy_with_parent(true);
        *self.connections_dialog.borrow_mut() = dialog.downgrade();
        dialog.present();
    }
    fn switch(
        self: &Rc<Self>,
        title: &str,
        subtitle: &str,
        value: fn(&Snapshot) -> bool,
        command: impl Fn(bool, &Snapshot) -> Command + 'static,
    ) -> adw::SwitchRow {
        let row = adw::SwitchRow::builder()
            .title(title)
            .subtitle(subtitle)
            .build();
        row.set_sensitive(false);
        let weak = row.downgrade();
        self.bind(move |snapshot, ready| {
            if let Some(row) = weak.upgrade() {
                row.set_active(value(snapshot));
                row.set_sensitive(ready);
            }
        });
        let ui = self.clone();
        row.connect_active_notify(move |row| {
            if !ui.updating.get() {
                let command = command(row.is_active(), &ui.model.borrow().snapshot);
                ui.send(command);
            }
        });
        row
    }
    fn text(&self, class: &str, value: impl Fn(&Snapshot) -> String + 'static) -> gtk::Label {
        let label = label("正在读取…", class);
        let weak = label.downgrade();
        self.bind(move |snapshot, _| {
            if let Some(label) = weak.upgrade() {
                let text = value(snapshot);
                label.set_visible(!text.is_empty());
                label.set_text(&text);
            }
        });
        label
    }
    fn devices(self: &Rc<Self>) -> gtk::Box {
        let page = page("你的设备", "连接另一台设备，或安全地共享这台电脑。");
        let connect = card("连接远端设备");
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        row.add_css_class("connect-row");
        let entry = gtk::Entry::builder()
            .placeholder_text("输入远端设备 ID")
            .hexpand(true)
            .build();
        entry.add_css_class("connect-entry");
        let button = gtk::Button::with_label("连接");
        button.add_css_class("suggested-action");
        button.add_css_class("connect-button");
        button.set_sensitive(false);
        let weak = button.downgrade();
        self.bind(move |snapshot, ready| {
            if let Some(button) = weak.upgrade() {
                button.set_sensitive(ready && !snapshot.local_id.is_empty());
            }
        });
        row.append(&entry);
        row.append(&button);
        let files = gtk::Button::with_label("发送文件");
        files.set_widget_name("open-files");
        row.append(&files);
        let weak = files.downgrade();
        self.bind(move |snapshot, ready| {
            if let Some(button) = weak.upgrade() {
                button.set_sensitive(ready && !snapshot.local_id.is_empty());
            }
        });
        let ui = self.clone();
        let weak_entry = entry.downgrade();
        files.connect_clicked(move |button| {
            let Some(entry) = weak_entry.upgrade() else {
                return;
            };
            let peer = entry.text().trim().to_string();
            if peer.is_empty() || peer.len() > 256 || peer.chars().any(char::is_control) {
                ui.notice("请输入有效的远端设备 ID 或地址");
                return;
            }
            let Some(parent) = button.root().and_downcast::<gtk::Window>() else {
                return;
            };
            let snapshot = ui.model.borrow().snapshot.clone();
            if let Err(error) = crate::file_view::open(
                &parent,
                peer,
                farpane_protocol::ViewerConfiguration {
                    local_id: snapshot.local_id,
                    server: snapshot.server,
                },
            ) {
                ui.notice(&error.to_string());
            }
        });
        connect.append(&row);
        let audio = gtk::CheckButton::with_label("本次连接接收音频");
        connect.append(&audio);
        let ui = self.clone();
        let weak_entry = entry.downgrade();
        let weak_audio = audio.downgrade();
        button.connect_clicked(move |_| {
            let (Some(entry), Some(audio)) = (weak_entry.upgrade(), weak_audio.upgrade()) else {
                return;
            };
            let peer = entry.text().trim().to_string();
            if peer.is_empty() || peer.len() > 256 || peer.chars().any(char::is_control) {
                ui.notice("请输入有效的远端设备 ID 或地址");
                return;
            }
            if let Some(connect) = ui.on_connect.borrow().as_ref() {
                connect(peer, audio.is_active());
            }
        });
        let weak = button.downgrade();
        entry.connect_activate(move |_| {
            if let Some(button) = weak.upgrade() {
                if button.is_sensitive() {
                    button.emit_clicked();
                }
            }
        });
        page.append(&connect);
        let host = card("共享这台电脑");
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let identity = gtk::Box::new(gtk::Orientation::Vertical, 4);
        identity.set_hexpand(true);
        identity.append(&label("本机设备 ID", "caption-label"));
        let id = self.text("local-id", |s| {
            if s.local_id.is_empty() {
                "— — —".into()
            } else {
                s.local_id.clone()
            }
        });
        id.set_selectable(true);
        identity.append(&id);
        row.append(&identity);
        let copy = gtk::Button::from_icon_name("edit-copy-symbolic");
        copy.set_tooltip_text(Some("复制本机 ID"));
        copy.set_valign(gtk::Align::Center);
        let ui = self.clone();
        copy.connect_clicked(move |button| {
            button
                .clipboard()
                .set_text(&ui.model.borrow().snapshot.local_id);
        });
        let weak = copy.downgrade();
        self.bind(move |snapshot, _| {
            if let Some(copy) = weak.upgrade() {
                copy.set_sensitive(!snapshot.local_id.is_empty());
            }
        });
        row.append(&copy);
        host.append(&row);
        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::None);
        list.add_css_class("boxed-list");
        list.append(&self.switch(
            "允许连接本机",
            "关闭后停止接受新连接，当前会话可在授权页断开",
            |s| s.host_enabled,
            |enabled, s| Command::SetHost {
                enabled,
                revision: s.revision,
            },
        ));
        let auth = adw::ActionRow::builder()
            .title("连接认证")
            .subtitle("正在读取…")
            .build();
        let weak = auth.downgrade();
        self.bind(move |s, _| {
            if let Some(row) = weak.upgrade() {
                row.set_subtitle(&format!(
                    "{} · {}",
                    authentication(s.authentication),
                    if s.permanent_password_set {
                        "固定密码已设置"
                    } else {
                        "固定密码未设置"
                    }
                ));
            }
        });
        list.append(&auth);
        host.append(&list);
        host.append(&self.text("muted", |s| {
            if s.role == Some(Role::Config) {
                "设置已保存在本机；后台运行后才能接受连接。".into()
            } else {
                String::new()
            }
        }));
        let recovery = self.text("muted", |s| {
            if s.role == Some(Role::Agent) {
                s.recovery.detail.clone()
            } else {
                String::new()
            }
        });
        recovery.set_widget_name("host-recovery");
        host.append(&recovery);
        page.append(&host);
        page.append(&self.sessions());
        page.append(&crate::devices::list(self));
        page
    }
    fn security(self: &Rc<Self>) -> gtk::Box {
        let page = page(
            "授权与安全",
            "每次授权都由后台执行，界面显示实际生效的状态。",
        );
        let desktop = adw::ActionRow::builder()
            .title("桌面通知与托盘")
            .subtitle("正在读取桌面状态")
            .build();
        let weak = desktop.downgrade();
        self.bind(move |s, _| {
            if let Some(row) = weak.upgrade() {
                row.set_subtitle(if s.desktop.detail.is_empty() {
                    "后台启动后显示桌面通知状态"
                } else {
                    &s.desktop.detail
                });
            }
        });
        let desktop_group = adw::PreferencesGroup::builder().title("桌面集成").build();
        desktop_group.add(&desktop);
        page.append(&desktop_group);
        let group = adw::PreferencesGroup::builder().title("连接认证").build();
        let modes = gtk::StringList::new(&[
            "只使用固定密码",
            "只使用临时密码",
            "固定或临时密码",
            "每次手动批准",
        ]);
        let choice = adw::ComboRow::builder()
            .title("认证方式")
            .model(&modes)
            .build();
        let weak = choice.downgrade();
        self.bind(move |s, ready| {
            if let Some(row) = weak.upgrade() {
                row.set_sensitive(ready);
                row.set_selected(match s.authentication {
                    Authentication::Permanent => 0,
                    Authentication::Temporary => 1,
                    Authentication::Both => 2,
                    Authentication::Approval => 3,
                });
            }
        });
        let ui = self.clone();
        choice.connect_selected_notify(move |row| {
            if ui.updating.get() {
                return;
            }
            let mode = match row.selected() {
                0 => Authentication::Permanent,
                1 => Authentication::Temporary,
                2 => Authentication::Both,
                _ => Authentication::Approval,
            };
            let revision = ui.model.borrow().snapshot.revision;
            ui.send(Command::SetAuthentication {
                mode,
                password: None,
                revision,
            });
        });
        group.add(&choice);
        let password = adw::ActionRow::builder().title("固定密码").build();
        let weak = password.downgrade();
        self.bind(move |s, _| {
            if let Some(row) = weak.upgrade() {
                row.set_subtitle(if s.permanent_password_set {
                    "已设置；不会读回密码原文"
                } else {
                    "未设置"
                });
            }
        });
        let edit = gtk::Button::with_label("设置密码");
        edit.set_valign(gtk::Align::Center);
        let weak = edit.downgrade();
        self.bind(move |_, ready| {
            if let Some(button) = weak.upgrade() {
                button.set_sensitive(ready);
            }
        });
        let ui = self.clone();
        edit.connect_clicked(move |button| ui.password_dialog(button));
        password.add_suffix(&edit);
        group.add(&password);
        let temp = adw::ActionRow::builder().title("临时密码").build();
        let weak = temp.downgrade();
        self.bind(move |s, _| {
            if let Some(row) = weak.upgrade() {
                row.set_subtitle(
                    s.temporary_password
                        .as_ref()
                        .map(|p| p.0.as_str())
                        .unwrap_or("未启用"),
                );
            }
        });
        group.add(&temp);
        page.append(&group);
        page.append(&self.sessions());
        page
    }
    fn password_dialog(self: &Rc<Self>, parent: &gtk::Button) {
        let dialog = adw::Dialog::builder()
            .title("设置固定密码")
            .content_width(420)
            .build();
        let body = gtk::Box::new(gtk::Orientation::Vertical, 16);
        for set in [
            gtk::Widget::set_margin_top,
            gtk::Widget::set_margin_bottom,
            gtk::Widget::set_margin_start,
            gtk::Widget::set_margin_end,
        ] {
            set(body.upcast_ref(), 24);
        }
        body.append(&label("设置固定密码", "card-title"));
        let password = adw::PasswordEntryRow::builder().title("新密码").build();
        let confirm = adw::PasswordEntryRow::builder()
            .title("再次输入密码")
            .build();
        body.append(&password);
        body.append(&confirm);
        body.append(&label("留空并保存将清除固定密码。", "muted"));
        let save = gtk::Button::with_label("保存");
        save.add_css_class("suggested-action");
        body.append(&save);
        let ui = self.clone();
        let weak = dialog.downgrade();
        let revision = self.model.borrow().snapshot.revision;
        save.connect_clicked(move |_| {
            if password.text() != confirm.text() {
                ui.notice("两次输入的密码不一致");
                return;
            }
            let mode = ui.model.borrow().snapshot.authentication;
            ui.send(Command::SetAuthentication {
                mode,
                password: Some(Secret(password.text().to_string())),
                revision,
            });
            password.set_text("");
            confirm.set_text("");
            if let Some(dialog) = weak.upgrade() {
                dialog.close();
            }
        });
        dialog.set_child(Some(&body));
        dialog.present(Some(parent));
    }
    fn sessions(self: &Rc<Self>) -> adw::PreferencesGroup {
        let section = adw::PreferencesGroup::builder()
            .title("连接请求与有效权限")
            .build();
        let rows = gtk::ListBox::new();
        rows.set_selection_mode(gtk::SelectionMode::None);
        rows.add_css_class("boxed-list");
        let empty = label("暂无连接请求或活动会话", "placeholder-label");
        empty.set_xalign(0.5);
        rows.set_placeholder(Some(&empty));
        section.add(&rows);
        let weak = rows.downgrade();
        let ui = Rc::downgrade(self);
        let previous = RefCell::new(String::new());
        self.bind_scoped(&section, move |s, ready| {
            let signature = format!(
                "{}:{ready}",
                serde_json::to_string(&s.inbound).unwrap_or_default()
            );
            if *previous.borrow() == signature {
                return;
            }
            *previous.borrow_mut() = signature;
            let (Some(rows), Some(ui)) = (weak.upgrade(), ui.upgrade()) else {
                return;
            };
            rows.remove_all();
            for connection in &s.inbound {
                let p = &connection.permissions;
                let granted = [
                    ("键鼠", p.keyboard),
                    ("剪贴板", p.clipboard),
                    ("音频", p.audio),
                    ("文件", p.file),
                ]
                .into_iter()
                .filter_map(|(name, enabled)| enabled.then_some(name))
                .collect::<Vec<_>>();
                let entry = adw::ExpanderRow::builder()
                    .title(&connection.name)
                    .subtitle(format!(
                        "{} · {} · {}",
                        connection.peer,
                        if connection.authorized {
                            "已连接"
                        } else {
                            "等待批准"
                        },
                        if granted.is_empty() {
                            "无权限".into()
                        } else {
                            granted.join("、")
                        }
                    ))
                    // Pending requests show what they ask for; active ones stay compact.
                    .expanded(!connection.authorized)
                    .build();
                entry.set_use_markup(false);
                let id = connection.id;
                if !connection.authorized {
                    let accept = gtk::Button::with_label("允许连接");
                    accept.set_widget_name(&format!("inbound-approve-{id}"));
                    accept.add_css_class("suggested-action");
                    accept.set_valign(gtk::Align::Center);
                    accept.set_sensitive(ready);
                    let permissions = connection.permissions.clone();
                    let ui = ui.clone();
                    accept.connect_clicked(move |_| {
                        ui.send(Command::Approve {
                            connection: id,
                            permissions: permissions.clone(),
                        })
                    });
                    entry.add_suffix(&accept);
                }
                let close = gtk::Button::with_label(if connection.authorized {
                    "断开"
                } else {
                    "拒绝"
                });
                close.set_valign(gtk::Align::Center);
                if connection.authorized {
                    close.add_css_class("destructive-action");
                }
                close.set_sensitive(ready);
                close.set_widget_name(&format!(
                    "inbound-{}-{id}",
                    if connection.authorized {
                        "disconnect"
                    } else {
                        "reject"
                    }
                ));
                let controller = ui.clone();
                let authorized = connection.authorized;
                close.connect_clicked(move |_| {
                    controller.send(if authorized {
                        Command::DisconnectInbound { connection: id }
                    } else {
                        Command::Reject { connection: id }
                    })
                });
                entry.add_suffix(&close);
                for (title, permission, enabled) in [
                    (
                        "键鼠",
                        Permission::Keyboard,
                        connection.permissions.keyboard,
                    ),
                    (
                        "剪贴板",
                        Permission::Clipboard,
                        connection.permissions.clipboard,
                    ),
                    ("音频", Permission::Audio, connection.permissions.audio),
                    ("文件", Permission::File, connection.permissions.file),
                ] {
                    let row = adw::ActionRow::builder().title(title).build();
                    row.add_suffix(&label(if enabled { "允许" } else { "关闭" }, "muted"));
                    if connection.authorized && enabled {
                        let revoke = gtk::Button::with_label("撤销");
                        revoke.set_valign(gtk::Align::Center);
                        revoke.add_css_class("flat");
                        if permission == Permission::Audio {
                            revoke.set_widget_name(&format!("inbound-revoke-audio-{id}"));
                        } else if permission == Permission::File {
                            revoke.set_widget_name(&format!("inbound-revoke-file-{id}"));
                        } else if permission == Permission::Keyboard {
                            revoke.set_widget_name(&format!("inbound-revoke-keyboard-{id}"));
                        } else if permission == Permission::Clipboard {
                            revoke.set_widget_name(&format!("inbound-revoke-clipboard-{id}"));
                        }
                        revoke.set_sensitive(ready);
                        let ui = ui.clone();
                        revoke.connect_clicked(move |_| {
                            ui.send(Command::Revoke {
                                connection: id,
                                permission,
                            })
                        });
                        row.add_suffix(&revoke);
                    }
                    entry.add_row(&row);
                }
                rows.append(&entry);
            }
        });
        section
    }
    fn sharing(self: &Rc<Self>) -> gtk::Box {
        let page = page(
            "共享设置",
            "按需开启共享。权限与媒体后端以后台实际状态为准。",
        );
        page.append(&self.startup.group());
        let media = adw::PreferencesGroup::builder().title("媒体与诊断").build();
        media.add(&self.switch(
            "GPU 加速",
            "是否使用 GPU 由驱动和当前会话共同决定",
            |s| s.gpu_enabled,
            |enabled, s| Command::SetGpu {
                enabled,
                retry: false,
                revision: s.revision,
            },
        ));
        let backend = adw::ActionRow::builder().title("当前媒体后端").build();
        let weak = backend.downgrade();
        self.bind(move |s, _| {
            if let Some(row) = weak.upgrade() {
                row.set_subtitle(match s.media_backend.as_str() {
                    "gpu" => "GPU 工作中",
                    "cpu" => "兼容模式",
                    "disabled" => "GPU 已关闭",
                    "" | "unavailable" => "等待后台",
                    _ => "等待媒体会话",
                });
            }
        });
        media.add(&backend);
        let retry = gtk::Button::with_label("重新尝试 GPU");
        retry.set_valign(gtk::Align::Center);
        let weak = retry.downgrade();
        self.bind(move |s, ready| {
            if let Some(button) = weak.upgrade() {
                button.set_sensitive(ready && s.gpu_enabled);
            }
        });
        let ui = self.clone();
        retry.connect_clicked(move |_| {
            let revision = ui.model.borrow().snapshot.revision;
            ui.send(Command::SetGpu {
                enabled: true,
                retry: true,
                revision,
            });
        });
        backend.add_suffix(&retry);
        page.append(&media);
        page.append(&crate::host_audio::group(self));
        page.append(&crate::host_clipboard::group(self));
        page.append(&crate::host_files::group(self));
        page.append(&crate::host_files::tasks(self));
        let group = adw::PreferencesGroup::builder().title("共享能力").build();
        for (title, value) in [("键鼠", 0), ("音频", 1), ("剪贴板", 2), ("文件传输", 3)]
        {
            let row = adw::ActionRow::builder().title(title).build();
            let state = label("正在读取…", "muted");
            row.add_suffix(&state);
            let weak = state.downgrade();
            self.bind(move |s, _| {
                if let Some(state) = weak.upgrade() {
                    let p = &s.sharing.permissions;
                    state.set_text(if [p.keyboard, p.audio, p.clipboard, p.file][value] {
                        "已启用"
                    } else {
                        "已关闭"
                    });
                }
            });
            group.add(&row);
        }
        page.append(&group);
        let diagnostics = adw::PreferencesGroup::new();
        let detail = adw::ExpanderRow::builder()
            .title("诊断详情")
            .subtitle("媒体后端选择原因")
            .build();
        let reason = self.text("muted", |s| s.media_reason.clone());
        reason.add_css_class("diagnostic-text");
        reason.set_wrap(true);
        reason.set_wrap_mode(gtk::pango::WrapMode::WordChar);
        reason.set_selectable(true);
        detail.add_row(&reason);
        diagnostics.add(&detail);
        page.append(&diagnostics);
        page
    }
    pub fn server_dialog(self: &Rc<Self>, window: &adw::ApplicationWindow) {
        let dialog = adw::PreferencesDialog::builder()
            .title("服务器设置")
            .build();
        let page = adw::PreferencesPage::new();
        let group = adw::PreferencesGroup::builder()
            .title("自建服务器")
            .description("保存后重新注册服务器；本机设备 ID 保持不变。")
            .build();
        let snapshot = &self.model.borrow().snapshot;
        let revision = snapshot.revision;
        let id = adw::EntryRow::builder()
            .title("ID 服务器")
            .text(&snapshot.server.rendezvous)
            .build();
        let relay = adw::EntryRow::builder()
            .title("中继服务器")
            .text(&snapshot.server.relay)
            .build();
        let key = adw::EntryRow::builder()
            .title("服务器公钥")
            .text(&snapshot.server.public_key)
            .build();
        for row in [&id, &relay, &key] {
            group.add(row);
        }
        let force = adw::SwitchRow::builder()
            .title("强制使用中继")
            .active(snapshot.server.force_relay)
            .build();
        group.add(&force);
        let save = gtk::Button::with_label("保存设置");
        save.add_css_class("suggested-action");
        save.set_sensitive(snapshot.role.is_some());
        group.add(&save);
        let ui = self.clone();
        let weak = dialog.downgrade();
        save.connect_clicked(move |_| {
            ui.send(Command::SetServer {
                settings: ServerSettings {
                    rendezvous: id.text().trim().into(),
                    relay: relay.text().trim().into(),
                    public_key: key.text().trim().into(),
                    force_relay: force.is_active(),
                },
                revision,
            });
            if let Some(dialog) = weak.upgrade() {
                dialog.close();
            }
        });
        page.add(&group);
        dialog.add(&page);
        dialog.present(Some(window));
    }
}
fn authentication(mode: Authentication) -> &'static str {
    match mode {
        Authentication::Permanent => "固定密码",
        Authentication::Temporary => "临时密码",
        Authentication::Both => "固定或临时密码",
        Authentication::Approval => "每次手动批准",
    }
}
