//! RustDesk file wire adapter. All filesystem work stays on the file worker.
use super::files;
use base::{fs, message_proto::*};
use farpane_files::{
    outgoing::Plan,
    owner::{Cursor, Key, Owner, Read},
    Entry, Reader, Root, BLOCK_BYTES, PAGE_BYTES, PAGE_ENTRIES,
};
use farpane_protocol::FileTask;
use hbb_common::{bail, ResultType};
use std::{
    collections::BTreeMap,
    path::Path,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc, Arc,
    },
    task::Poll,
    time::{Duration, Instant},
};

static NEXT_OWNER: AtomicU64 = AtomicU64::new(1);
fn relative(path: &str) -> ResultType<String> {
    let path = path.strip_prefix('/').unwrap_or(path);
    farpane_files::validate_relative(path, true)?;
    Ok(path.into())
}
fn wire_entry(e: &Entry) -> FileEntry {
    FileEntry {
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
    }
}
fn digest(id: i32, index: i32, size: u64, modified: u64) -> Message {
    let mut response = FileResponse::new();
    response.set_digest(FileTransferDigest {
        id,
        file_num: index,
        file_size: size,
        last_modified: modified,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_file_response(response);
    message
}
fn confirm(id: i32, index: i32, page: u32) -> Message {
    fs::new_send_confirm(FileTransferSendConfirmRequest {
        id,
        file_num: index,
        farpane_page: page,
        union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
        ..Default::default()
    })
}
fn message_id(message: &Message) -> i32 {
    match message.union.as_ref() {
        Some(message::Union::FileAction(a)) => match a.union.as_ref() {
            Some(file_action::Union::Receive(v)) => v.id,
            Some(file_action::Union::Send(v)) => v.id,
            Some(file_action::Union::Cancel(v)) => v.id,
            Some(file_action::Union::SendConfirm(v)) => v.id,
            Some(file_action::Union::Create(v)) => v.id,
            Some(file_action::Union::AllFiles(v)) => v.id,
            Some(file_action::Union::RemoveDir(v)) => v.id,
            Some(file_action::Union::RemoveFile(v)) => v.id,
            Some(file_action::Union::Rename(v)) => v.id,
            _ => 0,
        },
        Some(message::Union::FileResponse(r)) => match r.union.as_ref() {
            Some(file_response::Union::Block(v)) => v.id,
            Some(file_response::Union::Digest(v)) => v.id,
            Some(file_response::Union::Done(v)) => v.id,
            Some(file_response::Union::Error(v)) => v.id,
            _ => 0,
        },
        _ => 0,
    }
}
struct Upload {
    base: String,
    tree: bool,
    page: u32,
    more: bool,
    awaiting_batch: bool,
    overwrite: bool,
    base_done: u64,
    entries: Vec<Entry>,
    next: usize,
    active: bool,
    bytes: u64,
    pending: Option<FileTransferDigest>,
}
struct Download {
    ready: bool,
    name: String,
    size: u64,
}
struct TreeDownload {
    path: String,
    plan: Option<Plan>,
    entries: Vec<Entry>,
    reader: Option<Reader>,
    index: usize,
    page: u32,
    more: bool,
    skipped: u64,
    preparing: bool,
    ready: bool,
    awaiting_ack: bool,
}
enum Kind {
    Upload(Upload),
    Download(Download),
    Tree(TreeDownload),
}
struct Job {
    key: Option<Key>,
    token: i32,
    decision: Arc<files::Decision>,
    approved: bool,
    done: u64,
    total: u64,
    touched: Instant,
    kind: Kind,
}
struct Host<'a> {
    connection: i32,
    root: Arc<Root>,
    owner: Owner,
    generation: u64,
    confirm: bool,
    jobs: BTreeMap<i32, Job>,
    send: &'a dyn Fn(Message) -> ResultType<()>,
}
impl Drop for Host<'_> {
    fn drop(&mut self) {
        self.owner.revoke();
        for job in self.jobs.values() {
            files::update(job.token, job.done, "cancelled", "文件连接已结束", true);
        }
    }
}
impl Host<'_> {
    fn finish(&mut self, id: i32, status: &str, detail: &str) {
        if let Some(job) = self.jobs.remove(&id) {
            if let Some(key) = job.key {
                let _ = self.owner.cancel(key);
            }
            files::update(job.token, job.done, status, detail, true);
        }
    }
    fn admit(&self, id: i32) -> ResultType<()> {
        if id <= 0
            || self.jobs.contains_key(&id)
            || self.jobs.len() >= farpane_files::owner::MAX_JOBS
        {
            bail!("Invalid or duplicate file job");
        }
        Ok(())
    }
    fn receive(&mut self, r: FileTransferReceiveRequest) -> ResultType<()> {
        let continuation = self.jobs.contains_key(&r.id);
        if !continuation {
            self.admit(r.id)?;
        }
        if r.file_num != 0 || r.files.is_empty() || r.files.len() > PAGE_ENTRIES {
            bail!("Invalid receive manifest or unsupported resume");
        }
        let base = relative(&r.path)?;
        if !r.farpane_tree && (r.farpane_page != 0 || r.farpane_more) {
            bail!("Batch metadata requires a selected directory transfer");
        }
        if r.farpane_tree {
            farpane_files::validate_relative(&base, false)?;
            if r.farpane_page == 0
                && (r.files[0].name != ""
                    || r.files[0].entry_type.enum_value() != Ok(FileType::Dir))
            {
                bail!("First directory batch must name its selected root");
            }
        }
        let retained_overwrite = if continuation {
            let job = self.jobs.get(&r.id).unwrap();
            let Kind::Upload(upload) = &job.kind else {
                bail!("Not an upload continuation");
            };
            if !job.approved
                || !upload.tree
                || !r.farpane_tree
                || !upload.awaiting_batch
                || upload.base != base
                || upload.page.checked_add(1) != Some(r.farpane_page)
            {
                bail!("Stale batch or changed directory scope");
            }
            upload.overwrite
        } else {
            if r.farpane_page != 0 {
                bail!("Missing initial directory batch");
            }
            false
        };
        let mut entries = Vec::new();
        let mut metadata = 0usize;
        let mut overwrite = false;
        if r.farpane_tree && !continuation {
            match self.root.directory(&base) {
                Ok(_) => overwrite = true,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        for (index, f) in r.files.into_iter().enumerate() {
            let directory = match f.entry_type.enum_value() {
                Ok(FileType::Dir) => true,
                Ok(FileType::File) => false,
                _ => bail!("Unsupported file type"),
            };
            if r.farpane_tree
                && f.name.is_empty()
                && (r.farpane_page != 0 || index != 0 || !directory)
            {
                bail!("Only the first directory entry may address the selected root");
            }
            let name = if f.name.is_empty() {
                base.clone()
            } else if base.is_empty() {
                farpane_files::validate_relative(&f.name, false)?;
                f.name
            } else {
                farpane_files::validate_relative(&f.name, false)?;
                format!("{base}/{}", f.name)
            };
            farpane_files::validate_relative(&name, false)?;
            metadata += name.len() + 64;
            if metadata > PAGE_BYTES {
                bail!("Receive manifest exceeds limit");
            }
            if !directory {
                match self.root.read(&name) {
                    Ok(_) => overwrite = true,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error.into()),
                }
            }
            entries.push(Entry {
                name,
                directory,
                size: f.size,
                modified: f.modified_time,
            });
        }
        let (key, total) = self.owner.offer_receive(entries.clone())?;
        if total != r.total_size {
            let _ = self.owner.cancel(key);
            bail!("Receive size differs from manifest");
        }
        if continuation {
            if overwrite && !retained_overwrite {
                let _ = self.owner.cancel(key);
                bail!("A later directory batch would overwrite unapproved files");
            }
            let combined = self
                .jobs
                .get(&r.id)
                .unwrap()
                .total
                .checked_add(total)
                .filter(|n| *n <= i64::MAX as u64);
            let Some(combined) = combined else {
                let _ = self.owner.cancel(key);
                bail!("Directory byte count exceeds limit");
            };
            if let Err(error) = self.owner.confirm_receive(key, true, retained_overwrite) {
                let _ = self.owner.cancel(key);
                return Err(error.into());
            }
            let job = self.jobs.get_mut(&r.id).unwrap();
            job.total = combined;
            job.key = Some(key);
            job.kind = Kind::Upload(Upload {
                base,
                tree: true,
                page: r.farpane_page,
                more: r.farpane_more,
                awaiting_batch: false,
                overwrite: retained_overwrite,
                base_done: job.done,
                entries,
                next: 0,
                active: false,
                bytes: 0,
                pending: None,
            });
            files::total(job.token, if r.farpane_more { 0 } else { job.total });
            files::update(job.token, job.done, "receiving", "", false);
            return Ok(());
        }
        let registration = files::register(
            FileTask {
                connection: self.connection,
                name: if r.farpane_tree {
                    base.clone()
                } else if entries.len() > 1 {
                    format!("{} 个项目 · /{}", entries.len(), base)
                } else {
                    entries[0].name.clone()
                },
                upload: true,
                total: if r.farpane_more { 0 } else { total },
                overwrite_required: overwrite,
                ..Default::default()
            },
            self.confirm || overwrite,
        );
        let (token, decision) = match registration {
            Ok(v) => v,
            Err(error) => {
                let _ = self.owner.cancel(key);
                return Err(error);
            }
        };
        self.jobs.insert(
            r.id,
            Job {
                key: Some(key),
                token,
                decision,
                approved: false,
                done: 0,
                total,
                touched: Instant::now(),
                kind: Kind::Upload(Upload {
                    base,
                    tree: r.farpane_tree,
                    page: 0,
                    more: r.farpane_more,
                    awaiting_batch: false,
                    overwrite: false,
                    base_done: 0,
                    entries,
                    next: 0,
                    active: false,
                    bytes: 0,
                    pending: None,
                }),
            },
        );
        Ok(())
    }
    fn download(&mut self, r: FileTransferSendRequest) -> ResultType<()> {
        self.admit(r.id)?;
        if r.file_num != 0
            || r.file_type.enum_value() != Ok(file_transfer_send_request::FileType::Generic)
        {
            bail!("Unsupported file request or resume");
        }
        let path = relative(&r.path)?;
        if r.farpane_tree {
            farpane_files::validate_relative(&path, false)?;
            self.root.directory(&path)?;
            let (token, decision) = files::register(
                FileTask {
                    connection: self.connection,
                    name: path.clone(),
                    upload: false,
                    ..Default::default()
                },
                self.confirm,
            )?;
            self.jobs.insert(
                r.id,
                Job {
                    key: None,
                    token,
                    decision,
                    approved: false,
                    done: 0,
                    total: 0,
                    touched: Instant::now(),
                    kind: Kind::Tree(TreeDownload {
                        path,
                        plan: None,
                        entries: Vec::new(),
                        reader: None,
                        index: 0,
                        page: 0,
                        more: false,
                        skipped: 0,
                        preparing: true,
                        ready: false,
                        awaiting_ack: false,
                    }),
                },
            );
            return Ok(());
        }
        let (key, size) = self.owner.offer_send(&path)?;
        let registration = files::register(
            FileTask {
                connection: self.connection,
                name: path,
                upload: false,
                total: size,
                ..Default::default()
            },
            self.confirm,
        );
        let (token, decision) = match registration {
            Ok(v) => v,
            Err(error) => {
                let _ = self.owner.cancel(key);
                return Err(error);
            }
        };
        self.jobs.insert(
            r.id,
            Job {
                key: Some(key),
                token,
                decision,
                approved: false,
                done: 0,
                total: size,
                touched: Instant::now(),
                kind: Kind::Download(Download {
                    ready: false,
                    name: r.path,
                    size,
                }),
            },
        );
        Ok(())
    }
    fn start_upload(&mut self, id: i32, d: FileTransferDigest) -> ResultType<()> {
        let job = self
            .jobs
            .get_mut(&id)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Unknown upload"))?;
        let Kind::Upload(upload) = &mut job.kind else {
            bail!("Digest does not belong to upload");
        };
        if d.is_resume
            || d.is_upload
            || d.file_num < 0
            || d.file_num as usize != upload.next
            || upload.active
            || upload.pending.is_some()
            || upload.awaiting_batch
        {
            bail!("Unexpected upload digest");
        }
        let entry = upload
            .entries
            .get(upload.next)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Digest outside manifest"))?;
        if entry.size != d.file_size || entry.modified != d.last_modified {
            bail!("Digest differs from receive manifest");
        }
        if !job.approved {
            upload.pending = Some(d);
            return Ok(());
        }
        self.owner.begin_receive(job.key.unwrap(), upload.next)?;
        if entry.directory || entry.size == 0 {
            if !entry.directory {
                self.owner.commit(job.key.unwrap(), upload.next)?;
            }
            upload.next += 1;
        } else {
            upload.active = true;
            upload.bytes = 0;
        }
        (self.send)(confirm(id, d.file_num, upload.page))?;
        Ok(())
    }
    fn block(&mut self, b: FileTransferBlock) -> ResultType<()> {
        if b.data.len() > BLOCK_BYTES {
            bail!("Compressed file block exceeds limit");
        }
        let job = self
            .jobs
            .get_mut(&b.id)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Unknown upload"))?;
        let Kind::Upload(upload) = &mut job.kind else {
            bail!("Not an upload");
        };
        if !job.approved {
            bail!("File destination has not been confirmed");
        }
        // Current RustDesk emits an empty block when advancing past each file.
        if b.data.is_empty()
            && !b.compressed
            && upload.next > 0
            && b.file_num == upload.next as i32 - 1
        {
            return Ok(());
        }
        if !upload.active || b.file_num < 0 || b.file_num as usize != upload.next {
            bail!("Unexpected upload block");
        }
        let data = if b.compressed {
            hbb_common::compress::decompress_with_limit(&b.data, BLOCK_BYTES)?
        } else {
            b.data.to_vec()
        };
        let progress = self.owner.write(job.key.unwrap(), upload.next, &data)?;
        upload.bytes += data.len() as u64;
        job.done = upload.base_done + progress.done;
        if upload.bytes == upload.entries[upload.next].size {
            self.owner.commit(job.key.unwrap(), upload.next)?;
            upload.active = false;
            upload.next += 1;
        }
        files::update(job.token, job.done, "receiving", "", false);
        Ok(())
    }
    fn handle(&mut self, message: Message) -> ResultType<()> {
        let id = message_id(&message);
        match message.union {
            Some(message::Union::FileAction(a)) => match a.union {
                Some(file_action::Union::ReadDir(r)) => {
                    let path = relative(&r.path)?;
                    let after = if r.farpane_cursor == 0 {
                        None
                    } else {
                        Some(Cursor {
                            key: Key {
                                generation: self.generation,
                                serial: r.farpane_cursor,
                            },
                            page: r.farpane_page,
                        })
                    };
                    if !r.farpane_paged && after.is_some() {
                        bail!("Unexpected legacy directory cursor");
                    }
                    let page = self.owner.list(&path, r.include_hidden, after)?;
                    if !r.farpane_paged && page.next.is_some() {
                        bail!("This directory requires a client with paged directory support");
                    }
                    let mut response = FileResponse::new();
                    response.set_dir(FileDirectory {
                        id: 0,
                        path: format!("/{path}"),
                        entries: page.entries.iter().map(wire_entry).collect(),
                        farpane_paged: r.farpane_paged,
                        farpane_cursor: page.next.map_or(0, |c| c.key.serial),
                        farpane_page: page.next.map_or(0, |c| c.page),
                        farpane_more: page.next.is_some(),
                        farpane_upload_batches: true,
                        farpane_download_batches: true,
                        ..Default::default()
                    });
                    let mut message = Message::new();
                    message.set_file_response(response);
                    (self.send)(message)?;
                }
                Some(file_action::Union::Receive(r)) => self.receive(r)?,
                Some(file_action::Union::Send(r)) => self.download(r)?,
                Some(file_action::Union::Cancel(r)) => {
                    self.finish(r.id, "cancelled", "远端取消了传输")
                }
                Some(file_action::Union::SendConfirm(r)) => {
                    let job = self
                        .jobs
                        .get_mut(&r.id)
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("Unknown download"))?;
                    if let Kind::Tree(tree) = &mut job.kind {
                        if !job.approved
                            || tree.preparing
                            || tree.ready
                            || tree.awaiting_ack
                            || r.file_num < 0
                            || r.file_num as usize != tree.index
                            || r.farpane_page != tree.page
                            || !matches!(
                                r.union,
                                Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
                            )
                        {
                            bail!("Unexpected directory file confirmation");
                        }
                        let entry = tree.entries.get(tree.index).ok_or_else(|| {
                            hbb_common::anyhow::anyhow!("Directory index outside manifest")
                        })?;
                        if !entry.directory {
                            tree.reader = Some(tree.plan.as_mut().unwrap().open(entry)?);
                        }
                        tree.ready = true;
                        job.touched = Instant::now();
                        return Ok(());
                    }
                    let Kind::Download(download) = &mut job.kind else {
                        bail!("Unexpected send confirmation");
                    };
                    if !job.approved || download.ready || r.file_num != 0 {
                        bail!("Unexpected send confirmation");
                    }
                    match r.union {
                        Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
                        | Some(file_transfer_send_confirm_request::Union::Skip(false)) => {
                            download.ready = true
                        }
                        Some(file_transfer_send_confirm_request::Union::Skip(true)) => {
                            self.finish(r.id, "skipped", "远端跳过了文件");
                            (self.send)(fs::new_done(r.id, 1))?;
                        }
                        _ => bail!("Resume is not supported for this transfer"),
                    }
                }
                _ => bail!("This file action is not supported by the native file owner"),
            },
            Some(message::Union::FileResponse(r)) => match r.union {
                Some(file_response::Union::Digest(d)) => self.start_upload(d.id, d)?,
                Some(file_response::Union::Block(b)) => self.block(b)?,
                Some(file_response::Union::Done(d)) => {
                    if matches!(self.jobs.get(&d.id).map(|j| &j.kind), Some(Kind::Tree(_))) {
                        let job = self.jobs.get_mut(&d.id).unwrap();
                        let Kind::Tree(tree) = &mut job.kind else {
                            unreachable!()
                        };
                        if !tree.awaiting_ack
                            || d.farpane_page != tree.page
                            || d.file_num != tree.entries.len() as i32
                        {
                            bail!("Unexpected directory completion acknowledgement");
                        }
                        if tree.more {
                            tree.page = tree.page.checked_add(1).ok_or_else(|| {
                                hbb_common::anyhow::anyhow!("Directory page counter exhausted")
                            })?;
                            tree.preparing = true;
                            tree.awaiting_ack = false;
                            tree.entries.clear();
                            job.touched = Instant::now();
                        } else {
                            let skipped = tree.skipped;
                            self.finish(
                                d.id,
                                if skipped == 0 {
                                    "completed"
                                } else {
                                    "completed_with_skips"
                                },
                                "远端已确认目录保存",
                            );
                        }
                        return Ok(());
                    }
                    let job = self
                        .jobs
                        .get(&d.id)
                        .ok_or_else(|| hbb_common::anyhow::anyhow!("Unknown upload completion"))?;
                    let Kind::Upload(upload) = &job.kind else {
                        bail!("Unexpected completion");
                    };
                    if !job.approved
                        || upload.active
                        || upload.next != upload.entries.len()
                        || d.file_num != upload.entries.len() as i32
                        || d.farpane_page != upload.page
                    {
                        bail!("Incomplete upload");
                    }
                    let more = upload.more;
                    let mut response = FileResponse::new();
                    response.set_done(d.clone());
                    let mut message = Message::new();
                    message.set_file_response(response);
                    (self.send)(message)?;
                    if more {
                        let job = self.jobs.get_mut(&d.id).unwrap();
                        let Kind::Upload(upload) = &mut job.kind else {
                            unreachable!()
                        };
                        upload.awaiting_batch = true;
                        upload.entries.clear();
                        files::update(
                            job.token,
                            job.done,
                            "receiving",
                            "等待下一批目录内容",
                            false,
                        );
                    } else {
                        self.finish(d.id, "completed", "文件已保存");
                    }
                }
                Some(file_response::Union::Error(e)) => {
                    self.finish(e.id, "failed", "远端报告文件传输失败")
                }
                _ => bail!("Unexpected file response"),
            },
            _ => bail!("Non-file message reached file worker"),
        }
        if let Some(job) = self.jobs.get_mut(&id) {
            job.touched = Instant::now();
        }
        Ok(())
    }
    fn advance(&mut self) -> ResultType<bool> {
        let mut activity = false;
        for id in self.jobs.keys().copied().collect::<Vec<_>>() {
            let result = (|| -> ResultType<bool> {
                let mut activity = false;
                let job = self.jobs.get_mut(&id).unwrap();
                // The storage owner retires a completed receive immediately. Keep
                // a separate wire deadline while awaiting the peer's final Done.
                if job.touched.elapsed() >= Duration::from_secs(if job.approved { 120 } else { 60 })
                {
                    self.finish(id, "timed_out", "文件传输已超时");
                    (self.send)(fs::new_error(id, "File task timed out", -1))?;
                    return Ok(activity);
                }
                if job.decision.cancel.load(Ordering::Acquire) {
                    self.finish(id, "cancelled", "本机取消了传输");
                    (self.send)(fs::new_error(id, "Transfer cancelled", -1))?;
                    return Ok(activity);
                }
                let choice = job.decision.choice.lock().unwrap().take();
                if let Some((accept, overwrite)) = choice {
                    if !accept {
                        self.finish(id, "rejected", "本机拒绝了传输");
                        (self.send)(fs::new_error(id, "Transfer rejected", -1))?;
                        return Ok(activity);
                    }
                    job.approved = true;
                    job.touched = Instant::now();
                    files::update(job.token, job.done, "transferring", "", false);
                    match &mut job.kind {
                        Kind::Upload(upload) => {
                            upload.overwrite = overwrite;
                            self.owner
                                .confirm_receive(job.key.unwrap(), true, overwrite)?;
                            if let Some(d) = upload.pending.take() {
                                self.start_upload(id, d)?;
                            }
                        }
                        Kind::Download(download) => {
                            self.owner.confirm_send(job.key.unwrap(), true)?;
                            (self.send)(fs::new_dir(
                                id,
                                download.name.clone(),
                                vec![FileEntry {
                                    entry_type: FileType::File.into(),
                                    name: String::new(),
                                    size: download.size,
                                    ..Default::default()
                                }],
                            ))?;
                            (self.send)(digest(id, 0, download.size, 0))?;
                        }
                        Kind::Tree(tree) => {
                            tree.plan = Some(Plan::shared_folder(self.root.clone(), &tree.path)?);
                        }
                    }
                }
                let Some(job) = self.jobs.get_mut(&id) else {
                    return Ok(activity);
                };
                if matches!(&job.kind, Kind::Tree(_)) && job.approved {
                    activity |= advance_tree(id, job, self.send)?;
                    return Ok(activity);
                }
                if matches!(&job.kind,Kind::Download(d) if d.ready) {
                    activity = true;
                    match self.owner.read(job.key.unwrap())? {
                        Read::Block(data) => {
                            job.done += data.len() as u64;
                            job.touched = Instant::now();
                            (self.send)(fs::new_block(FileTransferBlock {
                                id,
                                file_num: 0,
                                data: data.into(),
                                ..Default::default()
                            }))?;
                            files::update(job.token, job.done, "sending", "", false);
                        }
                        Read::End => {
                            (self.send)(fs::new_done(id, 1))?;
                            self.finish(id, "sent", "已发送；此协议未确认远端落盘");
                        }
                    }
                }
                Ok(activity)
            })();
            match result {
                Ok(active) => activity |= active,
                Err(error) => {
                    self.finish(id, "failed", &error.to_string());
                    (self.send)(fs::new_error(
                        id,
                        error.to_string().chars().take(256).collect::<String>(),
                        -1,
                    ))?;
                }
            }
        }
        for expired in self.owner.expire(Instant::now()) {
            if let Some(id) = self
                .jobs
                .iter()
                .find_map(|(id, j)| (j.key == Some(expired)).then_some(*id))
            {
                self.finish(id, "failed", "文件确认或传输已超时");
                (self.send)(fs::new_error(id, "File task timed out", -1))?;
            }
        }
        Ok(activity)
    }
}
fn advance_tree(
    id: i32,
    job: &mut Job,
    send: &dyn Fn(Message) -> ResultType<()>,
) -> ResultType<bool> {
    let Kind::Tree(tree) = &mut job.kind else {
        unreachable!()
    };
    if tree.preparing {
        let batch = match tree.plan.as_mut().unwrap().poll_batch()? {
            Poll::Pending => {
                job.touched = Instant::now();
                return Ok(true);
            }
            Poll::Ready(Some(batch)) => batch,
            Poll::Ready(None) => bail!("Missing final directory manifest"),
        };
        let total = batch
            .entries
            .iter()
            .try_fold(0u64, |sum, e| sum.checked_add(e.size))
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Directory size exceeds limit"))?;
        job.total = job
            .total
            .checked_add(total)
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Directory size exceeds limit"))?;
        tree.entries = batch.entries;
        tree.more = batch.more;
        tree.skipped = batch.skipped;
        tree.preparing = false;
        tree.index = 0;
        let mut response = FileResponse::new();
        response.set_dir(FileDirectory {
            id,
            path: format!("/{}", tree.path),
            entries: tree.entries.iter().map(wire_entry).collect(),
            farpane_tree: true,
            farpane_page: tree.page,
            farpane_more: tree.more,
            farpane_skipped: tree.skipped,
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_file_response(response);
        send(message)?;
        let entry = &tree.entries[0];
        send(digest(id, 0, entry.size, entry.modified))?;
        files::total(job.token, if tree.more { 0 } else { job.total });
        files::update(job.token, job.done, "sending", "", false);
        job.touched = Instant::now();
        return Ok(true);
    }
    if !tree.ready {
        return Ok(false);
    }
    let data = if tree.entries[tree.index].directory {
        Vec::new()
    } else {
        tree.reader
            .as_mut()
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Missing directory source"))?
            .read_block()?
    };
    if data.is_empty() {
        tree.ready = false;
        tree.reader = None;
        tree.index += 1;
        if tree.index == tree.entries.len() {
            tree.awaiting_ack = true;
            let mut response = FileResponse::new();
            response.set_done(FileTransferDone {
                id,
                file_num: tree.index as i32,
                farpane_page: tree.page,
                ..Default::default()
            });
            let mut message = Message::new();
            message.set_file_response(response);
            send(message)?;
        } else {
            let e = &tree.entries[tree.index];
            send(digest(id, tree.index as i32, e.size, e.modified))?;
        }
    } else {
        job.done += data.len() as u64;
        send(fs::new_block(FileTransferBlock {
            id,
            file_num: tree.index as i32,
            data: data.into(),
            ..Default::default()
        }))?;
        files::update(job.token, job.done, "sending", "", false);
    }
    job.touched = Instant::now();
    Ok(true)
}
pub fn run(
    connection: i32,
    path: &str,
    confirm: bool,
    receiver: mpsc::Receiver<Message>,
    valid: &dyn Fn() -> bool,
    send: &dyn Fn(Message) -> ResultType<()>,
) -> ResultType<()> {
    let generation = NEXT_OWNER
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |v| v.checked_add(1))
        .map_err(|_| hbb_common::anyhow::anyhow!("File generation exhausted"))?;
    let root = Arc::new(Root::open(Path::new(path))?);
    let owner = Owner::new(root.clone(), generation)?;
    let mut host = Host {
        connection,
        root,
        owner,
        generation,
        confirm,
        jobs: BTreeMap::new(),
        send,
    };
    while valid() {
        let busy = host.advance()?;
        match receiver.recv_timeout(if busy {
            Duration::ZERO
        } else {
            Duration::from_millis(20)
        }) {
            Ok(message) => {
                if !valid() {
                    break;
                }
                let id = message_id(&message);
                if let Err(error) = host.handle(message) {
                    host.finish(id, "failed", &error.to_string());
                    send(fs::new_error(
                        id,
                        error.to_string().chars().take(256).collect::<String>(),
                        -1,
                    ))?;
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    Ok(())
}
