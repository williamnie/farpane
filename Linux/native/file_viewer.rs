//! File-only Viewer: bounded wire queue and filesystem I/O on its own thread.
use super::{viewer::State, viewer_ui::NativeUi};
use crate::ui_session_interface::Session;
use base::{fs, message_proto::*};
use farpane_files::{
    batch::Incoming, outgoing::Plan, Entry, Reader, Root, Writer, BLOCK_BYTES, PAGE_BYTES,
    PAGE_ENTRIES,
};
use farpane_protocol::{Command, EventKind};
use hbb_common::{bail, protobuf::Message as _, ResultType};
use std::{
    collections::{BTreeMap, VecDeque},
    path::{Path, PathBuf},
    sync::{atomic::Ordering, mpsc, Arc},
    task::Poll,
    time::{Duration, Instant},
};

enum Work {
    Wire(Message),
    User(Command),
}
pub struct Link {
    sender: mpsc::SyncSender<Work>,
    worker: std::thread::JoinHandle<()>,
}
impl Link {
    pub fn start(state: Arc<State>, session: Session<NativeUi>) -> ResultType<Self> {
        let (sender, receiver) = mpsc::sync_channel(8);
        let worker = std::thread::Builder::new()
            .name("viewer-files".into())
            .spawn(move || {
                let mut client = Client {
                    state: state.clone(),
                    session,
                    jobs: BTreeMap::new(),
                    next: 0,
                    listing: None,
                    retired: VecDeque::new(),
                    upload_batches: false,
                    download_batches: false,
                };
                let result = (|| -> ResultType<()> {
                    while !state.stopped.load(Ordering::Acquire) {
                        if state.authenticated.load(Ordering::Acquire)
                            && !state.permissions.lock().unwrap().file
                        {
                            bail!("File permission was revoked");
                        }
                        let busy = client.advance()?;
                        match receiver.recv_timeout(if busy {
                            Duration::ZERO
                        } else {
                            Duration::from_millis(20)
                        }) {
                            Ok(Work::User(command)) => {
                                let confirmed = match &command {
                                    Command::ConfirmTransfer { job, .. } => Some(*job),
                                    _ => None,
                                };
                                let before = confirmed
                                    .and_then(|id| client.jobs.get(&id))
                                    .map(|j| (j.name.clone(), j.done, j.total));
                                if let Err(error) = client.command(command) {
                                    if let Some(id) = confirmed {
                                        client.fail_job(id, &error.to_string(), before)?;
                                        continue;
                                    }
                                    state.emit(EventKind::Log {
                                        level: "error".into(),
                                        message: error.to_string(),
                                    });
                                }
                            }
                            Ok(Work::Wire(message)) => client.wire(message)?,
                            Err(mpsc::RecvTimeoutError::Timeout) => {}
                            Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        }
                    }
                    Ok(())
                })();
                if let Err(error) = result {
                    state.fail(&format!("文件连接失败：{error}"));
                }
                for (id, job) in &client.jobs {
                    client.report(*id, job, "cancelled", false);
                }
            })?;
        Ok(Self { sender, worker })
    }
    pub fn finish(self) {
        drop(self.sender);
        // This runs only on the disposable core's control thread, after stop.
        // Normal exit waits for staging-file cleanup; the GUI separately owns
        // the bounded shutdown/kill deadline for a wedged process.
        let _ = self.worker.join();
    }
    pub fn command(&self, command: Command) -> ResultType<()> {
        self.sender
            .try_send(Work::User(command))
            .map_err(|_| hbb_common::anyhow::anyhow!("File control queue is busy"))
    }
}
pub async fn enqueue(mut message: Message) -> bool {
    let Some(state) = super::viewer::CURRENT.get() else {
        return false;
    };
    if !state.file_only.load(Ordering::Acquire)
        || !state.authenticated.load(Ordering::Acquire)
        || message.compute_size() as usize > super::files::PACKET_LIMIT
    {
        return false;
    }
    let sender = state
        .files
        .lock()
        .unwrap()
        .as_ref()
        .map(|f| f.sender.clone());
    let Some(sender) = sender else {
        return false;
    };
    let began = Instant::now();
    loop {
        if state.stopped.load(Ordering::Acquire) {
            return false;
        }
        match sender.try_send(Work::Wire(message)) {
            Ok(_) => return true,
            Err(mpsc::TrySendError::Full(Work::Wire(value))) => message = value,
            Err(_) => return false,
        }
        if began.elapsed() > Duration::from_secs(2) {
            state.fail("文件接收队列停止响应");
            return false;
        }
        hbb_common::tokio::time::sleep(Duration::from_millis(5)).await;
    }
}
struct Upload {
    plan: Plan,
    destination: String,
    entries: Vec<Entry>,
    reader: Option<Reader>,
    index: usize,
    preparing: bool,
    more: bool,
    page: u32,
    skipped: u64,
    ready: bool,
    awaiting_ack: bool,
}
struct Download {
    root: Root,
    name: String,
    writer: Option<Writer>,
    size: Option<u64>,
    overwrite: bool,
    pending: Option<FileTransferDigest>,
    needs_confirmation: bool,
}
struct TreeDownload {
    root: Arc<Root>,
    name: String,
    page: u32,
    more: bool,
    skipped: u64,
    batch: Option<Incoming>,
    index: usize,
    bytes: u64,
    active: bool,
    overwrite: bool,
    needs_confirmation: bool,
    pending: Option<FileTransferDigest>,
}
enum Kind {
    Upload(Upload),
    Download(Download),
    Tree(TreeDownload),
}
struct Job {
    name: String,
    total: u64,
    done: u64,
    kind: Kind,
    touched: Instant,
    reported: Instant,
}
struct Listing {
    path: String,
    page: u32,
    cursor: u64,
    more: bool,
    paged: bool,
}
struct Client {
    state: Arc<State>,
    session: Session<NativeUi>,
    jobs: BTreeMap<i32, Job>,
    next: i32,
    listing: Option<Listing>,
    retired: VecDeque<i32>,
    upload_batches: bool,
    download_batches: bool,
}
fn remote(path: &str, allow_root: bool) -> ResultType<()> {
    farpane_files::validate_relative(path.strip_prefix('/').unwrap_or(path), allow_root)?;
    Ok(())
}
fn cancel(id: i32) -> Message {
    let mut a = FileAction::new();
    a.set_cancel(FileTransferCancel {
        id,
        ..Default::default()
    });
    let mut m = Message::new();
    m.set_file_action(a);
    m
}
fn confirm(id: i32) -> Message {
    fs::new_send_confirm(FileTransferSendConfirmRequest {
        id,
        file_num: 0,
        union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
        ..Default::default()
    })
}
fn upload_digest(id: i32, index: usize, entry: &Entry) -> Message {
    let mut r = FileResponse::new();
    r.set_digest(FileTransferDigest {
        id,
        file_num: index as i32,
        file_size: entry.size,
        last_modified: entry.modified,
        ..Default::default()
    });
    let mut m = Message::new();
    m.set_file_response(r);
    m
}
impl Client {
    fn retire(&mut self, id: i32) {
        self.retired.push_back(id);
        while self.retired.len() > 32 {
            self.retired.pop_front();
        }
    }
    fn send(&self, message: Message) -> ResultType<()> {
        let result = super::viewer_queue::send_file(&self.session, &self.state, message);
        // Disk/manifest failures retire one task. A dead transport or revoked
        // permission invalidates the entire connection, even if a tiny Cancel
        // could still fit in the otherwise stalled network credit queue.
        if let Err(error) = &result {
            self.state.fail(&format!("文件连接失败：{error}"));
        }
        result
    }
    fn report(&self, id: i32, job: &Job, status: &str, needs_confirmation: bool) {
        self.state.emit(EventKind::Transfer {
            job: id,
            name: job.name.chars().take(128).collect(),
            done: job.done,
            total: if matches!(&job.kind, Kind::Upload(u) if u.plan.tree && (u.preparing || u.more))
                || matches!(&job.kind, Kind::Tree(t) if t.more)
            {
                0
            } else {
                job.total
            },
            status: status.into(),
            needs_confirmation,
        });
    }
    fn command(&mut self, command: Command) -> ResultType<()> {
        if !self.state.authenticated.load(Ordering::Acquire)
            || !self.state.permissions.lock().unwrap().file
        {
            bail!("File connection is not authorized");
        }
        match command {
            Command::TransferFiles {
                local,
                remote: path,
            } => {
                remote(&path, true)?;
                let paths: Vec<_> = local.into_iter().map(PathBuf::from).collect();
                let plan = Plan::files(&paths)?;
                self.upload(plan, path)?;
            }
            Command::ListDirectory {
                path,
                page,
                remote: true,
            } => {
                remote(&path, true)?;
                let cursor = if page == 0 {
                    0
                } else {
                    let previous = self
                        .listing
                        .as_ref()
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("No directory continuation"))?;
                    if previous.path != path
                        || previous.page + 1 != page
                        || !previous.more
                        || !previous.paged
                    {
                        bail!("Directory page is stale or unsupported");
                    }
                    previous.cursor
                };
                let mut a = FileAction::new();
                a.set_read_dir(ReadDir {
                    path: path.clone(),
                    farpane_paged: true,
                    farpane_cursor: cursor,
                    farpane_page: page,
                    ..Default::default()
                });
                let mut m = Message::new();
                m.set_file_action(a);
                self.send(m)?;
                self.listing = Some(Listing {
                    path,
                    page,
                    cursor: 0,
                    more: false,
                    paged: true,
                });
            }
            Command::Transfer {
                local,
                remote: path,
                upload,
                overwrite,
                directory,
            } => {
                remote(&path, false)?;
                if self.jobs.len() >= 8 || local.len() > 4096 || !Path::new(&local).is_absolute() {
                    bail!("Invalid local selection or too many file jobs");
                }
                if upload {
                    let (plan, destination) = if directory {
                        if !self.upload_batches {
                            bail!("远端尚不支持目录分批传输");
                        }
                        (Plan::folder(Path::new(&local))?, path)
                    } else {
                        let (parent, name) = path.rsplit_once('/').unwrap_or(("", &path));
                        (Plan::file(Path::new(&local), name)?, parent.to_string())
                    };
                    self.upload(plan, destination)?;
                    return Ok(());
                }
                if directory && !self.download_batches {
                    bail!("远端尚不支持目录下载");
                }
                self.next = self
                    .next
                    .checked_add(1)
                    .ok_or_else(|| hbb_common::anyhow::anyhow!("File job ID exhausted"))?;
                let id = self.next;
                let (kind, total, message) = {
                    let selected = PathBuf::from(&local);
                    let parent = selected
                        .parent()
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("No download directory"))?;
                    let name = selected
                        .file_name()
                        .and_then(|n| n.to_str())
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("Invalid download filename"))?
                        .to_string();
                    farpane_files::validate_relative(&name, false)?;
                    let root = Root::provision(parent)?;
                    if directory {
                        let needs_confirmation = match root.directory(&name) {
                            Ok(_) => !overwrite,
                            Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
                            Err(e) => return Err(e.into()),
                        };
                        let mut action = FileAction::new();
                        action.set_send(FileTransferSendRequest {
                            id,
                            path: path.clone(),
                            farpane_tree: true,
                            ..Default::default()
                        });
                        let mut message = Message::new();
                        message.set_file_action(action);
                        (
                            Kind::Tree(TreeDownload {
                                root: Arc::new(root),
                                name,
                                page: 0,
                                more: true,
                                skipped: 0,
                                batch: None,
                                index: 0,
                                bytes: 0,
                                active: false,
                                overwrite,
                                needs_confirmation,
                                pending: None,
                            }),
                            0,
                            message,
                        )
                    } else {
                        (
                            Kind::Download(Download {
                                root,
                                name,
                                writer: None,
                                size: None,
                                overwrite,
                                pending: None,
                                needs_confirmation: false,
                            }),
                            0,
                            fs::new_send(id, fs::JobType::Generic, path.clone(), 0, false),
                        )
                    }
                };
                let job = Job {
                    name: path,
                    total,
                    done: 0,
                    kind,
                    touched: Instant::now(),
                    reported: Instant::now(),
                };
                self.send(message)?;
                self.report(id, &job, "waiting", false);
                self.jobs.insert(id, job);
            }
            Command::CancelTransfer { job: id } => {
                self.send(cancel(id))?;
                if let Some(job) = self.jobs.remove(&id) {
                    self.report(id, &job, "cancelled", false);
                }
                self.retire(id);
            }
            Command::ConfirmTransfer {
                job: id,
                accept,
                overwrite,
            } => {
                if matches!(self.jobs.get(&id).map(|j| &j.kind), Some(Kind::Tree(_))) {
                    return self.confirm_tree(id, accept, overwrite);
                }
                let mut job = self
                    .jobs
                    .remove(&id)
                    .ok_or_else(|| hbb_common::anyhow::anyhow!("File task expired"))?;
                let Kind::Download(download) = &mut job.kind else {
                    self.jobs.insert(id, job);
                    bail!("No file confirmation is pending");
                };
                if !download.needs_confirmation {
                    self.jobs.insert(id, job);
                    bail!("No file confirmation is pending");
                }
                if !accept {
                    self.send(cancel(id))?;
                    self.report(id, &job, "cancelled", false);
                    self.retire(id);
                    return Ok(());
                }
                if !overwrite {
                    self.jobs.insert(id, job);
                    bail!("Explicit overwrite consent is required");
                }
                download.writer = Some(download.root.receive(
                    &download.name,
                    download.size.unwrap(),
                    true,
                )?);
                download.needs_confirmation = false;
                if download.pending.take().is_some() {
                    self.send(confirm(id))?;
                }
                self.report(id, &job, "receiving", false);
                self.jobs.insert(id, job);
            }
            _ => bail!("Unsupported file command"),
        }
        Ok(())
    }
    fn upload(&mut self, plan: Plan, destination: String) -> ResultType<()> {
        if self.jobs.len() >= 8 {
            bail!("Too many active file transfers");
        }
        self.next = self
            .next
            .checked_add(1)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("File job ID exhausted"))?;
        let id = self.next;
        let name = if plan.tree {
            destination.clone()
        } else {
            "所选文件".into()
        };
        let job = Job {
            name,
            total: 0,
            done: 0,
            kind: Kind::Upload(Upload {
                plan,
                destination,
                entries: Vec::new(),
                reader: None,
                index: 0,
                preparing: true,
                more: false,
                page: 0,
                skipped: 0,
                ready: false,
                awaiting_ack: false,
            }),
            touched: Instant::now(),
            reported: Instant::now(),
        };
        self.report(id, &job, "scanning", false);
        self.jobs.insert(id, job);
        Ok(())
    }
    fn wire(&mut self, message: Message) -> ResultType<()> {
        let id = match message.union.as_ref() {
            Some(message::Union::FileAction(a)) => match a.union.as_ref() {
                Some(file_action::Union::SendConfirm(c)) => c.id,
                _ => 0,
            },
            Some(message::Union::FileResponse(r)) => match r.union.as_ref() {
                Some(file_response::Union::Block(v)) => v.id,
                Some(file_response::Union::Digest(v)) => v.id,
                Some(file_response::Union::Done(v)) => v.id,
                Some(file_response::Union::Error(v)) => v.id,
                Some(file_response::Union::Dir(v)) => v.id,
                _ => 0,
            },
            _ => 0,
        };
        if id > 0 && self.retired.contains(&id) {
            return Ok(());
        }
        let before = self
            .jobs
            .get(&id)
            .map(|j| (j.name.clone(), j.done, j.total));
        match self.handle_wire(message) {
            Ok(()) => Ok(()),
            Err(error) if id > 0 => self.fail_job(id, &error.to_string(), before),
            Err(error) => Err(error),
        }
    }
    fn fail_job(
        &mut self,
        id: i32,
        error: &str,
        before: Option<(String, u64, u64)>,
    ) -> ResultType<()> {
        if let Some(job) = self.jobs.remove(&id) {
            self.report(id, &job, "failed", false);
        } else if let Some((name, done, total)) = before {
            self.state.emit(EventKind::Transfer {
                job: id,
                name: name.chars().take(128).collect(),
                done,
                total,
                status: "failed".into(),
                needs_confirmation: false,
            });
        }
        self.retire(id);
        self.state.emit(EventKind::Log {
            level: "error".into(),
            message: format!(
                "文件任务失败：{}",
                error.chars().take(256).collect::<String>()
            ),
        });
        self.send(cancel(id))
    }
    fn handle_wire(&mut self, message: Message) -> ResultType<()> {
        match message.union {
            Some(message::Union::FileAction(a)) => match a.union {
                Some(file_action::Union::SendConfirm(c)) => {
                    let job = self.jobs.get_mut(&c.id).ok_or_else(|| {
                        hbb_common::anyhow::anyhow!("Unknown upload confirmation")
                    })?;
                    let Kind::Upload(upload) = &mut job.kind else {
                        bail!("Not an upload");
                    };
                    if c.file_num < 0
                        || c.file_num as usize != upload.index
                        || upload.ready
                        || upload.awaiting_ack
                        || upload.preparing
                        || c.farpane_page != upload.page
                    {
                        bail!("Unexpected upload confirmation");
                    }
                    match c.union {
                        Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
                        | Some(file_transfer_send_confirm_request::Union::Skip(false)) => {
                            upload.ready = true
                        }
                        _ => bail!("Resume/skip response is unsupported"),
                    };
                    let entry = upload.entries.get(upload.index).ok_or_else(|| {
                        hbb_common::anyhow::anyhow!("Upload confirmation outside manifest")
                    })?;
                    if !entry.directory {
                        upload.reader = Some(upload.plan.open(entry)?);
                    }
                    job.touched = Instant::now();
                }
                _ => bail!("Unrequested remote file action"),
            },
            Some(message::Union::FileResponse(r)) => match r.union {
                Some(file_response::Union::Dir(d)) => {
                    if d.entries.len() > PAGE_ENTRIES
                        || d.entries.iter().map(|e| e.name.len() + 64).sum::<usize>() > PAGE_BYTES
                    {
                        bail!("Remote directory exceeds bounded page limit");
                    }
                    if d.id == 0 {
                        self.upload_batches = d.farpane_upload_batches;
                        self.download_batches = d.farpane_download_batches;
                        remote(&d.path, true)?;
                        let page = self.listing.as_ref().map_or(0, |l| l.page);
                        if let Some(pending) = &self.listing {
                            if pending.path != d.path && !(pending.path.is_empty() && d.path == "/")
                            {
                                bail!("Directory response path changed");
                            }
                        }
                        let mut entries = Vec::new();
                        for e in d.entries {
                            farpane_files::validate_relative(&e.name, false)?;
                            if e.name.contains('/') {
                                bail!("Directory entry is not a direct child");
                            }
                            let directory = match e.entry_type.enum_value() {
                                Ok(FileType::Dir) => true,
                                Ok(FileType::File) => false,
                                _ => continue,
                            };
                            entries.push(farpane_protocol::FileEntry {
                                name: e.name,
                                directory,
                                size: e.size,
                                modified: i64::try_from(e.modified_time).unwrap_or(i64::MAX),
                            });
                        }
                        if d.farpane_more
                            && (!d.farpane_paged
                                || d.farpane_cursor == 0
                                || d.farpane_page != page + 1)
                        {
                            bail!("Invalid directory continuation");
                        }
                        self.listing = Some(Listing {
                            path: d.path.clone(),
                            page,
                            cursor: d.farpane_cursor,
                            more: d.farpane_more,
                            paged: d.farpane_paged,
                        });
                        self.state.emit(EventKind::Directory {
                            path: d.path,
                            page,
                            more: d.farpane_more,
                            entries,
                        });
                    } else {
                        if matches!(self.jobs.get(&d.id).map(|j| &j.kind), Some(Kind::Tree(_))) {
                            return self.tree_manifest(d);
                        }
                        let mut job = self.jobs.remove(&d.id).ok_or_else(|| {
                            hbb_common::anyhow::anyhow!("Unrequested download manifest")
                        })?;
                        let Kind::Download(download) = &mut job.kind else {
                            bail!("Not a download");
                        };
                        if download.size.is_some()
                            || d.entries.len() != 1
                            || d.entries[0].entry_type.enum_value() != Ok(FileType::File)
                        {
                            bail!("Select individual files from the directory browser");
                        }
                        let size = d.entries[0].size;
                        if size > i64::MAX as u64 {
                            bail!("Download exceeds file size limit");
                        }
                        download.size = Some(size);
                        job.total = size;
                        match download
                            .root
                            .receive(&download.name, size, download.overwrite)
                        {
                            Ok(writer) => download.writer = Some(writer),
                            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                                download.needs_confirmation = true
                            }
                            Err(error) => return Err(error.into()),
                        }
                        let pending = download.needs_confirmation;
                        self.report(
                            d.id,
                            &job,
                            if pending {
                                "overwrite_required"
                            } else {
                                "receiving"
                            },
                            pending,
                        );
                        self.jobs.insert(d.id, job);
                    }
                }
                Some(file_response::Union::Digest(d)) => {
                    if matches!(self.jobs.get(&d.id).map(|j| &j.kind), Some(Kind::Tree(_))) {
                        return self.tree_digest(d);
                    }
                    let job = self
                        .jobs
                        .get_mut(&d.id)
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("Unexpected file digest"))?;
                    let Kind::Download(download) = &mut job.kind else {
                        bail!("Remote destination requires an unsupported overwrite negotiation");
                    };
                    if d.file_num != 0
                        || d.is_resume
                        || d.is_upload
                        || download.size != Some(d.file_size)
                        || download.pending.is_some()
                    {
                        bail!("Download digest differs from manifest");
                    }
                    if download.needs_confirmation {
                        download.pending = Some(d);
                    } else {
                        self.send(confirm(d.id))?;
                    }
                }
                Some(file_response::Union::Block(b)) => {
                    if matches!(self.jobs.get(&b.id).map(|j| &j.kind), Some(Kind::Tree(_))) {
                        return self.tree_block(b);
                    }
                    if b.data.len() > BLOCK_BYTES {
                        bail!("File block exceeds size limit");
                    }
                    let job = self
                        .jobs
                        .get_mut(&b.id)
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("Unrequested file block"))?;
                    let Kind::Download(download) = &mut job.kind else {
                        bail!("Not a download");
                    };
                    if b.file_num != 0 || download.needs_confirmation {
                        bail!("Unconfirmed download block");
                    }
                    if b.data.is_empty() && !b.compressed {
                        return Ok(());
                    }
                    let data = if b.compressed {
                        hbb_common::compress::decompress_with_limit(&b.data, BLOCK_BYTES)?
                    } else {
                        b.data.to_vec()
                    };
                    download
                        .writer
                        .as_mut()
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("No download destination"))?
                        .write_block(&data)?;
                    job.done += data.len() as u64;
                    job.touched = Instant::now();
                    if job.reported.elapsed() > Duration::from_millis(250) {
                        job.reported = Instant::now();
                        let event = EventKind::Transfer {
                            job: b.id,
                            name: job.name.clone(),
                            done: job.done,
                            total: job.total,
                            status: "receiving".into(),
                            needs_confirmation: false,
                        };
                        self.state.emit(event);
                    }
                }
                Some(file_response::Union::Done(d)) => {
                    if matches!(self.jobs.get(&d.id).map(|j| &j.kind), Some(Kind::Tree(_))) {
                        return self.tree_done(d);
                    }
                    let mut job = self
                        .jobs
                        .remove(&d.id)
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("Unknown file completion"))?;
                    if job.done != job.total {
                        bail!("File completion arrived before declared bytes");
                    }
                    match &mut job.kind {
                        Kind::Upload(upload)
                            if upload.awaiting_ack
                                && d.file_num == upload.entries.len() as i32
                                && d.farpane_page == upload.page =>
                        {
                            if upload.more {
                                upload.page = upload.page.checked_add(1).ok_or_else(|| {
                                    hbb_common::anyhow::anyhow!("Directory batch counter exhausted")
                                })?;
                                upload.awaiting_ack = false;
                                upload.preparing = true;
                                upload.entries.clear();
                                job.touched = Instant::now();
                                self.report(d.id, &job, "scanning", false);
                                self.jobs.insert(d.id, job);
                                return Ok(());
                            }
                        }
                        Kind::Download(download) if d.file_num == 1 => download
                            .writer
                            .take()
                            .ok_or_else(|| hbb_common::anyhow::anyhow!("No confirmed download"))?
                            .finish()?,
                        _ => bail!("Unexpected file completion"),
                    };
                    let skipped = match &job.kind {
                        Kind::Upload(u) => u.skipped,
                        _ => 0,
                    };
                    self.report(
                        d.id,
                        &job,
                        if skipped == 0 {
                            "completed"
                        } else {
                            "completed_with_skips"
                        },
                        false,
                    );
                    if skipped > 0 {
                        self.state.emit(EventKind::Log {
                            level: "warning".into(),
                            message: format!(
                                "目录传输已结束，跳过了 {skipped} 个不支持的对象（如符号链接）"
                            ),
                        });
                    }
                    self.retire(d.id);
                }
                Some(file_response::Union::Error(e)) => {
                    if let Some(job) = self.jobs.remove(&e.id) {
                        self.report(e.id, &job, "failed", false);
                        self.retire(e.id);
                    }
                    self.state.emit(EventKind::Log {
                        level: "error".into(),
                        message: format!(
                            "文件操作失败：{}",
                            e.error.chars().take(256).collect::<String>()
                        ),
                    });
                }
                _ => bail!("Unrequested file response"),
            },
            _ => bail!("Not a file message"),
        }
        Ok(())
    }
    fn tree_manifest(&mut self, d: FileDirectory) -> ResultType<()> {
        let job = self.jobs.get_mut(&d.id).unwrap();
        let Kind::Tree(tree) = &mut job.kind else {
            unreachable!()
        };
        if !d.farpane_tree
            || d.path.strip_prefix('/').unwrap_or(&d.path)
                != job.name.strip_prefix('/').unwrap_or(&job.name)
            || d.farpane_page != tree.page
            || tree.batch.is_some()
            || d.entries.is_empty()
            || d.farpane_skipped < tree.skipped
        {
            bail!("Stale or changed directory download manifest");
        }
        if tree.page == 0
            && (d.entries[0].name != ""
                || d.entries[0].entry_type.enum_value() != Ok(FileType::Dir))
        {
            bail!("Directory download has no selected root");
        }
        let mut entries = Vec::new();
        for (index, e) in d.entries.into_iter().enumerate() {
            let directory = match e.entry_type.enum_value() {
                Ok(FileType::Dir) => true,
                Ok(FileType::File) => false,
                _ => bail!("Unsupported directory download entry"),
            };
            let name = if e.name.is_empty() {
                if tree.page != 0 || index != 0 || !directory {
                    bail!("Unexpected directory root entry");
                }
                tree.name.clone()
            } else {
                farpane_files::validate_relative(&e.name, false)?;
                format!("{}/{}", tree.name, e.name)
            };
            entries.push(Entry {
                name,
                directory,
                size: e.size,
                modified: e.modified_time,
            });
        }
        let batch = Incoming::new(tree.root.clone(), entries)?;
        job.total = job
            .total
            .checked_add(batch.progress().1)
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Directory size exceeds limit"))?;
        if tree.page == 0 && !tree.overwrite {
            match tree.root.directory(&tree.name) {
                Ok(_) => tree.needs_confirmation = true,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e.into()),
            }
        }
        tree.batch = Some(batch);
        tree.index = 0;
        tree.more = d.farpane_more;
        tree.skipped = d.farpane_skipped;
        job.touched = Instant::now();
        let pending = tree.needs_confirmation;
        let job = self.jobs.get(&d.id).unwrap();
        self.report(
            d.id,
            job,
            if pending {
                "overwrite_required"
            } else {
                "receiving"
            },
            pending,
        );
        Ok(())
    }
    fn tree_digest(&mut self, d: FileTransferDigest) -> ResultType<()> {
        let job = self.jobs.get_mut(&d.id).unwrap();
        let Kind::Tree(tree) = &mut job.kind else {
            unreachable!()
        };
        let batch = tree
            .batch
            .as_mut()
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Missing directory manifest"))?;
        let entry = batch
            .entries()
            .get(tree.index)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Directory index outside manifest"))?;
        if d.file_num < 0
            || d.file_num as usize != tree.index
            || d.is_resume
            || d.is_upload
            || tree.active
            || tree.pending.is_some()
            || d.file_size != entry.size
            || d.last_modified != entry.modified
        {
            bail!("Directory digest differs from confirmed manifest");
        }
        job.touched = Instant::now();
        if tree.needs_confirmation {
            tree.pending = Some(d);
            return Ok(());
        }
        let directory = entry.directory;
        let empty = entry.size == 0;
        batch.begin(tree.index, tree.overwrite)?;
        if directory || empty {
            if !directory {
                batch.commit(tree.index)?;
            }
            tree.index += 1;
        } else {
            tree.active = true;
            tree.bytes = 0;
        }
        let message = fs::new_send_confirm(FileTransferSendConfirmRequest {
            id: d.id,
            file_num: d.file_num,
            farpane_page: tree.page,
            union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
            ..Default::default()
        });
        self.send(message)
    }
    fn confirm_tree(&mut self, id: i32, accept: bool, overwrite: bool) -> ResultType<()> {
        let job = self.jobs.get_mut(&id).unwrap();
        let Kind::Tree(tree) = &mut job.kind else {
            unreachable!()
        };
        if !tree.needs_confirmation {
            bail!("No directory confirmation is pending");
        }
        if !accept {
            self.send(cancel(id))?;
            let job = self.jobs.remove(&id).unwrap();
            self.report(id, &job, "cancelled", false);
            self.retire(id);
            return Ok(());
        }
        if !overwrite {
            bail!("Explicit directory overwrite consent is required");
        }
        tree.overwrite = true;
        tree.needs_confirmation = false;
        let pending = tree.pending.take();
        job.touched = Instant::now();
        if let Some(d) = pending {
            self.tree_digest(d)?;
        }
        self.report(id, self.jobs.get(&id).unwrap(), "receiving", false);
        Ok(())
    }
    fn tree_block(&mut self, b: FileTransferBlock) -> ResultType<()> {
        if b.data.len() > BLOCK_BYTES {
            bail!("File block exceeds size limit");
        }
        let job = self.jobs.get_mut(&b.id).unwrap();
        let Kind::Tree(tree) = &mut job.kind else {
            unreachable!()
        };
        if !tree.active
            || tree.needs_confirmation
            || b.file_num < 0
            || b.file_num as usize != tree.index
        {
            bail!("Unconfirmed directory block");
        }
        let batch = tree
            .batch
            .as_mut()
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Missing directory manifest"))?;
        let data = if b.compressed {
            hbb_common::compress::decompress_with_limit(&b.data, BLOCK_BYTES)?
        } else {
            b.data.to_vec()
        };
        if data.is_empty() {
            bail!("Unexpected empty directory block");
        }
        batch.write(tree.index, &data)?;
        tree.bytes += data.len() as u64;
        job.done += data.len() as u64;
        if tree.bytes == batch.entries()[tree.index].size {
            batch.commit(tree.index)?;
            tree.active = false;
            tree.index += 1;
        }
        job.touched = Instant::now();
        if job.reported.elapsed() > Duration::from_millis(250) {
            job.reported = Instant::now();
            self.report(b.id, self.jobs.get(&b.id).unwrap(), "receiving", false);
        }
        Ok(())
    }
    fn tree_done(&mut self, d: FileTransferDone) -> ResultType<()> {
        let job = self.jobs.get_mut(&d.id).unwrap();
        let Kind::Tree(tree) = &mut job.kind else {
            unreachable!()
        };
        let batch = tree
            .batch
            .as_ref()
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Missing directory manifest"))?;
        if !batch.complete()
            || tree.active
            || tree.needs_confirmation
            || tree.pending.is_some()
            || d.farpane_page != tree.page
            || d.file_num != batch.entries().len() as i32
            || job.done != job.total
        {
            bail!("Directory completion arrived before local commit");
        }
        let more = tree.more;
        let skipped = tree.skipped;
        tree.batch = None;
        if more {
            tree.page = tree
                .page
                .checked_add(1)
                .ok_or_else(|| hbb_common::anyhow::anyhow!("Directory page counter exhausted"))?;
        }
        job.touched = Instant::now();
        let mut r = FileResponse::new();
        r.set_done(d.clone());
        let mut m = Message::new();
        m.set_file_response(r);
        self.send(m)?;
        if !more {
            let job = self.jobs.remove(&d.id).unwrap();
            self.report(
                d.id,
                &job,
                if skipped == 0 {
                    "completed"
                } else {
                    "completed_with_skips"
                },
                false,
            );
            if skipped > 0 {
                self.state.emit(EventKind::Log {
                    level: "warning".into(),
                    message: format!(
                        "目录下载已结束，远端跳过了 {skipped} 个不支持的对象（如符号链接）"
                    ),
                });
            }
            self.retire(d.id);
        }
        Ok(())
    }
    fn advance(&mut self) -> ResultType<bool> {
        let mut busy = false;
        for id in self.jobs.keys().copied().collect::<Vec<_>>() {
            let result = (|| -> ResultType<bool> {
                let mut busy = false;
                let job = self.jobs.get_mut(&id).unwrap();
                if job.touched.elapsed() > Duration::from_secs(120) {
                    self.send(cancel(id))?;
                    let job = self.jobs.remove(&id).unwrap();
                    self.report(id, &job, "timed_out", false);
                    self.retire(id);
                    return Ok(busy);
                }
                let Kind::Upload(upload) = &mut job.kind else {
                    return Ok(busy);
                };
                if upload.preparing {
                    busy = true;
                    let batch = match upload.plan.poll_batch()? {
                        Poll::Pending => {
                            job.touched = Instant::now();
                            return Ok(busy);
                        }
                        Poll::Ready(Some(batch)) => batch,
                        Poll::Ready(None) => bail!("Missing final directory manifest"),
                    };
                    let total = batch
                        .entries
                        .iter()
                        .try_fold(0u64, |sum, e| sum.checked_add(e.size))
                        .filter(|n| *n <= i64::MAX as u64)
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("Batch size exceeds limit"))?;
                    job.total = job
                        .total
                        .checked_add(total)
                        .filter(|n| *n <= i64::MAX as u64)
                        .ok_or_else(|| {
                            hbb_common::anyhow::anyhow!("Transfer size exceeds limit")
                        })?;
                    upload.entries = batch.entries;
                    upload.more = batch.more;
                    upload.skipped = batch.skipped;
                    upload.preparing = false;
                    upload.index = 0;
                    job.touched = Instant::now();
                    if !upload.plan.tree {
                        job.name = if upload.entries.len() == 1 {
                            format!(
                                "{}/{}",
                                upload.destination.trim_end_matches('/'),
                                upload.entries[0].name
                            )
                        } else {
                            format!("{} 个文件", upload.entries.len())
                        };
                    }
                    let mut action = FileAction::new();
                    action.set_receive(FileTransferReceiveRequest {
                        id,
                        path: upload.destination.clone(),
                        file_num: 0,
                        total_size: total,
                        files: upload
                            .entries
                            .iter()
                            .map(|e| FileEntry {
                                name: e.name.clone(),
                                size: e.size,
                                modified_time: e.modified,
                                entry_type: if e.directory {
                                    FileType::Dir
                                } else {
                                    FileType::File
                                }
                                .into(),
                                ..Default::default()
                            })
                            .collect(),
                        farpane_tree: upload.plan.tree,
                        farpane_page: upload.page,
                        farpane_more: upload.more,
                        ..Default::default()
                    });
                    let mut request = Message::new();
                    request.set_file_action(action);
                    let digest = upload_digest(id, 0, &upload.entries[0]);
                    self.state.emit(EventKind::Transfer {
                        job: id,
                        name: job.name.clone(),
                        done: job.done,
                        total: if upload.plan.tree && upload.more {
                            0
                        } else {
                            job.total
                        },
                        status: "waiting".into(),
                        needs_confirmation: false,
                    });
                    self.send(request)?;
                    self.send(digest)?;
                    return Ok(busy);
                }
                if !upload.ready {
                    return Ok(busy);
                }
                busy = true;
                let data = if upload.entries[upload.index].directory {
                    Vec::new()
                } else {
                    upload
                        .reader
                        .as_mut()
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("Missing confirmed source"))?
                        .read_block()?
                };
                let message = if data.is_empty() {
                    upload.ready = false;
                    upload.reader = None;
                    upload.index += 1;
                    if upload.index < upload.entries.len() {
                        upload_digest(id, upload.index, &upload.entries[upload.index])
                    } else {
                        upload.awaiting_ack = true;
                        let mut r = FileResponse::new();
                        r.set_done(FileTransferDone {
                            id,
                            file_num: upload.entries.len() as i32,
                            farpane_page: upload.page,
                            ..Default::default()
                        });
                        let mut m = Message::new();
                        m.set_file_response(r);
                        m
                    }
                } else {
                    job.done += data.len() as u64;
                    fs::new_block(FileTransferBlock {
                        id,
                        file_num: upload.index as i32,
                        data: data.into(),
                        ..Default::default()
                    })
                };
                job.touched = Instant::now();
                if job.reported.elapsed() > Duration::from_millis(250) {
                    job.reported = Instant::now();
                    self.state.emit(EventKind::Transfer {
                        job: id,
                        name: job.name.clone(),
                        done: job.done,
                        total: if upload.plan.tree && upload.more {
                            0
                        } else {
                            job.total
                        },
                        status: "sending".into(),
                        needs_confirmation: false,
                    });
                }
                self.send(message)?;
                Ok(busy)
            })();
            match result {
                Ok(active) => busy |= active,
                Err(error) => {
                    self.fail_job(id, &error.to_string(), None)?;
                }
            }
        }
        Ok(busy)
    }
}
