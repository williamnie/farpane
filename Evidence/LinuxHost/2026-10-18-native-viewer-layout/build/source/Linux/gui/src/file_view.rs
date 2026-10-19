//! A file-only companion window. Closing it drains/reaps its own worker.
use adw::prelude::*;
use farpane_protocol::{Command, EventKind, Phase, Secret, ViewerConfiguration};
use gtk::glib;
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    path::Path,
    rc::{Rc, Weak},
    time::Duration,
};
thread_local! {static OPEN:RefCell<Option<Weak<View>>>=const{RefCell::new(None)};}
pub struct View {
    peer: String,
    pub(crate) bridge: crate::viewer_bridge::Bridge,
    pub(crate) window: glib::WeakRef<adw::Window>,
    pub(crate) status: gtk::Label,
    pub(crate) auth: gtk::Box,
    pub(crate) password: gtk::PasswordEntry,
    pub(crate) submit: gtk::Button,
    pub(crate) secrets: Rc<crate::auth_secrets::Controls>,
    pub(crate) challenge: Cell<u8>,
    path: gtk::Entry,
    controls: gtk::Box,
    rows: gtk::ListBox,
    pub(crate) next: gtk::Button,
    page: Cell<u32>,
    current: RefCell<String>,
    pending: Cell<bool>,
    ready: Cell<bool>,
    pub(crate) jobs: RefCell<VecDeque<(i32, String, String, u64, u64, bool)>>,
    tasks: gtk::Box,
    pub(crate) exited: Cell<bool>,
    closing: Cell<bool>,
    pub(crate) events: RefCell<Vec<serde_json::Value>>,
}
pub fn close_all() -> bool {
    OPEN.with(|slot| {
        if let Some(view) = slot.borrow().as_ref().and_then(Weak::upgrade) {
            view.close();
            view.exited.get()
        } else {
            true
        }
    })
}
pub fn open(
    parent: &gtk::Window,
    peer: String,
    configuration: ViewerConfiguration,
) -> Result<Rc<View>, Box<dyn std::error::Error + Send + Sync>> {
    if let Some(existing) = OPEN.with(|slot| slot.borrow().as_ref().and_then(Weak::upgrade)) {
        if !existing.exited.get() {
            if let Some(window) = existing.window.upgrade() {
                window.present();
            }
            if existing.peer != peer {
                return Err("请先关闭当前文件连接，再连接另一台设备".into());
            }
            return Ok(existing);
        }
        if let Some(window) = existing.window.upgrade() {
            window.close();
        }
    }
    let secret_key = crate::credentials::Key::new(&peer, &configuration.server);
    let bridge = crate::viewer_bridge::Bridge::start_files(peer.clone(), configuration)?;
    let window = adw::Window::builder()
        .title(format!("FarPane 文件 · {peer}"))
        .transient_for(parent)
        .default_width(820)
        .default_height(620)
        .build();
    window.set_application(parent.application().as_ref());
    window.set_icon_name(Some("org.farpane.FarPane"));
    let root = gtk::Box::new(gtk::Orientation::Vertical, 10);
    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&adw::WindowTitle::new("FarPane 文件传输", &peer)));
    root.append(&header);
    let status = gtk::Label::new(Some("正在建立文件连接…"));
    status.set_wrap(true);
    root.append(&status);
    let auth = gtk::Box::new(gtk::Orientation::Vertical, 8);
    auth.set_halign(gtk::Align::Center);
    let password = gtk::PasswordEntry::builder().show_peek_icon(true).build();
    let submit = gtk::Button::with_label("验证并连接");
    let secret_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    secret_row.set_halign(gtk::Align::Center);
    secret_row.append(&password);
    secret_row.append(&submit);
    auth.append(&secret_row);
    let secrets = crate::auth_secrets::Controls::new(&password, secret_key);
    auth.append(&secrets.root);
    auth.set_visible(false);
    root.append(&auth);
    let controls = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    controls.set_margin_start(12);
    controls.set_margin_end(12);
    let up = gtk::Button::from_icon_name("go-up-symbolic");
    up.set_tooltip_text(Some("上一级"));
    controls.append(&up);
    let path = gtk::Entry::builder().text("/").hexpand(true).build();
    controls.append(&path);
    let refresh = gtk::Button::from_icon_name("view-refresh-symbolic");
    refresh.set_tooltip_text(Some("打开文件夹"));
    controls.append(&refresh);
    let upload = gtk::Button::with_label("发送文件");
    controls.append(&upload);
    let folder = gtk::Button::with_label("发送文件夹");
    controls.append(&folder);
    let next = gtk::Button::with_label("下一页");
    controls.append(&next);
    controls.set_sensitive(false);
    next.set_sensitive(false);
    root.append(&controls);
    let rows = gtk::ListBox::new();
    rows.set_selection_mode(gtk::SelectionMode::None);
    rows.add_css_class("boxed-list");
    let scroll = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .hexpand(true)
        .child(&rows)
        .build();
    scroll.set_margin_start(12);
    scroll.set_margin_end(12);
    root.append(&scroll);
    let tasks = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let task_scroll = gtk::ScrolledWindow::builder()
        .max_content_height(180)
        .propagate_natural_height(true)
        .child(&tasks)
        .build();
    root.append(&task_scroll);
    let toast = adw::ToastOverlay::new();
    toast.set_child(Some(&root));
    window.set_content(Some(&toast));
    let view = Rc::new(View {
        peer,
        bridge,
        window: window.downgrade(),
        status,
        auth,
        password,
        submit,
        secrets,
        challenge: Cell::new(0),
        path,
        controls,
        rows,
        next,
        page: Cell::new(0),
        current: RefCell::new("/".into()),
        pending: Cell::new(false),
        ready: Cell::new(false),
        jobs: RefCell::new(VecDeque::new()),
        tasks,
        exited: Cell::new(false),
        closing: Cell::new(false),
        events: RefCell::new(Vec::new()),
    });
    OPEN.with(|slot| *slot.borrow_mut() = Some(Rc::downgrade(&view)));
    let keep = view.clone();
    window.connect_close_request(move |_| {
        if keep.exited.get() {
            glib::Propagation::Proceed
        } else {
            keep.close();
            glib::Propagation::Stop
        }
    });
    let weak = Rc::downgrade(&view);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        if let Some(v) = weak.upgrade() {
            v.poll();
            if !v.exited.get() {
                return glib::ControlFlow::Continue;
            }
        }
        glib::ControlFlow::Break
    });
    let weak = Rc::downgrade(&view);
    view.submit.connect_clicked(move |_| {
        if let Some(v) = weak.upgrade() {
            let secret = Secret(v.password.text().to_string());
            if v.challenge.get() == 2 && !crate::auth_secrets::valid_two_factor(&secret.0) {
                v.status
                    .set_text(crate::auth_secrets::TWO_FACTOR_FORMAT_ERROR);
                v.password.grab_focus();
                return;
            }
            v.secrets.attempt(v.challenge.get(), &secret.0);
            v.password.set_text("");
            v.send(match v.challenge.get() {
                2 => Command::TwoFactor { code: secret },
                3 => Command::ConfirmInsecure { accept: true },
                _ => Command::Password { password: secret },
            });
            v.auth.set_visible(false);
        }
    });
    let weak = Rc::downgrade(&view);
    view.password.connect_activate(move |_| {
        if let Some(v) = weak.upgrade() {
            if v.auth.is_visible() {
                v.submit.emit_clicked();
            }
        }
    });
    let weak = Rc::downgrade(&view);
    refresh.connect_clicked(move |_| {
        if let Some(v) = weak.upgrade() {
            v.list(v.path.text().to_string(), 0);
        }
    });
    let weak = Rc::downgrade(&view);
    view.path.connect_activate(move |_| {
        if let Some(v) = weak.upgrade() {
            v.list(v.path.text().to_string(), 0);
        }
    });
    let weak = Rc::downgrade(&view);
    up.connect_clicked(move |_| {
        if let Some(v) = weak.upgrade() {
            let current = v.current.borrow().clone();
            let parent = current
                .trim_end_matches('/')
                .rsplit_once('/')
                .map(|(p, _)| p)
                .filter(|s| !s.is_empty())
                .unwrap_or("/");
            v.list(parent.into(), 0);
        }
    });
    let weak = Rc::downgrade(&view);
    view.next.connect_clicked(move |_| {
        if let Some(v) = weak.upgrade() {
            let path = v.current.borrow().clone();
            v.list(path, v.page.get() + 1);
        }
    });
    let weak = Rc::downgrade(&view);
    upload.connect_clicked(move |_| {
        if let Some(v) = weak.upgrade() {
            let w = v.window.upgrade();
            let weak = Rc::downgrade(&v);
            gtk::FileDialog::builder()
                .title("选择要发送的文件")
                .build()
                .open_multiple(w.as_ref(), None::<&gtk::gio::Cancellable>, move |result| {
                    if let (Ok(files), Some(v)) = (result, weak.upgrade()) {
                        if files.n_items() > 128 {
                            v.status
                                .set_text("一次最多选择 128 个文件；大批量文件可放入文件夹发送");
                            return;
                        }
                        let mut paths = Vec::new();
                        for index in 0..files.n_items() {
                            let path = files
                                .item(index)
                                .and_downcast::<gtk::gio::File>()
                                .and_then(|f| f.path());
                            let Some(path) = path else {
                                v.status.set_text("请选择本机文件");
                                return;
                            };
                            paths.push(path);
                        }
                        v.upload_files(&paths);
                    }
                });
        }
    });
    let weak = Rc::downgrade(&view);
    folder.connect_clicked(move |_| {
        if let Some(v) = weak.upgrade() {
            let parent = v.window.upgrade();
            let weak = Rc::downgrade(&v);
            gtk::FileDialog::builder()
                .title("选择要发送的文件夹")
                .build()
                .select_folder(
                    parent.as_ref(),
                    None::<&gtk::gio::Cancellable>,
                    move |result| {
                        if let (Ok(folder), Some(v)) = (result, weak.upgrade()) {
                            if let Some(path) = folder.path() {
                                v.upload_folder(&path);
                            }
                        }
                    },
                );
        }
    });
    window.present();
    Ok(view)
}
impl View {
    pub(crate) fn capture_smoke(&self, path: &Path) -> Result<(), String> {
        if crate::viewer::test_directory("FARPANE_FILES_SMOKE_DIR").is_none() {
            return Err("Not a private file UI test".into());
        }
        let window = self.window.upgrade().ok_or("File window closed")?;
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let snapshot = gtk::Snapshot::new();
        paintable.snapshot(&snapshot, window.width() as f64, window.height() as f64);
        let node = snapshot.to_node().ok_or("File window has no render node")?;
        let renderer = window.renderer().ok_or("File window has no renderer")?;
        renderer
            .render_texture(&node, None)
            .save_to_png(path)
            .map_err(|e| e.to_string())
    }
    pub(crate) fn send(&self, command: Command) {
        if let Err(error) = self.bridge.send(command) {
            self.status.set_text(&error.to_string());
        }
    }
    pub(crate) fn close(&self) {
        self.secrets.stop();
        self.closing.set(true);
        self.bridge.stop();
        self.controls.set_sensitive(false);
        // Polling ends after the child is reaped. A later close must still
        // destroy the companion window, otherwise it keeps the application up.
        if self.exited.get() {
            if let Some(window) = self.window.upgrade() {
                window.close();
            }
        }
    }
    fn list(&self, path: String, page: u32) {
        if self.pending.replace(true) {
            return;
        }
        self.controls.set_sensitive(false);
        self.send(Command::ListDirectory {
            path,
            page,
            remote: true,
        });
    }
    pub(crate) fn upload_path(&self, path: &Path) {
        if let (Some(local), Some(name)) =
            (path.to_str(), path.file_name().and_then(|n| n.to_str()))
        {
            let remote = format!("{}/{}", self.current.borrow().trim_end_matches('/'), name);
            self.send(Command::Transfer {
                local: local.into(),
                remote,
                upload: true,
                overwrite: false,
                directory: false,
            });
        }
    }
    pub(crate) fn download_to(&self, name: &str, parent: &Path) {
        self.download_item(name, parent, false);
    }
    pub(crate) fn download_item(&self, name: &str, parent: &Path, directory: bool) {
        let local = parent.join("FarPane").join(name);
        if let Some(local) = local.to_str() {
            self.send(Command::Transfer {
                local: local.into(),
                remote: format!("{}/{}", self.current.borrow().trim_end_matches('/'), name),
                upload: false,
                overwrite: false,
                directory,
            });
        }
    }
    pub(crate) fn upload_folder(&self, path: &Path) {
        if let (Some(local), Some(name)) =
            (path.to_str(), path.file_name().and_then(|n| n.to_str()))
        {
            self.send(Command::Transfer {
                local: local.into(),
                remote: format!("{}/{}", self.current.borrow().trim_end_matches('/'), name),
                upload: true,
                overwrite: false,
                directory: true,
            });
        }
    }
    pub(crate) fn upload_files(&self, paths: &[std::path::PathBuf]) {
        if paths.len() == 1 {
            self.upload_path(&paths[0]);
            return;
        }
        let local: Option<Vec<String>> = paths
            .iter()
            .map(|p| p.to_str().map(str::to_owned))
            .collect();
        let Some(local) = local else {
            self.status.set_text("文件路径须为 UTF-8");
            return;
        };
        if local.is_empty()
            || local.len() > 128
            || local.iter().map(|p| p.len() + 64).sum::<usize>() > 16 * 1024
        {
            self.status
                .set_text("所选文件过多或路径过长，请分次选择或发送文件夹");
            return;
        }
        self.send(Command::TransferFiles {
            local,
            remote: self.current.borrow().clone(),
        });
    }
    fn poll(self: &Rc<Self>) {
        self.secrets.poll();
        let update = self.bridge.take();
        if let Some(error) = update.error {
            self.status.set_text(&error);
        }
        for event in update.events {
            if crate::viewer::test_directory("FARPANE_FILES_SMOKE_DIR").is_some() {
                let mut events = self.events.borrow_mut();
                if events.len() < 1000 {
                    events.push(serde_json::to_value(&event).unwrap());
                }
            }
            match event.event {
                EventKind::AuthenticationChallenge {
                    two_factor,
                    insecure,
                    detail,
                } => {
                    self.challenge.set(if insecure {
                        3
                    } else if two_factor {
                        2
                    } else {
                        1
                    });
                    self.secrets.challenge(!insecure && !two_factor);
                    self.status.set_text(&detail);
                    self.password.set_visible(!insecure);
                    self.submit.set_label(if insecure {
                        "继续未加密连接"
                    } else {
                        "验证并连接"
                    });
                    self.auth.set_visible(true);
                    self.password.grab_focus();
                }
                EventKind::Phase { phase, detail } => {
                    self.status.set_text(&detail);
                    if phase == Phase::PasswordRequired {
                        self.secrets.challenge(true);
                        self.challenge.set(1);
                        self.password.set_visible(true);
                        self.submit.set_label("验证并连接");
                        self.auth.set_visible(true);
                        self.password.grab_focus();
                    }
                    if phase == Phase::FilesReady {
                        self.secrets.authenticated();
                        self.ready.set(true);
                        self.auth.set_visible(false);
                    }
                    if matches!(phase, Phase::Failed | Phase::Ended) {
                        self.secrets.stop();
                        self.ready.set(false);
                        self.auth.set_visible(false);
                        self.controls.set_sensitive(false);
                    }
                }
                EventKind::Directory {
                    path,
                    page,
                    more,
                    entries,
                } => {
                    self.pending.set(false);
                    self.path.set_text(&path);
                    *self.current.borrow_mut() = path;
                    self.page.set(page);
                    self.controls
                        .set_sensitive(self.ready.get() && !self.closing.get());
                    self.next.set_sensitive(more);
                    self.status
                        .set_text(&format!("第 {} 页 · {} 项", page + 1, entries.len()));
                    while let Some(child) = self.rows.first_child() {
                        self.rows.remove(&child);
                    }
                    for entry in entries {
                        let row = adw::ActionRow::builder().title(&entry.name).build();
                        row.set_use_markup(false);
                        row.set_subtitle(if entry.directory {
                            "文件夹"
                        } else {
                            "文件"
                        });
                        if entry.directory {
                            let open = gtk::Button::with_label("打开");
                            open.set_valign(gtk::Align::Center);
                            row.add_suffix(&open);
                            let weak = Rc::downgrade(self);
                            let name = entry.name.clone();
                            open.connect_clicked(move |_| {
                                if let Some(v) = weak.upgrade() {
                                    let path = format!(
                                        "{}/{}",
                                        v.current.borrow().trim_end_matches('/'),
                                        name
                                    );
                                    v.list(path, 0);
                                }
                            });
                        }
                        let button = gtk::Button::with_label(if entry.directory {
                            "接收文件夹"
                        } else {
                            "接收"
                        });
                        button.set_valign(gtk::Align::Center);
                        row.add_suffix(&button);
                        let weak = Rc::downgrade(self);
                        button.connect_clicked(move |_| {
                            if let Some(v) = weak.upgrade() {
                                let w = v.window.upgrade();
                                let name = entry.name.clone();
                                let directory = entry.directory;
                                let weak = Rc::downgrade(&v);
                                gtk::FileDialog::builder()
                                    .title("选择接收位置（保存在 FarPane 文件夹）")
                                    .build()
                                    .select_folder(
                                        w.as_ref(),
                                        None::<&gtk::gio::Cancellable>,
                                        move |result| {
                                            if let (Ok(folder), Some(v)) = (result, weak.upgrade())
                                            {
                                                if let Some(path) = folder.path() {
                                                    v.download_item(&name, &path, directory);
                                                }
                                            }
                                        },
                                    );
                            }
                        });
                        self.rows.append(&row);
                    }
                }
                EventKind::Transfer {
                    job,
                    name,
                    done,
                    total,
                    status,
                    needs_confirmation,
                } => {
                    let mut jobs = self.jobs.borrow_mut();
                    if let Some(index) = jobs.iter().position(|j| j.0 == job) {
                        jobs.remove(index);
                    }
                    jobs.push_back((job, name, status, done, total, needs_confirmation));
                    while jobs.len() > 16 {
                        jobs.pop_front();
                    }
                    drop(jobs);
                    self.render_jobs();
                }
                EventKind::Reply {
                    error: Some(error), ..
                }
                | EventKind::Log {
                    level: _,
                    message: error,
                } => {
                    self.status.set_text(&error);
                    self.pending.set(false);
                    if self.ready.get() && !self.exited.get() && !self.closing.get() {
                        self.controls.set_sensitive(true);
                    }
                }
                _ => {}
            }
        }
        if update.exited {
            self.secrets.stop();
            self.exited.set(true);
            self.controls.set_sensitive(false);
            self.auth.set_visible(false);
            for job in self.jobs.borrow_mut().iter_mut() {
                if !matches!(
                    job.2.as_str(),
                    "completed" | "completed_with_skips" | "failed" | "cancelled" | "timed_out"
                ) {
                    job.2 = if self.closing.get() {
                        "cancelled"
                    } else {
                        "interrupted"
                    }
                    .into();
                    job.5 = false;
                }
            }
            self.render_jobs();
            if self.closing.get() {
                if let Some(w) = self.window.upgrade() {
                    w.close();
                }
            }
        }
    }
    fn render_jobs(self: &Rc<Self>) {
        while let Some(child) = self.tasks.first_child() {
            self.tasks.remove(&child);
        }
        for (id, name, status, done, total, confirm) in self.jobs.borrow().iter().rev() {
            let row = adw::ActionRow::builder().title(name).build();
            row.set_use_markup(false);
            let label = match status.as_str() {
                "completed" => "已完成",
                "completed_with_skips" => "已完成（部分对象已跳过）",
                "scanning" => "正在扫描文件夹",
                "failed" => "失败",
                "cancelled" => "已取消",
                "sending" => "正在发送",
                "receiving" => "正在接收",
                "overwrite_required" => "本地已有同名文件或文件夹",
                "timed_out" => "已超时",
                "interrupted" => "已中断",
                _ => "等待远端确认",
            };
            row.set_subtitle(&if *total == 0 && *done > 0 {
                format!("{label} · 已传输 {done} 字节（总大小待确定）")
            } else {
                format!("{label} · {done} / {total} 字节")
            });
            let id = *id;
            if *confirm {
                let button = gtk::Button::with_label("允许替换已有文件");
                button.set_widget_name(&format!("file-local-replace-{id}"));
                button.set_valign(gtk::Align::Center);
                let weak = Rc::downgrade(self);
                button.connect_clicked(move |_| {
                    if let Some(v) = weak.upgrade() {
                        let dialog = adw::MessageDialog::new(
                            v.window.upgrade().as_ref(),
                            Some("替换已有文件？"),
                            Some("目录会合并，每个同名文件在完整接收后替换。取消会保留已完成的文件，未完成文件的原内容不变。"),
                        );
                        dialog.add_responses(&[("cancel", "取消"), ("replace", "替换")]);
                        dialog.set_close_response("cancel");
                        dialog.set_response_appearance(
                            "replace",
                            adw::ResponseAppearance::Destructive,
                        );
                        let weak = Rc::downgrade(&v);
                        dialog.connect_response(None, move |_, response| {
                            if let Some(v) = weak.upgrade() {
                                v.send(Command::ConfirmTransfer {
                                    job: id,
                                    accept: response == "replace",
                                    overwrite: response == "replace",
                                });
                            }
                        });
                        dialog.present();
                    }
                });
                row.add_suffix(&button);
            }
            if !matches!(
                status.as_str(),
                "completed"
                    | "completed_with_skips"
                    | "failed"
                    | "cancelled"
                    | "timed_out"
                    | "interrupted"
            ) {
                let cancel = gtk::Button::with_label("取消");
                cancel.set_valign(gtk::Align::Center);
                let weak = Rc::downgrade(self);
                cancel.connect_clicked(move |_| {
                    if let Some(v) = weak.upgrade() {
                        v.send(Command::CancelTransfer { job: id });
                    }
                });
                row.add_suffix(&cancel);
            }
            self.tasks.append(&row);
        }
    }
}
