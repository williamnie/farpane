use crate::updates::{CheckResult, Release, Version, CHECK_INTERVAL, RELEASES_URL, RETRY_INTERVAL};
use adw::prelude::*;
use gtk::{gio, glib};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::mpsc,
    time::{Duration, Instant},
};

type Binding = Box<dyn Fn(&Updates) -> bool>;

pub struct Updates {
    automatic: Cell<bool>,
    busy: Cell<bool>,
    next_check: Cell<Option<Instant>>,
    latest: RefCell<Option<Release>>,
    message: RefCell<String>,
    bindings: RefCell<Vec<Binding>>,
    toast: glib::WeakRef<adw::ToastOverlay>,
}

impl Updates {
    pub fn new(toast: &adw::ToastOverlay) -> Rc<Self> {
        let preference = read_preference();
        let owner = Rc::new(Self {
            automatic: Cell::new(preference.as_ref().copied().unwrap_or(false)),
            busy: Cell::new(false),
            next_check: Cell::new(None),
            latest: RefCell::new(None),
            message: RefCell::new(preference.err().unwrap_or_else(|| "尚未检查更新".into())),
            bindings: RefCell::new(Vec::new()),
            toast: toast.downgrade(),
        });
        let weak = Rc::downgrade(&owner);
        glib::timeout_add_local_once(Duration::from_secs(5), move || {
            if let Some(owner) = weak.upgrade() {
                owner.check(false);
            }
        });
        let weak = Rc::downgrade(&owner);
        glib::timeout_add_local(Duration::from_secs(60), move || {
            let Some(owner) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            owner.check(false);
            glib::ControlFlow::Continue
        });
        owner
    }

    fn render(&self) {
        self.bindings.borrow_mut().retain(|binding| binding(self));
    }

    fn notice(&self, text: &str) {
        if let Some(toast) = self.toast.upgrade() {
            toast.add_toast(adw::Toast::new(text));
        }
    }

