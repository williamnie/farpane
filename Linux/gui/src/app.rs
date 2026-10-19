use crate::model::Model;
use adw::prelude::*;
use gtk::{gdk, glib};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

pub fn build(app: &adw::Application) -> Rc<Shell> {
    adw::StyleManager::default().set_color_scheme(adw::ColorScheme::ForceDark);
    if let Some(display) = gdk::Display::default() {
        let css = gtk::CssProvider::new();
        css.load_from_resource("/org/farpane/FarPane/style.css");
        gtk::style_context_add_provider_for_display(
            &display,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        gtk::IconTheme::for_display(&display).add_resource_path("/org/farpane/FarPane/icons");
    }
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("FarPane")
        .default_width(1020)
        .default_height(720)
        .build();
    window.set_icon_name(Some("org.farpane.FarPane"));
    let model = Rc::new(RefCell::new(Model::default()));
    let toast = adw::ToastOverlay::new();
    let ui = crate::host::Ui::new(model.clone(), &toast);
    let shell = Rc::new(Shell {
        window: window.downgrade(),
        toast: toast.downgrade(),
        ui: ui.clone(),
        status: RefCell::new(glib::WeakRef::new()),
        viewer: RefCell::new(None),
        pending: RefCell::new(None),
        tray_dialog: RefCell::new(glib::WeakRef::new()),
        close_when_ready: Cell::new(false),
    });
    let nav = shell.show_home();
    window.set_content(Some(&toast));
    let weak = Rc::downgrade(&shell);
    *ui.on_connect.borrow_mut() = Some(Box::new(move |peer, audio| {
        if let Some(shell) = weak.upgrade() {
            shell.connect(peer, audio);
        }
    }));
    let owner = shell.clone();
    window.connect_close_request(move |_| {
        owner.close_when_ready.set(true);
        let files_done = crate::file_view::close_all();
        owner.pending.borrow_mut().take();
        let viewer = owner.viewer.borrow().clone();
        if let Some(viewer) = viewer {
            if !viewer.has_exited() {
                viewer.close();
                return glib::Propagation::Stop;
            }
        }
        if files_done {
            glib::Propagation::Proceed
        } else {
            glib::Propagation::Stop
        }
    });
    window.present();
    crate::file_smoke::attach(&ui, &window);
    crate::inbound_smoke::attach(&ui, &window);
    crate::desktop_smoke::attach(&ui, &window);
    // Explicit isolated integration driver; never enabled by an ordinary launch.
    if crate::viewer::smoke_directory().is_some() {
        let weak = Rc::downgrade(&shell);
        let began = std::time::Instant::now();
        glib::timeout_add_local(std::time::Duration::from_millis(100), move || {
            let Some(shell) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if shell.ui.model.borrow().snapshot.role.is_none()
                || began.elapsed() < std::time::Duration::from_secs(3)
            {
                return glib::ControlFlow::Continue;
            }
            if let Some(directory) = crate::viewer::smoke_directory() {
                crate::viewer::smoke_trim(&directory, "home");
                for (source, target) in [
                    ("/proc/self/smaps", "home-smaps.txt"),
                    ("/proc/self/smaps_rollup", "home-memory.txt"),
                ] {
                    let _ = std::fs::read(source)
                        .and_then(|bytes| std::fs::write(directory.join(target), bytes));
                }
            }
            let target =
                if std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("auto-reconnect") {
                    "127.0.0.1:21119"
                } else {
                    "127.0.0.1:21118"
                };
            shell.connect(target.into(), false);
            glib::ControlFlow::Break
        });
    }
    let weak = Rc::downgrade(&shell);
    glib::timeout_add_local(std::time::Duration::from_millis(250), move || {
        let Some(shell) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if shell.window.upgrade().is_none() {
            return glib::ControlFlow::Break;
        }
        if shell.close_when_ready.get()
            && shell
                .viewer
                .borrow()
                .as_ref()
                .is_none_or(|v| v.has_exited())
            && crate::file_view::close_all()
        {
            if let Some(window) = shell.window.upgrade() {
                window.close();
            }
            return glib::ControlFlow::Break;
        }
        shell.ui.poll(shell.status.borrow().upgrade().as_ref());
        glib::ControlFlow::Continue
    });

    if let Some(directory) = std::env::var_os("FARPANE_SMOKE_REPORT_DIR") {
        let directory = std::path::PathBuf::from(directory);
        let weak_window = window.downgrade();
        let weak_nav = nav.downgrade();
        let smoke_model = model.clone();
        let mut page_index = 0;
        glib::timeout_add_local(std::time::Duration::from_secs(1), move || {
            let (Some(window), Some(nav)) = (weak_window.upgrade(), weak_nav.upgrade()) else {
                return glib::ControlFlow::Break;
            };
            if let Err(error) = capture_smoke(
                &window,
                &directory,
                page_index,
                &smoke_model.borrow().snapshot,
            ) {
                eprintln!("FarPane smoke capture failed: {error}");
                window.close();
                return glib::ControlFlow::Break;
            }
            page_index += 1;
            if page_index == 3 {
                return glib::ControlFlow::Break;
            }
            nav.select_row(nav.row_at_index(page_index).as_ref());
            glib::ControlFlow::Continue
        });
    }

    // Isolated smoke runner sets this; ordinary launches have no sampling timer.
    if let Ok(seconds) = std::env::var("FARPANE_SMOKE_EXIT_SECONDS")
        .unwrap_or_default()
        .parse::<u64>()
    {
        let weak = window.downgrade();
        glib::timeout_add_local_once(std::time::Duration::from_secs(seconds.min(60)), move || {
            if let Some(window) = weak.upgrade() {
                window.close();
            }
        });
    }
    shell
}

pub(crate) struct Shell {
    window: glib::WeakRef<adw::ApplicationWindow>,
    toast: glib::WeakRef<adw::ToastOverlay>,
    ui: Rc<crate::host::Ui>,
    status: RefCell<glib::WeakRef<gtk::Label>>,
    viewer: RefCell<Option<Rc<crate::viewer::View>>>,
    pending: RefCell<Option<Connection>>,
    tray_dialog: RefCell<glib::WeakRef<adw::MessageDialog>>,
    close_when_ready: Cell<bool>,
}
#[derive(Clone)]
struct Connection {
    peer: String,
    audio: bool,
    configuration: farpane_protocol::ViewerConfiguration,
    recovery: Rc<crate::viewer_recovery::Recovery>,
}
impl Shell {
    pub(crate) fn present(&self) {
        if let Some(window) = self.window.upgrade() {
            window.present();
        }
    }
    pub(crate) fn show_connections(&self) {
        if let Some(window) = self.window.upgrade() {
            self.ui.show_sessions(&window);
        }
    }
    pub(crate) fn tray_menu(self: &Rc<Self>) {
        if let Some(dialog) = self.tray_dialog.borrow().upgrade() {
            if dialog.is_visible() {
                dialog.present();
                return;
            }
        }
        let Some(window) = self.window.upgrade() else {
            return;
        };
        let dialog = adw::MessageDialog::new(
            Some(&window),
            Some("FarPane"),
            Some("查看连接请求或返回当前窗口。"),
        );
        dialog.add_responses(&[
            ("close", "关闭菜单"),
            ("open", "打开 FarPane"),
            ("connections", "本机连接与权限"),
        ]);
        dialog.set_close_response("close");
        dialog.set_destroy_with_parent(true);
        *self.tray_dialog.borrow_mut() = dialog.downgrade();
        let weak = Rc::downgrade(self);
        dialog.connect_response(None, move |_, response| {
            if let Some(shell) = weak.upgrade() {
                match response {
                    "open" => shell.present(),
                    "connections" => shell.show_connections(),
                    _ => (),
                }
            }
        });
        dialog.present();
    }
    fn show_home(self: &Rc<Self>) -> gtk::ListBox {
        let window = self.window.upgrade().expect("live window");
        let (root, status, nav) = home(&window, &self.ui);
        *self.status.borrow_mut() = status.downgrade();
        if let Some(toast) = self.toast.upgrade() {
            toast.set_child(Some(&root));
        }
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(std::time::Duration::from_secs(2), move || {
            if let Some(shell) = weak.upgrade() {
                if shell.viewer.borrow().is_none() && shell.window.upgrade().is_some() {
                    crate::memory::reclaim_idle();
                }
            }
        });
        nav
    }
    fn connect(self: &Rc<Self>, peer: String, audio: bool) {
        let snapshot = self.ui.model.borrow().snapshot.clone();
        if snapshot.role.is_none() || snapshot.local_id.is_empty() {
            return;
        }
        let configuration = farpane_protocol::ViewerConfiguration {
            local_id: snapshot.local_id,
            server: snapshot.server,
        };
        let recovery = Rc::new(crate::viewer_recovery::Recovery::new(&peer, &configuration));
        let request = Connection {
            peer,
            audio,
            configuration,
            recovery,
        };
        if self.viewer.borrow().is_some() || self.pending.borrow().is_some() {
            let Some(window) = self.window.upgrade() else {
                return;
            };
            let dialog = adw::MessageDialog::new(
                Some(&window),
                Some("替换当前连接？"),
                Some("将先断开当前设备，再连接所选设备。"),
            );
            dialog.add_responses(&[("cancel", "取消"), ("replace", "断开并连接")]);
            dialog.set_response_appearance("replace", adw::ResponseAppearance::Destructive);
            dialog.set_close_response("cancel");
            let weak = Rc::downgrade(self);
            dialog.connect_response(None, move |_, response| {
                if response == "replace" {
                    if let Some(shell) = weak.upgrade() {
                        shell.replace(request.clone());
                    }
                }
            });
            dialog.present();
        } else {
            self.open(request);
        }
    }
    fn replace(self: &Rc<Self>, request: Connection) {
        if self.close_when_ready.get() {
            return;
        }
        *self.pending.borrow_mut() = Some(request);
        let viewer = self.viewer.borrow().clone();
        if let Some(viewer) = viewer {
            viewer.close();
        } else {
            self.finished();
        }
    }
    fn finished(self: &Rc<Self>) {
        self.viewer.borrow_mut().take();
        if let Some(toast) = self.toast.upgrade() {
            toast.set_child(None::<&gtk::Widget>);
        }
        let pending = self.pending.borrow().is_some();
        if self.close_when_ready.get() || (!pending && crate::viewer::smoke_directory().is_some()) {
            self.pending.borrow_mut().take();
            if let Some(window) = self.window.upgrade() {
                window.close();
            }
        } else if pending {
            // Let the old render signal and widget destruction finish before
            // creating the next context/worker. Retrying cannot overlap owners.
            let weak = Rc::downgrade(self);
            glib::idle_add_local_once(move || {
                if let Some(shell) = weak.upgrade() {
                    if !shell.close_when_ready.get() {
                        let request = shell.pending.borrow_mut().take();
                        if let Some(request) = request {
                            shell.open(request);
                        }
                    }
                }
            });
        } else {
            self.show_home();
        }
    }
    fn open(self: &Rc<Self>, request: Connection) {
        if self.viewer.borrow().is_some() || self.close_when_ready.get() {
            return;
        }
        let weak = Rc::downgrade(self);
        let retry_shell = Rc::downgrade(self);
        let retry_request = request.clone();
        let history_ui = Rc::downgrade(&self.ui);
        let history_peer = request.peer.clone();
        let history_server = request.configuration.server.clone();
        let result = crate::viewer::View::new(
            request.peer,
            request.audio,
            request.configuration,
            request.recovery,
            &self.ui,
            move |name| {
                if let Some(ui) = history_ui.upgrade() {
                    ui.remember(
                        history_peer.clone(),
                        history_server.clone(),
                        name.to_owned(),
                    );
                }
            },
            move |automatic, audio| {
                if let Some(shell) = retry_shell.upgrade() {
                    let mut request = retry_request.clone();
                    if automatic {
                        request.audio = audio;
                    } else {
                        request.recovery = Rc::new(crate::viewer_recovery::Recovery::new(
                            &request.peer,
                            &request.configuration,
                        ));
                    }
                    shell.replace(request);
                }
            },
            move || {
                if let Some(shell) = weak.upgrade() {
                    shell.finished();
                }
            },
        );
        match result {
            Ok(viewer) => {
                if let Some(toast) = self.toast.upgrade() {
                    toast.set_child(Some(&viewer.root));
                }
                *self.viewer.borrow_mut() = Some(viewer);
            }
            Err(error) => {
                self.show_home();
                if let Some(toast) = self.toast.upgrade() {
                    toast.add_toast(adw::Toast::new(&error.to_string()));
                }
            }
        }
    }
}
fn home(
    window: &adw::ApplicationWindow,
    ui: &Rc<crate::host::Ui>,
) -> (gtk::Box, gtk::Label, gtk::ListBox) {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let header = adw::HeaderBar::new();
    let title = adw::WindowTitle::new(
        "FarPane",
        &format!("Linux · v{}", crate::installed_version().version),
    );
    title.set_widget_name("installed-version-title");
    header.set_title_widget(Some(&title));
    let status = label("后台未连接", "status-pill");
    header.pack_end(&status);
    let settings = gtk::Button::from_icon_name("emblem-system-symbolic");
    settings.set_tooltip_text(Some("服务器设置"));
    let weak_window = window.downgrade();
    let settings_ui = ui.clone();
    settings.connect_clicked(move |_| {
        if let Some(window) = weak_window.upgrade() {
            settings_ui.server_dialog(&window);
        }
    });
    header.pack_end(&settings);
    root.append(&header);

    let body = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    body.set_vexpand(true);
    let sidebar = gtk::Box::new(gtk::Orientation::Vertical, 6);
    sidebar.add_css_class("sidebar");
    sidebar.set_width_request(208);
    sidebar.set_hexpand(false);
    let brand_row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    brand_row.set_margin_start(4);
    let icon = gtk::Image::from_icon_name("org.farpane.FarPane");
    icon.set_pixel_size(36);
    brand_row.append(&icon);
    brand_row.append(&label("FarPane", "brand"));
    sidebar.append(&brand_row);
    sidebar.append(&label("LINUX · NATIVE", "brand-subtitle"));
    let nav = gtk::ListBox::new();
    nav.set_widget_name("home-navigation");
    nav.add_css_class("navigation-sidebar");
    nav.add_css_class("home-nav");
    for (icon, name) in [
        ("computer-symbolic", "设备"),
        ("security-high-symbolic", "授权与安全"),
        ("preferences-system-sharing-symbolic", "共享设置"),
    ] {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        row.append(&gtk::Image::from_icon_name(icon));
        row.append(&label(name, ""));
        nav.append(&row);
    }
    sidebar.append(&nav);
    let spacer = gtk::Box::new(gtk::Orientation::Vertical, 0);
    spacer.set_vexpand(true);
    sidebar.append(&spacer);
    let core_version = crate::installed_version().core_build.as_deref()
        .map(|build| format!("主机核心 {build}"))
        .unwrap_or_else(|| "构建未标识".into());
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    footer.add_css_class("sidebar-footer");
    let core_version = label(&core_version, "muted");
    core_version.set_widget_name("installed-core-version");
    core_version.set_selectable(true);
    core_version.set_hexpand(true);
    core_version.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    core_version.set_tooltip_text(Some("本机 Linux 核心构建。后台连接成功时，界面与后台已核对为同一安装构建。"));
    footer.append(&core_version);
    let about = gtk::Button::from_icon_name("help-about-symbolic");
    about.set_tooltip_text(Some("关于 FarPane"));
    about.add_css_class("flat");
    about.add_css_class("circular");
    let weak_window = window.downgrade();
    about.connect_clicked(move |_| {
        if let Some(window) = weak_window.upgrade() {
            let dialog = adw::AboutDialog::builder()
                .application_name("FarPane")
                .application_icon("org.farpane.FarPane")
                .version(&crate::installed_version().version)
                .developer_name("FarPane")
                .comments("原生 Linux 远程桌面")
                .build();
            dialog.present(Some(&window));
        }
    });
    footer.append(&about);
    sidebar.append(&footer);
    body.append(&sidebar);
    let scroll = gtk::ScrolledWindow::builder()
        .hexpand(true)
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build();
    let weak_scroll = scroll.downgrade();
    let page_ui = ui.clone();
    nav.connect_row_selected(move |_, row| {
        let Some(scroll) = weak_scroll.upgrade() else {
            return;
        };
        let index = row.map(|r| r.index()).unwrap_or(0);
        let page = page_ui.select(index);
        // Replace and release the old page; do not retain hidden page trees.
        let clamp = adw::Clamp::builder()
            .maximum_size(880)
            .tightening_threshold(640)
            .child(&page)
            .build();
        scroll.set_child(Some(&clamp));
    });
    body.append(&scroll);
    root.append(&body);
    let initial_page = if crate::viewer::test_directory("FARPANE_AUDIO_UI_SMOKE_DIR").is_some()
        || crate::viewer::test_directory("FARPANE_HOST_CLIPBOARD_UI_DIR").is_some()
        || crate::viewer::test_directory("FARPANE_FILES_SMOKE_DIR").is_some()
    {
        2
    } else if crate::viewer::test_directory("FARPANE_REVOKE_AUDIO_SMOKE_DIR").is_some()
        || crate::viewer::test_directory("FARPANE_REVOKE_CLIPBOARD_SMOKE_DIR").is_some()
    {
        1
    } else {
        0
    };
    nav.select_row(nav.row_at_index(initial_page).as_ref());
    crate::host_audio_smoke::attach_revoke(ui, &root);
    (root, status, nav)
}

fn capture_smoke(
    window: &adw::ApplicationWindow,
    directory: &std::path::Path,
    page: i32,
    state: &farpane_protocol::Snapshot,
) -> Result<(), Box<dyn std::error::Error>> {
    // Executed only by an explicitly configured, isolated smoke runner.
    std::fs::create_dir_all(directory)?;
    // Measure before allocating the export texture used by this test driver.
    std::fs::write(
        directory.join(format!("page-{page}-memory.txt")),
        std::fs::read("/proc/self/smaps_rollup")?,
    )?;
    std::fs::write(
        directory.join(format!("page-{page}-smaps.txt")),
        std::fs::read("/proc/self/smaps")?,
    )?;
    // The smoke report proves the data source without exporting IDs or secrets.
    std::fs::write(
        directory.join(format!("page-{page}-state.json")),
        serde_json::to_vec_pretty(&serde_json::json!({
            "role": state.role, "revision": state.revision,
            "permanent_password_set": state.permanent_password_set,
            "temporary_password_present": state.temporary_password.is_some(),
            "gpu_enabled": state.gpu_enabled,
        }))?,
    )?;
    let snapshot = gtk::Snapshot::new();
    let paintable = gtk::WidgetPaintable::new(Some(window));
    paintable.snapshot(
        &snapshot,
        f64::from(window.width()),
        f64::from(window.height()),
    );
    let node = snapshot.to_node().ok_or("window produced no render node")?;
    let renderer = window.renderer().ok_or("window has no renderer")?;
    let texture = renderer.render_texture(&node, None);
    texture.save_to_png(directory.join(format!("page-{page}.png")))?;
    std::fs::write(
        directory.join(format!("page-{page}-maps.txt")),
        std::fs::read("/proc/self/maps")?,
    )?;
    Ok(())
}

pub(crate) fn label(text: &str, class: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.set_xalign(0.0);
    if !class.is_empty() {
        label.add_css_class(class);
    }
    label
}
pub(crate) fn page(title: &str, subtitle: &str) -> gtk::Box {
    let page = gtk::Box::new(gtk::Orientation::Vertical, 28);
    page.add_css_class("content-page");
    let heading = gtk::Box::new(gtk::Orientation::Vertical, 6);
    heading.append(&label(title, "page-title"));
    heading.append(&label(subtitle, "page-subtitle"));
    page.append(&heading);
    page
}
pub(crate) fn card(title: &str) -> gtk::Box {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 16);
    card.add_css_class("card");
    card.append(&label(title, "card-title"));
    card
}
