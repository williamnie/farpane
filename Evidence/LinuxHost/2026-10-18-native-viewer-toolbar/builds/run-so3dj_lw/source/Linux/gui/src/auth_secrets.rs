//! Reused by media and file authentication. Only explicit user actions access
//! Secret Service; a password is stored only after the core authenticates it.
use crate::credentials::{Action, Key, Operation, Outcome, Pending};
use adw::prelude::*;
use gtk::glib;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

/// Keep malformed local input editable. The core applies the same bounds
/// before consuming its pending challenge; the remote Host checks the value.
pub fn valid_two_factor(text: &str) -> bool {
    !text.is_empty() && text.len() <= 16 && text.bytes().all(|byte| byte.is_ascii_digit())
}

pub const TWO_FACTOR_FORMAT_ERROR: &str = "验证码须为数字，最多 16 位，请修改后重试";

struct Active {
    operation: Operation,
    lookup: bool,
    epoch: u64,
}
pub struct Controls {
    pub root: gtk::Box,
    pub save: gtk::CheckButton,
    pub load: gtk::Button,
    pub forget: gtk::Button,
    pub cancel: gtk::Button,
    pub note: gtk::Label,
    entry: glib::WeakRef<gtk::PasswordEntry>,
    key: Result<Key, &'static str>,
    active: RefCell<Option<Active>>,
    pending: RefCell<Option<Pending>>,
    epoch: Cell<u64>,
    password_challenge: Cell<bool>,
    authenticated: Cell<bool>,
    toast: RefCell<Option<adw::Toast>>,
}
impl Controls {
    pub fn new(entry: &gtk::PasswordEntry, key: Result<Key, &'static str>) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let save = gtk::CheckButton::with_label("验证成功后保存到系统密码库");
        let load = gtk::Button::with_label("使用已保存密码");
        let forget = gtk::Button::with_label("忘记已保存密码");
        let cancel = gtk::Button::with_label("取消密码库操作");
        save.set_widget_name("secret-save");
        load.set_widget_name("secret-load");
        forget.set_widget_name("secret-forget");
        cancel.set_widget_name("secret-cancel");
        row.append(&load);
        row.append(&forget);
        row.append(&cancel);
        root.append(&save);
        root.append(&row);
        let note = gtk::Label::new(None);
        note.set_wrap(true);
        note.set_max_width_chars(60);
        note.add_css_class("muted");
        root.append(&note);
        root.set_visible(false);
        let controls = Rc::new(Self {
            root,
            save,
            load,
            forget,
            cancel,
            note,
            entry: entry.downgrade(),
            key,
            active: RefCell::new(None),
            pending: RefCell::new(None),
            epoch: Cell::new(0),
            password_challenge: Cell::new(false),
            authenticated: Cell::new(false),
            toast: RefCell::new(None),
        });
        for (button, delete) in [(&controls.load, false), (&controls.forget, true)] {
            let weak = Rc::downgrade(&controls);
            button.connect_clicked(move |_| {
                if let Some(c) = weak.upgrade() {
                    if delete {
                        c.confirm_delete();
                    } else {
                        c.start(Action::Lookup);
                    }
                }
            });
        }
        let weak = Rc::downgrade(&controls);
        controls.cancel.connect_clicked(move |_| {
            if let Some(c) = weak.upgrade() {
                c.cancel();
            }
        });
        controls.refresh();
        controls
    }
    fn refresh(&self) {
        let busy = self.active.borrow().is_some();
        self.load.set_sensitive(!busy && self.key.is_ok());
        self.forget.set_sensitive(!busy && self.key.is_ok());
        self.save.set_sensitive(self.key.is_ok());
        self.cancel.set_visible(busy);
    }
    fn notice(self: &Rc<Self>, message: &str, cancellable: bool) {
        self.note.set_text(message);
        if let Some(toast) = self.toast.borrow_mut().take() {
            toast.dismiss();
        }
        if let Some(overlay) = self
            .entry
            .upgrade()
            .and_then(|e| e.ancestor(adw::ToastOverlay::static_type()))
            .and_then(|w| w.downcast::<adw::ToastOverlay>().ok())
        {
            let toast = adw::Toast::new(message);
            if cancellable {
                toast.set_timeout(0);
                toast.set_button_label(Some("取消"));
                let weak = Rc::downgrade(self);
                toast.connect_button_clicked(move |_| {
                    if let Some(c) = weak.upgrade() {
                        c.cancel();
                    }
                });
            }
            overlay.add_toast(toast.clone());
            *self.toast.borrow_mut() = Some(toast);
        }
    }
    fn start(self: &Rc<Self>, action: Action) {
        if self.active.borrow().is_some() {
            self.notice("密码库正在处理操作，请先取消或等待完成", false);
            return;
        }
        let lookup = matches!(action, Action::Lookup);
        let message = match &action {
            Action::Lookup => "正在读取系统密码库…",
            Action::Store(_) => "正在保存到系统密码库…",
            Action::Delete => "正在删除已保存密码…",
        };
        let result = self
            .key
            .clone()
            .and_then(|key| Operation::start(key, action));
        match result {
            Ok(operation) => {
                *self.active.borrow_mut() = Some(Active {
                    operation,
                    lookup,
                    epoch: self.epoch.get(),
                });
                self.notice(message, true);
            }
            Err(error) => self.notice(error, false),
        }
        self.refresh();
    }
    fn confirm_delete(self: &Rc<Self>) {
        let Some(window) = self
            .entry
            .upgrade()
            .and_then(|e| e.root().and_downcast::<gtk::Window>())
        else {
            return;
        };
        let dialog = adw::MessageDialog::new(
            Some(&window),
            Some("忘记已保存密码？"),
            Some("只删除当前设备在当前服务器范围内的密码。连接记录和远端密码不会改变。"),
        );
        dialog.add_responses(&[("cancel", "取消"), ("forget", "忘记密码")]);
        dialog.set_close_response("cancel");
        dialog.set_response_appearance("forget", adw::ResponseAppearance::Destructive);
        let weak = Rc::downgrade(self);
        dialog.connect_response(None, move |_, response| {
            if response == "forget" {
                if let Some(c) = weak.upgrade() {
                    c.start(Action::Delete);
                }
            }
        });
        dialog.present();
    }
    pub fn challenge(&self, password: bool) {
        self.authenticated.set(false);
        if password && self.password_challenge.get() {
            self.root.set_visible(true);
            return;
        }
        self.epoch.set(self.epoch.get().wrapping_add(1));
        self.password_challenge.set(password);
        self.root.set_visible(password);
        if password {
            self.pending.borrow_mut().take();
        }
        if self.active.borrow().as_ref().is_some_and(|a| a.lookup) {
            self.cancel();
        }
    }
    pub fn attempt(&self, kind: u8, text: &str) {
        self.authenticated.set(false);
        self.epoch.set(self.epoch.get().wrapping_add(1));
        self.password_challenge.set(false);
        if self.active.borrow().as_ref().is_some_and(|a| a.lookup) {
            self.cancel();
        }
        if kind == 1 {
            *self.pending.borrow_mut() = if self.save.is_active() {
                Pending::new(text).ok()
            } else {
                None
            };
        }
    }
    pub fn authenticated(self: &Rc<Self>) {
        self.authenticated.set(true);
        self.password_challenge.set(false);
        self.root.set_visible(false);
        self.store_when_ready();
    }
    fn store_when_ready(self: &Rc<Self>) {
        if !self.authenticated.get() || self.active.borrow().is_some() {
            return;
        }
        let pending = self.pending.borrow_mut().take();
        if let Some(password) = pending {
            self.start(Action::Store(password));
        }
    }
    pub fn cancel(&self) {
        if let Some(active) = self.active.borrow().as_ref() {
            active.operation.cancel();
        }
    }
    pub fn stop(&self) {
        self.authenticated.set(false);
        self.pending.borrow_mut().take();
        self.password_challenge.set(false);
        self.cancel();
    }
    pub fn poll(self: &Rc<Self>) {
        let result = {
            let mut active = self.active.borrow_mut();
            active
                .as_mut()
                .and_then(|a| a.operation.poll().map(|r| (r, a.epoch)))
        };
        let Some((result, epoch)) = result else {
            return;
        };
        self.active.borrow_mut().take();
        match result {
            Ok(Outcome::Password(Some(password))) => {
                if self.password_challenge.get() && self.epoch.get() == epoch {
                    if let Some(entry) = self.entry.upgrade() {
                        entry.set_text(&password.value().0);
                    }
                    self.notice("已从系统密码库读取，请验证并连接", false);
                }
            }
            Ok(Outcome::Password(None)) => {
                self.notice("当前设备还没有已保存密码，可手动输入", false)
            }
            Ok(Outcome::Stored) => self.notice("密码已保存到系统密码库", false),
            Ok(Outcome::Deleted) => {
                self.save.set_active(false);
                self.pending.borrow_mut().take();
                self.notice("已忘记当前设备的保存密码", false);
            }
            Err(error) => self.notice(error, false),
        }
        self.refresh();
        self.store_when_ready();
    }
}
