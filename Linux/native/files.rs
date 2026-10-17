//! Host file workers and authenticated GUI decisions. No GTK or legacy CM FS I/O.
use base::message_proto::Message;
use farpane_protocol::FileTask;
use hbb_common::tokio::sync::mpsc::Sender;
use hbb_common::{bail, config::Config, ResultType};
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicBool, AtomicI32, Ordering},
        mpsc, Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

pub const PACKET_LIMIT: usize = 320 * 1024;
static NEXT_TASK: AtomicI32 = AtomicI32::new(1);
static TASKS: OnceLock<Mutex<BTreeMap<i32, Record>>> = OnceLock::new();
static WORKERS: OnceLock<Mutex<Vec<Arc<Worker>>>> = OnceLock::new();
struct Worker {
    connection: i32,
    epoch: String,
    stop: AtomicBool,
    done: AtomicBool,
}
fn workers() -> &'static Mutex<Vec<Arc<Worker>>> {
    WORKERS.get_or_init(Default::default)
}
// A successful acknowledgement means all selected workers have dropped their
// file owners/writers. Setting an atomic flag alone cannot prove that disk I/O
// which was already in progress has stopped.
fn stop_and_wait(select: impl Fn(&Worker) -> bool) -> ResultType<()> {
    let selected: Vec<_> = workers()
        .lock()
        .unwrap()
        .iter()
        .filter(|worker| select(worker))
        .cloned()
        .collect();
    for worker in &selected {
        worker.stop.store(true, Ordering::Release);
    }
    let began = Instant::now();
    while selected
        .iter()
        .any(|worker| !worker.done.load(Ordering::Acquire))
    {
        if began.elapsed() >= Duration::from_secs(2) {
            bail!("File access was revoked, but storage cleanup is still pending");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}
pub fn stop_connection(connection: i32) -> ResultType<()> {
    stop_and_wait(|worker| worker.connection == connection)
}
pub fn stop_outdated() -> ResultType<()> {
    // Read policy under the same registration lock in stop_and_wait/start.
    stop_and_wait(|worker| {
        !enabled() || worker.epoch != Config::get_option("farpane-files-generation")
    })
}
fn tasks() -> &'static Mutex<BTreeMap<i32, Record>> {
    TASKS.get_or_init(Default::default)
}
pub fn enabled() -> bool {
    (unsafe { hbb_common::libc::geteuid() }) != 0
        && Config::get_option("farpane-files-enabled") == "Y"
        && !Config::get_option("farpane-files-root").is_empty()
}
pub fn snapshot() -> Vec<FileTask> {
    tasks()
        .lock()
        .unwrap()
        .values()
        .map(|r| r.task.clone())
        .collect()
}
pub(super) struct Decision {
    pub choice: Mutex<Option<(bool, bool)>>,
    pub cancel: AtomicBool,
}
struct Record {
    task: FileTask,
    decision: Arc<Decision>,
    terminal: bool,
}
pub(super) fn register(mut task: FileTask, confirm: bool) -> ResultType<(i32, Arc<Decision>)> {
    let mut records = tasks().lock().unwrap();
    while records.len() >= 16 {
        if let Some(key) = records.iter().find_map(|(k, r)| r.terminal.then_some(*k)) {
            records.remove(&key);
        } else {
            bail!("Too many active file tasks");
        }
    }
    let token = NEXT_TASK
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_add(1))
        .map_err(|_| hbb_common::anyhow::anyhow!("File task ID exhausted"))?;
    task.job = token;
    task.name = task.name.chars().take(96).collect();
    task.needs_confirmation = confirm;
    task.status = if confirm {
        "awaiting_confirmation"
    } else {
        "queued"
    }
    .into();
    let decision = Arc::new(Decision {
        choice: Mutex::new(if confirm { None } else { Some((true, false)) }),
        cancel: AtomicBool::new(false),
    });
    records.insert(
        token,
        Record {
            task,
            decision: decision.clone(),
            terminal: false,
        },
    );
    super::control::changed();
    Ok((token, decision))
}
pub fn decide(token: i32, accept: bool, overwrite: bool) -> ResultType<()> {
    let mut records = tasks().lock().unwrap();
    let record = records
        .get_mut(&token)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("File task expired"))?;
    if !record.task.needs_confirmation || record.terminal {
        bail!("No file decision is pending");
    }
    if accept && record.task.overwrite_required && !overwrite {
        bail!("Explicit permission to replace existing files is required");
    }
    *record.decision.choice.lock().unwrap() = Some((accept, overwrite));
    record.task.needs_confirmation = false;
    record.task.status = "confirming".into();
    super::control::changed();
    Ok(())
}
pub fn cancel(token: i32) -> ResultType<()> {
    let records = tasks().lock().unwrap();
    let record = records
        .get(&token)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("File task expired"))?;
    if record.terminal {
        bail!("File task already ended");
    }
    record.decision.cancel.store(true, Ordering::Release);
    Ok(())
}
pub(super) fn update(token: i32, done: u64, status: &str, detail: &str, terminal: bool) {
    if let Some(record) = tasks().lock().unwrap().get_mut(&token) {
        record.task.done = done;
        record.task.status = status.into();
        record.task.detail = detail.chars().take(128).collect();
        record.task.needs_confirmation = false;
        record.terminal = terminal;
    }
    super::control::changed();
}
pub(super) fn total(token: i32, total: u64) {
    if let Some(record) = tasks().lock().unwrap().get_mut(&token) {
        record.task.total = total;
    }
}
pub struct Link {
    sender: mpsc::SyncSender<Message>,
    worker: Arc<Worker>,
    epoch: String,
}
impl Link {
    pub fn start(connection: i32, output: Sender<Message>) -> ResultType<Self> {
        let mut registered = workers().lock().unwrap();
        registered.retain(|worker| !worker.done.load(Ordering::Acquire));
        if !enabled() {
            bail!("Choose and enable a shared folder first");
        }
        if registered.len() >= 4 {
            bail!("Too many file connections");
        }
        let epoch = Config::get_option("farpane-files-generation");
        let root = Config::get_option("farpane-files-root");
        let confirm = Config::get_option("farpane-files-confirm") != "N";
        let (sender, receiver) = mpsc::sync_channel(8);
        let worker = Arc::new(Worker {
            connection,
            epoch: epoch.clone(),
            stop: AtomicBool::new(false),
            done: AtomicBool::new(false),
        });
        let stopping = worker.clone();
        let expected = epoch.clone();
        let result = std::thread::Builder::new()
            .name("native-files".into())
            .spawn(move || {
                struct Completed(Arc<Worker>);
                impl Drop for Completed {
                    fn drop(&mut self) {
                        self.0.stop.store(true, Ordering::Release);
                        self.0.done.store(true, Ordering::Release);
                    }
                }
                let _completed = Completed(stopping.clone());
                let _activity = super::activity::Guard::files();
                let valid = || {
                    !stopping.stop.load(Ordering::Acquire)
                        && enabled()
                        && Config::get_option("farpane-files-generation") == expected
                };
                let send = |mut message: Message| -> ResultType<()> {
                    let began = Instant::now();
                    loop {
                        if !valid() {
                            bail!("File connection was revoked");
                        }
                        match output.try_send(message) {
                            Ok(_) => return Ok(()),
                            Err(hbb_common::tokio::sync::mpsc::error::TrySendError::Full(
                                value,
                            )) => message = value,
                            Err(_) => bail!("File network connection ended"),
                        }
                        if began.elapsed() >= Duration::from_secs(2) {
                            bail!("File network queue stalled");
                        }
                        std::thread::sleep(Duration::from_millis(5));
                    }
                };
                let result =
                    super::file_host::run(connection, &root, confirm, receiver, &valid, &send);
                if let Err(error) = result {
                    hbb_common::log::debug!("Native file connection ended: {error}");
                }
            });
        if let Err(error) = result {
            return Err(error.into());
        }
        registered.push(worker.clone());
        Ok(Self {
            sender,
            worker,
            epoch,
        })
    }
    pub fn valid(&self) -> bool {
        !self.worker.stop.load(Ordering::Acquire)
            && enabled()
            && Config::get_option("farpane-files-generation") == self.epoch
    }
    pub async fn submit(&self, mut message: Message) -> ResultType<()> {
        let began = Instant::now();
        loop {
            if !self.valid() {
                bail!("File permission was revoked");
            }
            match self.sender.try_send(message) {
                Ok(_) => return Ok(()),
                Err(mpsc::TrySendError::Full(value)) => message = value,
                Err(_) => bail!("File worker ended"),
            }
            if began.elapsed() >= Duration::from_secs(2) {
                bail!("File storage queue stalled");
            }
            hbb_common::tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }
}
impl Drop for Link {
    fn drop(&mut self) {
        self.worker.stop.store(true, Ordering::Release);
    }
}
