//! Optional user-session Secret Service. No password file/config fallback.
use farpane_protocol::{devices, Secret, ServerSettings};
use gio::prelude::*;
use glib::translate::ToGlibPtr;
use gtk::{gio, glib};
use std::{
    ffi::{CStr, CString},
    sync::atomic::{AtomicUsize, Ordering},
    thread,
    time::{Duration, Instant},
};

unsafe extern "C" {
    fn farpane_secret_execute(
        action: i32,
        peer: *const libc::c_char,
        scope: *const libc::c_char,
        password: *const libc::c_char,
        cancel: *mut gio::ffi::GCancellable,
        output: *mut *mut libc::c_char,
    ) -> i32;
    fn farpane_secret_free(value: *mut libc::c_char);
}
#[derive(Clone)]
pub struct Key {
    peer: CString,
    scope: CString,
}
impl Key {
    pub fn new(peer: &str, server: &ServerSettings) -> Result<Self, &'static str> {
        devices::validate_peer(peer)?;
        let scope = devices::scope(server)?;
        let scope = glib::compute_checksum_for_string(glib::ChecksumType::Sha256, &scope)
            .ok_or("无法计算服务器凭据范围")?;
        Ok(Self {
            peer: CString::new(peer).map_err(|_| "无效设备 ID")?,
            scope: CString::new(scope.as_str()).unwrap(),
        })
    }
}
// Clear the bounded GUI-held pending copy when discarded. The IPC protocol has
// its own temporary serialization buffers; this is not a claim of total RAM erasure.
pub struct Pending(Vec<u8>);
impl Pending {
    pub fn new(text: &str) -> Result<Self, &'static str> {
        if text.is_empty() || text.len() > 4096 || text.contains('\0') {
            return Err("密码长度必须为 1–4096 字节");
        }
        let mut bytes = text.as_bytes().to_vec();
        bytes.push(0);
        Ok(Self(bytes))
    }
    pub fn value(&self) -> Secret {
        Secret(
            std::str::from_utf8(&self.0[..self.0.len() - 1])
                .unwrap()
                .into(),
        )
    }
}
impl Drop for Pending {
    fn drop(&mut self) {
        for byte in &mut self.0 {
            unsafe { std::ptr::write_volatile(byte, 0) };
        }
    }
}
pub enum Action {
    Lookup,
    Store(Pending),
    Delete,
}
pub enum Outcome {
    Password(Option<Pending>),
    Stored,
    Deleted,
}
pub type ResultValue = Result<Outcome, &'static str>;
static ACTIVE: AtomicUsize = AtomicUsize::new(0);
struct Active;
impl Drop for Active {
    fn drop(&mut self) {
        ACTIVE.fetch_sub(1, Ordering::AcqRel);
    }
}
pub struct Operation {
    worker: Option<thread::JoinHandle<ResultValue>>,
    cancel: gio::Cancellable,
    began: Instant,
}
impl Operation {
    pub fn start(key: Key, action: Action) -> Result<Self, &'static str> {
        if unsafe { libc::geteuid() } == 0
            || unsafe { libc::getuid() != libc::geteuid() }
            || std::env::var("XDG_SESSION_CLASS")
                .is_ok_and(|v| !matches!(v.as_str(), "user" | "user-early"))
            || std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_none()
        {
            return Err("当前登录环境没有可用的用户密码库，可手动输入继续连接");
        }
        ACTIVE
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < 2).then_some(n + 1)
            })
            .map_err(|_| "密码库正在处理其他操作，请稍后重试")?;
        let cancel = gio::Cancellable::new();
        let worker_cancel = cancel.clone();
        let active = Active;
        let worker = thread::Builder::new()
            .name("farpane-secrets".into())
            .spawn(move || {
                let _active = active;
                let (number, password) = match &action {
                    Action::Lookup => (0, std::ptr::null()),
                    Action::Store(p) => (1, p.0.as_ptr().cast()),
                    Action::Delete => (2, std::ptr::null()),
                };
                let mut output = std::ptr::null_mut();
                let code = unsafe {
                    farpane_secret_execute(
                        number,
                        key.peer.as_ptr(),
                        key.scope.as_ptr(),
                        password,
                        worker_cancel.to_glib_none().0,
                        &mut output,
                    )
                };
                let value = if output.is_null() {
                    None
                } else {
                    let value = unsafe { CStr::from_ptr(output) }
                        .to_str()
                        .ok()
                        .and_then(|s| Pending::new(s).ok());
                    unsafe { farpane_secret_free(output) };
                    value
                };
                match code {
                    0 => match action {
                        Action::Lookup => value
                            .map(|v| Outcome::Password(Some(v)))
                            .ok_or("密码库返回了无效凭据"),
                        Action::Store(_) => Ok(Outcome::Stored),
                        Action::Delete => Ok(Outcome::Deleted),
                    },
                    1 => Ok(Outcome::Password(None)),
                    2 => Err("密码库被锁定；请先在系统密码管理器中解锁，或手动输入继续连接"),
                    3 => Err("系统密码库不可用；可手动输入继续连接"),
                    4 => Err("已取消密码库操作；没有确认保存或删除成功"),
                    6 => Err("此设备的密码库记录无效或有多条冲突记录"),
                    7 => {
                        Err("系统密码库没有默认存储；请先在系统密码管理器中创建并解锁，或手动输入")
                    }
                    _ => Err("密码库操作未成功；原连接不受影响"),
                }
            })
            .map_err(|_| "无法启动密码库工作线程")?;
        Ok(Self {
            worker: Some(worker),
            cancel,
            began: Instant::now(),
        })
    }
    pub fn cancel(&self) {
        self.cancel.cancel();
    }
    pub fn poll(&mut self) -> Option<ResultValue> {
        if self.began.elapsed() > Duration::from_secs(60) {
            self.cancel.cancel();
        }
        if !self.worker.as_ref()?.is_finished() {
            return None;
        }
        Some(
            self.worker
                .take()
                .unwrap()
                .join()
                .unwrap_or(Err("密码库工作线程已结束")),
        )
    }
}
impl Drop for Operation {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

/// One explicit settings action. A transient dialog exposes cancellation even
/// when the action originates in an editor without a ToastOverlay ancestor.
pub fn interact(
    parent: &impl glib::object::IsA<gtk::Widget>,
    key: Key,
    action: Action,
    finish: impl FnOnce(ResultValue) + 'static,
) {
    use adw::prelude::*;
    let Some(window) = parent.root().and_downcast::<gtk::Window>() else {
        finish(Err("原窗口已关闭，密码库操作未开始"));
        return;
    };
    let operation = match Operation::start(key, action) {
        Ok(o) => o,
        Err(e) => {
            finish(Err(e));
            return;
        }
    };
    let operation = std::rc::Rc::new(std::cell::RefCell::new(operation));
    let dialog = adw::MessageDialog::new(
        Some(&window),
        Some("正在处理系统密码库…"),
        Some("系统可能要求解锁密码库。可取消操作，稍后重试。"),
    );
    dialog.add_response("cancel", "取消");
    dialog.set_close_response("cancel");
    dialog.set_destroy_with_parent(true);
    let weak = std::rc::Rc::downgrade(&operation);
    dialog.connect_response(None, move |_, _| {
        if let Some(o) = weak.upgrade() {
            o.borrow().cancel();
        }
    });
    dialog.present();
    let window = window.downgrade();
    let mut finish = Some(finish);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        if !window.upgrade().is_some_and(|w| w.is_visible()) {
            operation.borrow().cancel();
        }
        let result = operation.borrow_mut().poll();
        if let Some(result) = result {
            dialog.close();
            finish.take().unwrap()(result);
            glib::ControlFlow::Break
        } else {
            glib::ControlFlow::Continue
        }
    });
}
