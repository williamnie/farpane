//! Deliberately structured diagnostics: never copy protocol/credential payloads,
//! peer IDs, hostnames, display names, paths or arbitrary backend error strings.
use adw::prelude::*;
use farpane_protocol::EventKind;
use gtk::{gio, glib};
use serde::Serialize;
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    rc::Rc,
    sync::{
        atomic::{AtomicU64, AtomicU8, Ordering},
        mpsc::{self, SyncSender},
        Arc, OnceLock,
    },
    time::{Duration, Instant},
};
const LIMIT: usize = 1024 * 1024;
const FILE_LIMIT: u64 = 512 * 1024;
const HEADER: &[u8] = b"# FarPane native session log v1\n";
#[derive(Clone, Serialize)]
struct Entry {
    elapsed_ms: u64,
    message: String,
}
#[derive(Default)]
struct Store {
    entries: VecDeque<Entry>,
    bytes: usize,
    discarded: u64,
}
impl Store {
    fn push(&mut self, entry: Entry) {
        self.bytes += entry.message.len() + 64;
        self.entries.push_back(entry);
        while self.entries.len() > 2000 || self.bytes > LIMIT {
            if let Some(old) = self.entries.pop_front() {
                self.bytes -= old.message.len() + 64;
                self.discarded = self.discarded.saturating_add(1);
            }
        }
    }
}
fn summary(event: &EventKind) -> Option<String> {
    Some(match event {
        EventKind::ConnectionEnded { retryable } => format!("连接结束，核心允许重试={retryable}"),
        EventKind::Phase { phase, .. } => format!("会话状态：{phase:?}"),
        EventKind::Peer { .. } => "收到已认证设备信息（身份已隐藏）".into(),
        EventKind::AuthenticationChallenge {
            two_factor,
            insecure,
            ..
        } => format!("认证请求：验证码={two_factor}，需确认未加密连接={insecure}"),
        EventKind::Reply { error: Some(_), .. } => "操作被后台拒绝（原文已隐藏）".into(),
        EventKind::Permissions(p) => format!(
            "权限：键鼠={}，剪贴板={}，音频={}，文件={}",
            p.keyboard, p.clipboard, p.audio, p.file
        ),
        EventKind::Media { backend, .. } => format!(
            "媒体后端：{}",
            if backend == "vaapi" {
                "VAAPI"
            } else if backend == "software" {
                "软件兼容"
            } else {
                "未知"
            }
        ),
        EventKind::Displays { displays, selected } => {
            format!("显示器目录：{} 项，选择序号 {selected}", displays.len())
        }
        EventKind::Audio { dropped, .. } => format!("音频状态更新，累计丢弃 {dropped}"),
        EventKind::Log { .. } => "后台附加诊断事件（原文已隐藏）".into(),
        EventKind::ResyncRequired => "后台要求重新同步状态".into(),
        _ => return None,
    })
}
fn owned_file(path: &Path, create: bool) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .append(true)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let m = file.metadata()?;
    if !m.is_file()
        || m.uid() != unsafe { libc::geteuid() }
        || m.mode() & 0o077 != 0
        || m.nlink() != 1
    {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(file)
}
fn recognized(file: &File) -> io::Result<bool> {
    if file.metadata()?.len() == 0 {
        return Ok(true);
    }
    let mut header = vec![0; HEADER.len()];
    use std::os::unix::fs::FileExt;
    Ok(file.read_at(&mut header, 0)? == HEADER.len() && header == HEADER)
}
struct Rolling {
    directory: PathBuf,
    file: File,
    _lock: File,
}
impl Rolling {
    fn open(directory: &Path) -> io::Result<Self> {
        let lock = owned_file(&directory.join("viewer.lock"), true)?;
        use std::os::fd::AsRawFd;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let mut file = owned_file(&directory.join("viewer.log"), true)?;
        if !recognized(&file)? {
            return Err(io::ErrorKind::InvalidData.into());
        }
        if file.metadata()?.len() == 0 {
            file.write_all(HEADER)?;
        }
        Ok(Self {
            directory: directory.into(),
            file,
            _lock: lock,
        })
    }
    fn append(&mut self, line: &[u8]) -> io::Result<()> {
        if line.len() > 4096 {
            return Err(io::ErrorKind::InvalidData.into());
        }
        if self.file.metadata()?.len() + line.len() as u64 > FILE_LIMIT {
            let backup = self.directory.join("viewer.log.1");
            if backup.symlink_metadata().is_ok() && !recognized(&owned_file(&backup, false)?)? {
                return Err(io::ErrorKind::InvalidData.into());
            }
            fs::rename(self.directory.join("viewer.log"), backup)?;
            self.file = owned_file(&self.directory.join("viewer.log"), true)?;
            if !recognized(&self.file)? {
                return Err(io::ErrorKind::InvalidData.into());
            }
            self.file.write_all(HEADER)?;
        }
        self.file.write_all(line)
    }
}
struct Disk {
    tx: SyncSender<Vec<u8>>,
    status: Arc<AtomicU8>,
    dropped: AtomicU64,
}
static DISK: OnceLock<Disk> = OnceLock::new();
fn disk() -> &'static Disk {
    DISK.get_or_init(|| {
        let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(64);
        let status = Arc::new(AtomicU8::new(0));
        let state = status.clone();
        if std::thread::Builder::new()
            .name("farpane-log".into())
            .stack_size(128 * 1024)
            .spawn(move || {
                let result = (|| -> io::Result<()> {
                    let root = std::env::var_os("XDG_STATE_HOME")
                        .map(PathBuf::from)
                        .filter(|p| p.is_absolute())
                        .or_else(|| {
                            std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".local/state"))
                        })
                        .ok_or(io::ErrorKind::NotFound)?;
                    fs::create_dir_all(&root)?;
                    let mut directory = root;
                    for component in ["farpane", "native"] {
                        directory.push(component);
                        if let Err(e) = fs::DirBuilder::new().mode(0o700).create(&directory) {
                            if e.kind() != io::ErrorKind::AlreadyExists {
                                return Err(e);
                            }
                        }
                        let m = directory.symlink_metadata()?;
                        if !m.is_dir()
                            || m.uid() != unsafe { libc::geteuid() }
                            || m.mode() & 0o022 != 0
                        {
                            return Err(io::ErrorKind::PermissionDenied.into());
                        }
                    }
                    let mut writer = Rolling::open(&directory)?;
                    state.store(1, Ordering::Release);
                    while let Ok(line) = rx.recv() {
                        writer.append(&line)?;
                    }
                    Ok(())
                })();
                if result.is_err() {
                    state.store(2, Ordering::Release);
                }
            })
            .is_err()
        {
            status.store(2, Ordering::Release);
        }
        Disk {
            tx,
            status,
            dropped: AtomicU64::new(0),
        }
    })
}

