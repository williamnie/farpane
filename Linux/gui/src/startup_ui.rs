use adw::prelude::*;
use gtk::glib;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::mpsc,
    time::{Duration, Instant},
};

type Update = (Result<bool, String>, Option<String>);

pub struct Settings {
    busy: Cell<bool>,
    status: RefCell<Result<bool, String>>,
    error: RefCell<Option<String>>,
    last_read: Cell<Option<Instant>>,
    operation: fn(Option<bool>) -> Update,
}

impl Settings {
    pub fn new() -> Rc<Self> {
        Self::with_operation(|requested| {
            let error = requested.and_then(|enabled| crate::startup::set_enabled(enabled).err());
            // 即使授权取消/失败，也重新读取实际状态，不能把开关留在假成功的位置。
            (crate::startup::observe(), error)
        })
    }

    fn with_operation(operation: fn(Option<bool>) -> Update) -> Rc<Self> {
        Rc::new(Self {
            busy: Cell::new(false),
            status: RefCell::new(Err("正在读取系统设置…".into())),
            error: RefCell::new(None),
            last_read: Cell::new(None),
            operation,
        })
    }

    fn update(self: &Rc<Self>, requested: Option<bool>) {
        if self.busy.replace(true) {
            return;
        }
        let (send, receive) = mpsc::channel();
        let operation = self.operation;
        std::thread::spawn(move || {
            let _ = send.send(operation(requested));
        });
        let owner = self.clone();
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let result = match receive.try_recv() {
                Ok(result) => result,
                Err(mpsc::TryRecvError::Empty) => return glib::ControlFlow::Continue,
                Err(mpsc::TryRecvError::Disconnected) => {
                    (Err("读取系统设置失败，请重试。".into()), None)
                }
            };
            *owner.status.borrow_mut() = result.0;
            if requested.is_some() {
                *owner.error.borrow_mut() = result.1;
            }
            owner.last_read.set(Some(Instant::now()));
            owner.busy.set(false);
            glib::ControlFlow::Break
        });
    }

    pub fn group(self: &Rc<Self>) -> adw::PreferencesGroup {
        let group = adw::PreferencesGroup::builder()
            .title("启动")
            .description("管理重启后的自动运行；允许远程连接仍由“允许连接本机”控制。")
            .build();
        let row = adw::SwitchRow::builder()
            .title("开机自启")
            .subtitle("正在读取系统设置…")
            .sensitive(false)
            .build();
        row.set_widget_name("startup-enabled");
        group.add(&row);
        let updating = Rc::new(Cell::new(false));
        let owner = self.clone();
        let guard = updating.clone();
        row.connect_active_notify(move |row| {
            if !guard.get() && !owner.busy.get() {
                owner.update(Some(row.is_active()));
                row.set_sensitive(false);
                row.set_subtitle("正在更改系统设置；如有提示，请完成管理员授权…");
            }
        });
        let owner = self.clone();
        let weak = row.downgrade();
        group.connect_map(move |_| {
            if let Some(row) = weak.upgrade() {
                row.set_sensitive(false);
            }
            owner.update(None);
        });
        let weak = row.downgrade();
        let owner = self.clone();
        glib::timeout_add_local(Duration::from_millis(250), move || {
            let Some(row) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if owner.busy.get() {
                row.set_sensitive(false);
                return glib::ControlFlow::Continue;
            }
            updating.set(true);
            let status = owner.status.borrow();
            row.set_active(matches!(*status, Ok(true)));
            row.set_sensitive(status.is_ok());
            let message = match &*status {
                Ok(true) => "已开启：开机后自动运行 FarPane 后台服务，无需打开窗口。",
                Ok(false) => "未开启：开机后后台服务不会自动运行。开启时可能需要管理员授权。",
                Err(error) => error.as_str(),
            };
            let error = owner.error.borrow();
            row.set_subtitle(&match error.as_ref() {
                Some(error) => format!("{error}\n{message}"),
                None => message.into(),
            });
            updating.set(false);
            // 页面可见时刷新外部 systemctl 更改；不与正在进行的授权操作交叉。
            if row.is_mapped()
                && owner
                    .last_read
                    .get()
                    .is_none_or(|time| time.elapsed() >= Duration::from_secs(5))
            {
                row.set_sensitive(false);
                owner.update(None);
            }
            glib::ControlFlow::Continue
        });
        group
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst};

    static ENABLED: AtomicBool = AtomicBool::new(false);
    static DENIED: AtomicBool = AtomicBool::new(false);
    static WRITES: AtomicUsize = AtomicUsize::new(0);

    fn system(requested: Option<bool>) -> Update {
        let mut error = None;
        if let Some(enabled) = requested {
            WRITES.fetch_add(1, SeqCst);
            if DENIED.load(SeqCst) {
                error = Some("管理员拒绝授权".into());
            } else {
                ENABLED.store(enabled, SeqCst);
            }
        }
        (Ok(ENABLED.load(SeqCst)), error)
    }

    fn switch(widget: &gtk::Widget) -> Option<adw::SwitchRow> {
        if let Some(row) = widget.downcast_ref::<adw::SwitchRow>() {
            return Some(row.clone());
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            if let Some(row) = switch(&widget) {
                return Some(row);
            }
            child = widget.next_sibling();
        }
        None
    }

    fn settle(settings: &Settings) {
        let began = Instant::now();
        let context = glib::MainContext::default();
        while began.elapsed() < Duration::from_millis(700) || settings.busy.get() {
            assert!(began.elapsed() < Duration::from_secs(5));
            while context.pending() {
                context.iteration(false);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    #[ignore = "requires isolated GTK display: xvfb-run cargo test startup_ui -- --ignored"]
    fn switch_reloads_state_and_rolls_back_denied_changes_without_writing_on_refresh() {
        adw::init().expect("isolated GTK display");
        ENABLED.store(false, SeqCst);
        DENIED.store(false, SeqCst);
        WRITES.store(0, SeqCst);
        let settings = Settings::with_operation(system);
        let group = settings.group();
        let row = switch(group.upcast_ref()).expect("startup row");
        let window = gtk::Window::builder().default_width(600).build();
        window.set_child(Some(&group));
        window.present();
        settle(&settings);
        assert!(!row.is_active());
        assert!(row.is_sensitive());
        assert_eq!(WRITES.load(SeqCst), 0);

        row.set_active(true);
        assert!(!row.is_sensitive());
        settle(&settings);
        assert!(row.is_active());
        assert_eq!(WRITES.load(SeqCst), 1);
        let reopened = Settings::with_operation(system);
        reopened.update(None);
        settle(&reopened);
        assert_eq!(*reopened.status.borrow(), Ok(true));

        ENABLED.store(false, SeqCst);
        settings.update(None);
        settle(&settings);
        assert!(!row.is_active());
        assert_eq!(WRITES.load(SeqCst), 1);

        DENIED.store(true, SeqCst);
        row.set_active(true);
        settle(&settings);
        assert!(!row.is_active());
        assert!(row.is_sensitive());
        assert!(row.subtitle().unwrap().contains("拒绝"));
        assert_eq!(WRITES.load(SeqCst), 2);
        window.close();
    }
}