    fn check(self: &Rc<Self>, manual: bool) {
        if self.busy.get()
            || (!manual
                && (!self.automatic.get()
                    || self
                        .next_check
                        .get()
                        .is_some_and(|next| Instant::now() < next)))
        {
            return;
        }
        let current = &crate::installed_version().version;
        if Version::parse(current).is_none() {
            *self.message.borrow_mut() =
                "当前构建没有可比较的版本号，请前往发布页检查更新。".into();
            self.next_check.set(Some(Instant::now() + CHECK_INTERVAL));
            if manual {
                self.notice(&self.message.borrow());
            }
            self.render();
            return;
        }
        self.busy.set(true);
        *self.message.borrow_mut() = "正在检查更新…".into();
        self.render();
        let (send, receive) = mpsc::channel();
        let cancel = gio::Cancellable::new();
        let worker_cancel = cancel.clone();
        let current = current.clone();
        std::thread::spawn(move || {
            let _ = send.send(crate::update_network::check(&current, &worker_cancel));
        });
        let weak = Rc::downgrade(self);
        let deadline = Instant::now() + Duration::from_secs(25);
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(owner) = weak.upgrade() else {
                cancel.cancel();
                return glib::ControlFlow::Break;
            };
            if Instant::now() >= deadline {
                cancel.cancel();
            }
            let result = match receive.try_recv() {
                Ok(result) => result,
                Err(mpsc::TryRecvError::Empty) => return glib::ControlFlow::Continue,
                Err(mpsc::TryRecvError::Disconnected) => Err("更新检查未完成，请重试。".into()),
            };
            owner.busy.set(false);
            owner.next_check.set(Some(
                Instant::now()
                    + if result.is_ok() {
                        CHECK_INTERVAL
                    } else {
                        RETRY_INTERVAL
                    },
            ));
            match result {
                Ok(CheckResult::Available(release)) => {
                    *owner.message.borrow_mut() = release_message(&release);
                    *owner.latest.borrow_mut() = Some(release);
                }
                Ok(CheckResult::Current) => {
                    *owner.message.borrow_mut() = "当前已是适用于本机的最新版本".into();
                    owner.latest.borrow_mut().take();
                }
                Err(error) => *owner.message.borrow_mut() = error,
            }
            // 自动检查失败只更新设置状态，不弹通知或中断远程会话。
            if manual {
                owner.notice(&owner.message.borrow());
            }
            owner.render();
            glib::ControlFlow::Break
        });
    }

    fn open_release(self: &Rc<Self>) {
        let url = self
            .latest
            .borrow()
            .as_ref()
            .map(Release::url)
            .unwrap_or_else(|| RELEASES_URL.into());
        let weak = Rc::downgrade(self);
        gio::AppInfo::launch_default_for_uri_async(
            &url,
            None::<&gio::AppLaunchContext>,
            None::<&gio::Cancellable>,
            move |result| {
                if result.is_err() {
                    if let Some(owner) = weak.upgrade() {
                        owner.notice("无法打开浏览器，请手动访问 FarPane 的 GitHub 发布页。");
                    }
                }
            },
        );
    }

    pub fn banner(self: &Rc<Self>) -> adw::Banner {
        let banner = adw::Banner::new("");
        banner.set_widget_name("software-update-banner");
        banner.set_button_label(Some("前往下载"));
        let owner = self.clone();
        banner.connect_button_clicked(move |_| owner.open_release());
        let weak = banner.downgrade();
        self.bindings.borrow_mut().push(Box::new(move |owner| {
            let Some(banner) = weak.upgrade() else {
                return false;
            };
            let latest = owner.latest.borrow();
            banner.set_revealed(latest.is_some());
            if let Some(release) = latest.as_ref() {
                banner.set_title(&release_message(release));
            }
            true
        }));
        self.render();
        banner
    }

    pub fn group(self: &Rc<Self>) -> adw::PreferencesGroup {
        let group = adw::PreferencesGroup::builder()
            .title("软件更新")
            .description("检查 GitHub 发布的新版本（含预览版）；下载后手动安装。")
            .build();
        let automatic = adw::SwitchRow::builder()
            .title("自动检查更新")
            .subtitle("启动后及运行期间每 6 小时检查；发现新版后在首页提示。")
            .active(self.automatic.get())
            .build();
        automatic.set_widget_name("software-update-automatic");
        let owner = self.clone();
        automatic.connect_active_notify(move |row| {
            if row.is_active() == owner.automatic.get() {
                return;
            }
            match write_preference(row.is_active()) {
                Ok(()) => {
                    owner.automatic.set(row.is_active());
                    if row.is_active() {
                        owner.next_check.set(None);
                        owner.check(false);
                    }
                }
                Err(error) => {
                    row.set_active(owner.automatic.get());
                    owner.notice(&error);
                    *owner.message.borrow_mut() = error;
                }
            }
            owner.render();
        });
        group.add(&automatic);
        let status = adw::ActionRow::builder()
            .title(format!("当前版本 {}", crate::installed_version().version))
            .subtitle(&*self.message.borrow())
            .build();
        status.set_widget_name("software-update-status");
        let check = gtk::Button::with_label("检查更新");
        check.set_valign(gtk::Align::Center);
        let owner = self.clone();
        check.connect_clicked(move |_| owner.check(true));
        status.add_suffix(&check);
        let download = gtk::Button::with_label("前往发布页");
        download.set_valign(gtk::Align::Center);
        let owner = self.clone();
        download.connect_clicked(move |_| owner.open_release());
        status.add_suffix(&download);
        group.add(&status);
        let weak_status = status.downgrade();
        let weak_check = check.downgrade();
        self.bindings.borrow_mut().push(Box::new(move |owner| {
            let (Some(status), Some(check)) = (weak_status.upgrade(), weak_check.upgrade()) else {
                return false;
            };
            status.set_subtitle(&owner.message.borrow());
            check.set_sensitive(!owner.busy.get());
            check.set_label(if owner.busy.get() {
                "正在检查…"
            } else {
                "检查更新"
            });
            true
        }));
        self.render();
        group
    }
}

fn release_message(release: &Release) -> String {
    format!(
        "发现新版本 FarPane {}{}",
        release.tag,
        if release.preview {
            "（预览版）"
        } else {
            ""
        }
    )
}

fn preference_file() -> gio::File {
    gio::File::for_path(
        glib::user_config_dir()
            .join("farpane")
            .join("update-preferences.json"),
    )
}

fn read_preference() -> Result<bool, String> {
    use std::io::Read;
    let file = std::fs::File::open(preference_file().path().ok_or("无法读取更新设置。")?);
    let file = match file {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(true),
        Err(_) => return Err("无法读取更新设置；已暂停自动检查。".into()),
    };
    let value: serde_json::Value = serde_json::from_reader(file.take(4096))
        .map_err(|_| "更新设置无效；已暂停自动检查，请重新设置开关。")?;
    value
        .get("automatic")
        .and_then(|value| value.as_bool())
        .ok_or_else(|| "更新设置无效；已暂停自动检查，请重新设置开关。".into())
}

fn write_preference(enabled: bool) -> Result<(), String> {
    let file = preference_file();
    let directory = file
        .parent()
        .and_then(|parent| parent.path())
        .ok_or("无法保存更新设置。")?;
    std::fs::create_dir_all(directory).map_err(|_| "无法保存更新设置，请检查配置目录权限。")?;
    file.replace_contents(
        serde_json::json!({"automatic":enabled})
            .to_string()
            .as_bytes(),
        None,
        false,
        gio::FileCreateFlags::PRIVATE | gio::FileCreateFlags::REPLACE_DESTINATION,
        None::<&gio::Cancellable>,
    )
    .map(|_| ())
    .map_err(|_| "无法保存更新设置，请检查配置目录权限。".into())
}