pub struct Log {
    started: Instant,
    store: RefCell<Store>,
    version: Cell<u64>,
    rendered: Cell<u64>,
    refreshed: Cell<Instant>,
    window: RefCell<glib::WeakRef<adw::Window>>,
    text: RefCell<glib::WeakRef<gtk::TextView>>,
    note: RefCell<glib::WeakRef<gtk::Label>>,
    performance: RefCell<crate::viewer_hud::Snapshot>,
    performance_at: Cell<Option<Instant>>,
    exporting: Cell<bool>,
    export_result: Cell<Option<bool>>,
}
impl Log {
    pub fn new() -> Rc<Self> {
        let log = Rc::new(Self {
            started: Instant::now(),
            store: Default::default(),
            version: Cell::new(0),
            rendered: Cell::new(u64::MAX),
            refreshed: Cell::new(Instant::now()),
            window: Default::default(),
            text: Default::default(),
            note: Default::default(),
            performance: Default::default(),
            performance_at: Cell::new(None),
            exporting: Cell::new(false),
            export_result: Cell::new(None),
        });
        log.mark("开始新的 Viewer 会话");
        log
    }
    pub fn mark(&self, message: &'static str) {
        self.push(message.into());
    }
    pub fn record(&self, event: &EventKind) {
        if let Some(message) = summary(event) {
            self.push(message);
        }
    }
    fn push(&self, message: String) {
        let entry = Entry {
            elapsed_ms: self.started.elapsed().as_millis() as u64,
            message,
        };
        if let Ok(mut bytes) = serde_json::to_vec(&entry) {
            bytes.push(b'\n');
            let d = disk();
            if d.tx.try_send(bytes).is_err() {
                d.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
        self.store.borrow_mut().push(entry);
        self.version.set(self.version.get().wrapping_add(1));
    }
    pub fn tick(&self, hud: &crate::viewer_hud::Hud) {
        if self.refreshed.get().elapsed() < Duration::from_secs(1) {
            return;
        }
        self.refreshed.set(Instant::now());
        if hud.enabled() {
            if let Some(at) = hud.sampled_at() {
                *self.performance.borrow_mut() = hud.snapshot();
                self.performance_at.set(Some(at));
            }
        }
        if self.version.get() != self.rendered.get() {
            if let Some(text) = self.text.borrow().upgrade() {
                let lines = self
                    .store
                    .borrow()
                    .entries
                    .iter()
                    .map(|e| format!("{:>8.3}s  {}", e.elapsed_ms as f64 / 1000., e.message))
                    .collect::<Vec<_>>()
                    .join("\n");
                text.buffer().set_text(&lines);
                self.rendered.set(self.version.get());
            }
        }
        if !self.exporting.get() && self.export_result.get().is_none() {
            if let Some(note) = self.note.borrow().upgrade() {
                let d = disk();
                note.set_text(match d.status.load(Ordering::Acquire) {
                    1 => "本地日志按 512 KiB 轮转，最多保留两份。导出会隐藏设备身份、密码、路径和内容。",
                    2 => "本地日志不可用；会话继续运行，仍可导出当前窗口中的脱敏诊断。",
                    _ => "正在准备本地诊断日志…",
                });
            }
        }
    }
    pub fn button(self: &Rc<Self>) -> gtk::Button {
        let button = gtk::Button::with_label("诊断");
        button.set_widget_name("viewer-diagnostics");
        let weak = Rc::downgrade(self);
        button.connect_clicked(move |button| {
            if let (Some(log), Some(window)) =
                (weak.upgrade(), button.root().and_downcast::<gtk::Window>())
            {
                log.present(&window);
            }
        });
        button
    }
    fn bytes(&self) -> Vec<u8> {
        let store = self.store.borrow();
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema": 1,
            "product": "FarPane",
            "component": "native-viewer",
            "version": env!("CARGO_PKG_VERSION"),
            "elapsed_ms": self.started.elapsed().as_millis(),
            "redaction": "allowlisted events; no peer/server identities, credentials, paths, input, clipboard or file contents",
            "resource_scope": "GUI and this Viewer only; excludes Host, other workers and dedicated GPU memory",
            "log_entries": store.entries,
            "discarded_entries": store.discarded,
            "disk_dropped": disk().dropped.load(Ordering::Relaxed),
            "performance_age_ms": self.performance_at.get().map(|at| at.elapsed().as_millis() as u64),
            "performance": *self.performance.borrow(),
        }))
        .unwrap_or_default()
    }
    fn present(self: &Rc<Self>, parent: &gtk::Window) {
        if let Some(window) = self.window.borrow().upgrade() {
            window.present();
            return;
        }
        self.export_result.set(None);
        let window = adw::Window::builder()
            .title("FarPane · 会话诊断")
            .default_width(720)
            .default_height(520)
            .transient_for(parent)
            .destroy_with_parent(true)
            .build();
        let body = gtk::Box::new(gtk::Orientation::Vertical, 8);
        body.append(&adw::HeaderBar::new());
        let help = gtk::Label::new(Some(
            "这里只记录状态和性能，不记录密码、输入内容或文件内容。开启 HUD 可采集性能数据。",
        ));
        help.set_wrap(true);
        help.set_margin_start(12);
        help.set_margin_end(12);
        body.append(&help);
        let text = gtk::TextView::builder()
            .editable(false)
            .cursor_visible(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .left_margin(12)
            .right_margin(12)
            .build();
        text.set_widget_name("viewer-diagnostic-events");
        let scroll = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&text)
            .build();
        body.append(&scroll);
        let note = gtk::Label::new(None);
        note.set_widget_name("viewer-diagnostic-status");
        note.set_wrap(true);
        body.append(&note);
        let export = gtk::Button::with_label("导出脱敏诊断…");
        export.set_widget_name("viewer-diagnostic-export");
        export.set_halign(gtk::Align::End);
        export.set_margin_end(12);
        export.set_margin_bottom(12);
        body.append(&export);
        let weak = Rc::downgrade(self);
        let parent = window.downgrade();
        export.connect_clicked(move |_| {
            if let (Some(log), Some(parent)) = (weak.upgrade(), parent.upgrade()) {
                if log.exporting.replace(true) {
                    return;
                }
                let weak = Rc::downgrade(&log);
                let chooser = gtk::FileDialog::builder()
                    .title("保存 FarPane 诊断")
                    .initial_name("FarPane-diagnostics.json")
                    .build();
                chooser.save(Some(&parent), None::<&gio::Cancellable>, move |result| {
                    if let Some(log) = weak.upgrade() {
                        match result {
                            Ok(file) => log.export(&file),
                            Err(_) => log.exporting.set(false),
                        }
                    }
                });
            }
        });
        window.set_content(Some(&body));
        *self.window.borrow_mut() = window.downgrade();
        *self.text.borrow_mut() = text.downgrade();
        *self.note.borrow_mut() = note.downgrade();
        self.rendered.set(u64::MAX);
        window.present();
    }
    pub(crate) fn export(self: &Rc<Self>, file: &gio::File) {
        if file.path().is_none() {
            self.exporting.set(false);
            self.export_result.set(Some(false));
            if let Some(note) = self.note.borrow().upgrade() {
                note.set_text("请选择本机文件位置");
            }
            return;
        }
        self.exporting.set(true);
        self.export_result.set(None);
        let weak = Rc::downgrade(self);
        file.replace_contents_async(
            self.bytes(),
            None,
            false,
            gio::FileCreateFlags::PRIVATE | gio::FileCreateFlags::REPLACE_DESTINATION,
            None::<&gio::Cancellable>,
            move |result| {
                if let Some(log) = weak.upgrade() {
                    log.exporting.set(false);
                    log.export_result.set(Some(result.is_ok()));
                    if let Some(note) = log.note.borrow().upgrade() {
                        note.set_text(if result.is_ok() {
                            "已保存脱敏诊断"
                        } else {
                            "保存失败；连接保持不变，请重试其他位置"
                        });
                    }
                }
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn event_summaries_never_copy_sensitive_payloads() {
        let secret = "sensitive-password /home/private 192.0.2.7 clipboard";
        for event in [
            EventKind::Peer {
                name: secret.into(),
            },
            EventKind::Phase {
                phase: farpane_protocol::Phase::Failed,
                detail: secret.into(),
            },
            EventKind::Reply {
                request: 1,
                revision: 0,
                error: Some(secret.into()),
            },
            EventKind::Media {
                backend: secret.into(),
                detail: secret.into(),
            },
            EventKind::Log {
                level: secret.into(),
                message: secret.into(),
            },
        ] {
            let s = summary(&event).unwrap();
            assert!(!s.contains(secret));
            assert!(!s.contains("192.0.2.7"));
        }
        let mut store = Store::default();
        for _ in 0..3000 {
            store.push(Entry {
                elapsed_ms: 0,
                message: "x".repeat(600),
            });
        }
        assert!(store.bytes <= LIMIT && store.entries.len() <= 2000 && store.discarded > 0);
    }
    #[test]
    fn disk_rotation_is_bounded_and_preserves_unknown_and_symlink_targets() {
        let directory = std::env::temp_dir().join(format!(
            "farpane-log-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        {
            let mut rolling = Rolling::open(&directory).unwrap();
            assert!(Rolling::open(&directory).is_err());
            for _ in 0..1300 {
                rolling.append(&vec![b'x'; 1024]).unwrap();
            }
            assert!(rolling.file.metadata().unwrap().len() <= FILE_LIMIT);
            assert!(directory.join("viewer.log.1").metadata().unwrap().len() <= FILE_LIMIT);
        }
        let known = fs::read(directory.join("viewer.log")).unwrap();
        fs::write(directory.join("viewer.log.1"), "unrecognized").unwrap();
        {
            let mut rolling = Rolling::open(&directory).unwrap();
            while rolling.file.metadata().unwrap().len() + 1024 <= FILE_LIMIT {
                rolling.append(&vec![b'x'; 1024]).unwrap();
            }
            assert!(rolling.append(&vec![b'x'; 1024]).is_err());
        }
        assert_eq!(
            fs::read_to_string(directory.join("viewer.log.1")).unwrap(),
            "unrecognized"
        );
        fs::remove_file(directory.join("viewer.log")).unwrap();
        std::os::unix::fs::symlink(directory.join("viewer.log.1"), directory.join("viewer.log"))
            .unwrap();
        assert!(Rolling::open(&directory).is_err());
        assert!(!known.is_empty());
        fs::remove_dir_all(directory).unwrap();
    }
}
