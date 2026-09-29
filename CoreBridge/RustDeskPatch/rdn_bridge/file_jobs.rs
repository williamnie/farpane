#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeViewerRemoteListEntryKind {
    Directory,
    File,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerRemoteListEntry {
    kind: NativeViewerRemoteListEntryKind,
    relative_path: String,
    size: u64,
    modified_time: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct NativeViewerListRequest {
    session_epoch: u64,
    request_id: i32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerManifestRequest {
    session_epoch: u64,
    request_id: i32,
    files_delivered: bool,
    empty_directories_delivered: bool,
    total_files: Option<u32>,
    total_bytes: Option<u64>,
    files: Option<Vec<NativeViewerManifestFileAuthority>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct NativeViewerManifestFileAuthority {
    size: u64,
    modified_time: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerCompletedManifest {
    session_epoch: u64,
    request_id: i32,
    total_files: u32,
    total_bytes: u64,
    files: Arc<[NativeViewerManifestFileAuthority]>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerUploadFileAuthority {
    relative_path: String,
    size: u64,
    modified_time: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerUploadJob {
    session_epoch: u64,
    transfer_id: i32,
    source_token: u64,
    files: Arc<[NativeViewerUploadFileAuthority]>,
    empty_directories: Arc<[String]>,
    total_bytes: u64,
    stage: NativeViewerUploadStage,
    stage_started: Instant,
    sequence: u64,
    files_completed: u32,
    bytes_completed: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeViewerUploadStage {
    AwaitingCreate { directory_number: usize },
    ReadyDigest { file_number: u32 },
    AwaitingConfirmation { file_number: u32 },
    Sending { file_number: u32, offset: u64 },
    ReadyDone,
    AwaitingDone,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeViewerDownloadJob {
    session_epoch: u64,
    manifest_request_id: i32,
    transfer_id: i32,
    total_files: u32,
    total_bytes: u64,
    manifest_files: Arc<[NativeViewerManifestFileAuthority]>,
    next_digest_file_number: u32,
    sequence: u64,
    files_completed: u32,
    bytes_completed: u64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct NativeViewerDownloadEvent {
    session_epoch: u64,
    transfer_id: i32,
    sequence: u64,
    kind: u32,
    failure: u32,
    current_file_number: i32,
    files_completed: u32,
    total_files: u32,
    bytes_completed: u64,
    total_bytes: u64,
    bytes_per_second: f64,
}

#[derive(Debug, Eq, PartialEq)]
struct NativeViewerReceiveBlock {
    session_epoch: u64,
    transfer_id: i32,
    file_number: u32,
    payload: Vec<u8>,
}

impl NativeViewerDownloadJob {
    fn confirm_digest(
        &mut self,
        digest: &FileTransferDigest,
    ) -> Option<FileTransferSendConfirmRequest> {
        if digest.id != self.transfer_id
            || digest.is_upload
            || digest.is_resume
            || digest.is_identical
            || digest.transferred_size != 0
        {
            return None;
        }
        let file_number = u32::try_from(digest.file_num).ok()?;
        if file_number != self.next_digest_file_number {
            return None;
        }
        let authority = self.manifest_files.get(file_number as usize)?;
        if digest.file_size != authority.size || digest.last_modified != authority.modified_time {
            return None;
        }
        self.next_digest_file_number = file_number.checked_add(1)?;
        Some(FileTransferSendConfirmRequest {
            id: self.transfer_id,
            file_num: digest.file_num,
            union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
            ..Default::default()
        })
    }

    fn receive_block(&self, block: &FileTransferBlock) -> Option<NativeViewerReceiveBlock> {
        if block.id != self.transfer_id
            || block.data.is_empty()
            || block.data.len() > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES
        {
            return None;
        }
        let file_number = u32::try_from(block.file_num).ok()?;
        if file_number >= self.total_files || file_number >= self.next_digest_file_number {
            return None;
        }
        let payload = if block.compressed {
            hbb_common::compress::decompress_with_limit(
                &block.data,
                hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES,
            )
            .ok()?
        } else {
            block.data.to_vec()
        };
        if payload.is_empty() || payload.len() > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES {
            return None;
        }
        Some(NativeViewerReceiveBlock {
            session_epoch: self.session_epoch,
            transfer_id: self.transfer_id,
            file_number,
            payload,
        })
    }

    fn progress(
        &mut self,
        completed_file_number: i32,
        bytes_per_second: f64,
        finished_size: f64,
    ) -> Option<NativeViewerDownloadEvent> {
        if completed_file_number < -1
            || !bytes_per_second.is_finite()
            || bytes_per_second < 0.0
            || !finished_size.is_finite()
            || finished_size < 0.0
            || finished_size.fract() != 0.0
            || finished_size > self.total_bytes as f64
        {
            return None;
        }
        let files_completed = u32::try_from(completed_file_number.checked_add(1)?).ok()?;
        let bytes_completed = finished_size as u64;
        if files_completed > self.total_files
            || files_completed < self.files_completed
            || bytes_completed > self.total_bytes
            || bytes_completed < self.bytes_completed
        {
            return None;
        }
        let sequence = self.sequence.checked_add(1)?;
        self.sequence = sequence;
        self.files_completed = files_completed;
        self.bytes_completed = bytes_completed;
        Some(self.event(
            sequence,
            FILE_TRANSFER_EVENT_PROGRESS,
            FILE_TRANSFER_FAILURE_NONE,
            if files_completed < self.total_files {
                files_completed as i32
            } else {
                -1
            },
            files_completed,
            bytes_completed,
            bytes_per_second,
        ))
    }

    fn terminal(self, kind: u32, failure: u32) -> Option<NativeViewerDownloadEvent> {
        let sequence = self.sequence.checked_add(1)?;
        let (files_completed, bytes_completed) = if kind == FILE_TRANSFER_EVENT_COMPLETED {
            (self.total_files, self.total_bytes)
        } else {
            (self.files_completed, self.bytes_completed)
        };
        Some(self.event(
            sequence,
            kind,
            failure,
            -1,
            files_completed,
            bytes_completed,
            0.0,
        ))
    }

    fn event(
        &self,
        sequence: u64,
        kind: u32,
        failure: u32,
        current_file_number: i32,
        files_completed: u32,
        bytes_completed: u64,
        bytes_per_second: f64,
    ) -> NativeViewerDownloadEvent {
        NativeViewerDownloadEvent {
            session_epoch: self.session_epoch,
            transfer_id: self.transfer_id,
            sequence,
            kind,
            failure,
            current_file_number,
            files_completed,
            total_files: self.total_files,
            bytes_completed,
            total_bytes: self.total_bytes,
            bytes_per_second,
        }
    }
}

impl NativeViewerUploadJob {
    fn poll_interval_ms(&self) -> u64 {
        match self.stage {
            NativeViewerUploadStage::ReadyDigest { .. }
            | NativeViewerUploadStage::Sending { .. }
            | NativeViewerUploadStage::ReadyDone => VIEWER_UPLOAD_ACTIVE_POLL_INTERVAL_MS,
            NativeViewerUploadStage::AwaitingCreate { .. }
            | NativeViewerUploadStage::AwaitingConfirmation { .. }
            | NativeViewerUploadStage::AwaitingDone => VIEWER_UPLOAD_WAITING_POLL_INTERVAL_MS,
        }
    }

    fn timed_out(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.stage_started) >= VIEWER_UPLOAD_WIRE_TIMEOUT
    }

    fn transition(&mut self, stage: NativeViewerUploadStage) {
        self.stage = stage;
        self.stage_started = Instant::now();
    }

    fn initial_message(&self) -> Option<Message> {
        match self.stage {
            NativeViewerUploadStage::AwaitingCreate {
                directory_number: 0,
            } => native_viewer_upload_create_message(
                self.transfer_id,
                self.empty_directories.first()?.clone(),
            ),
            NativeViewerUploadStage::ReadyDigest { file_number: 0 } => {
                native_viewer_upload_receive_message(self)
            }
            _ => None,
        }
    }

    fn next_digest_message(&mut self, file_number: u32) -> Option<Message> {
        let file = self.files.get(file_number as usize)?;
        let message = native_viewer_upload_digest_message(
            self.transfer_id,
            file_number,
            file.size,
            file.modified_time,
        );
        self.transition(NativeViewerUploadStage::AwaitingConfirmation { file_number });
        Some(message)
    }

    fn next_done_message(&mut self) -> Option<Message> {
        let file_number = i32::try_from(self.files.len()).ok()?;
        self.transition(NativeViewerUploadStage::AwaitingDone);
        Some(hbb_common::fs::new_done(self.transfer_id, file_number))
    }

    fn advance_file(&mut self, file_number: u32, count_remaining_bytes: bool) -> bool {
        let Some(file) = self.files.get(file_number as usize) else {
            return false;
        };
        if count_remaining_bytes {
            let Some(bytes_completed) = self.bytes_completed.checked_add(file.size) else {
                return false;
            };
            if bytes_completed > self.total_bytes {
                return false;
            }
            self.bytes_completed = bytes_completed;
        }
        let Some(files_completed) = self.files_completed.checked_add(1) else {
            return false;
        };
        if files_completed as usize > self.files.len() {
            return false;
        }
        self.files_completed = files_completed;
        if files_completed as usize == self.files.len() {
            self.transition(NativeViewerUploadStage::ReadyDone);
        } else {
            self.transition(NativeViewerUploadStage::ReadyDigest {
                file_number: files_completed,
            });
        }
        true
    }

    fn progress_event(&mut self, current_file_number: i32) -> Option<NativeViewerDownloadEvent> {
        let sequence = self.sequence.checked_add(1)?;
        self.sequence = sequence;
        Some(self.event(
            sequence,
            FILE_TRANSFER_EVENT_PROGRESS,
            FILE_TRANSFER_FAILURE_NONE,
            current_file_number,
            self.files_completed,
            self.bytes_completed,
        ))
    }

    fn read_source(
        &self,
        callback: FileTransferUploadReadCallback,
        context: usize,
        file_number: u32,
        offset: u64,
        length: usize,
    ) -> Option<Vec<u8>> {
        if length == 0 || length > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES {
            return None;
        }
        let file = self.files.get(file_number as usize)?;
        let end = offset.checked_add(length as u64)?;
        if offset >= file.size || end > file.size {
            return None;
        }
        let mut payload = vec![0; length];
        let request = RDNFileTransferUploadReadRequest {
            abi_version: ABI_VERSION,
            session_epoch: self.session_epoch,
            transfer_id: self.transfer_id,
            source_token: self.source_token,
            file_number,
            offset,
            buffer: payload.as_mut_ptr(),
            length,
        };
        let mut bytes_written = 0usize;
        let result = unsafe { callback(context as *mut c_void, &request, &mut bytes_written) };
        if result != 0 || bytes_written != length {
            payload.fill(0);
            return None;
        }
        Some(payload)
    }

    fn terminal(self, kind: u32, failure: u32) -> Option<NativeViewerDownloadEvent> {
        let sequence = self.sequence.checked_add(1)?;
        let (files_completed, bytes_completed) = if kind == FILE_TRANSFER_EVENT_COMPLETED {
            (u32::try_from(self.files.len()).ok()?, self.total_bytes)
        } else {
            (self.files_completed, self.bytes_completed)
        };
        Some(self.event(
            sequence,
            kind,
            failure,
            -1,
            files_completed,
            bytes_completed,
        ))
    }

    fn event(
        &self,
        sequence: u64,
        kind: u32,
        failure: u32,
        current_file_number: i32,
        files_completed: u32,
        bytes_completed: u64,
    ) -> NativeViewerDownloadEvent {
        NativeViewerDownloadEvent {
            session_epoch: self.session_epoch,
            transfer_id: self.transfer_id,
            sequence,
            kind,
            failure,
            current_file_number,
            files_completed,
            total_files: self.files.len() as u32,
            bytes_completed,
            total_bytes: self.total_bytes,
            bytes_per_second: 0.0,
        }
    }
}

fn native_viewer_upload_create_message(transfer_id: i32, path: String) -> Option<Message> {
    if transfer_id <= 0 || path.is_empty() {
        return None;
    }
    let mut action = FileAction::new();
    action.set_create(FileDirCreate {
        id: transfer_id,
        path,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_file_action(action);
    Some(message)
}

fn native_viewer_upload_receive_message(job: &NativeViewerUploadJob) -> Option<Message> {
    if job.files.is_empty() {
        return None;
    }
    let files = job
        .files
        .iter()
        .map(|file| FileEntry {
            entry_type: FileType::File.into(),
            name: file.relative_path.clone(),
            size: file.size,
            modified_time: file.modified_time,
            ..Default::default()
        })
        .collect();
    Some(hbb_common::fs::new_receive(
        job.transfer_id,
        String::new(),
        0,
        files,
        job.total_bytes,
    ))
}

fn native_viewer_upload_digest_message(
    transfer_id: i32,
    file_number: u32,
    file_size: u64,
    modified_time: u64,
) -> Message {
    let mut response = FileResponse::new();
    response.set_digest(FileTransferDigest {
        id: transfer_id,
        file_num: i32::try_from(file_number).unwrap_or(-1),
        last_modified: modified_time,
        file_size,
        is_resume: false,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_file_response(response);
    message
}

fn native_viewer_upload_cancel_message(transfer_id: i32) -> Message {
    let mut action = FileAction::new();
    action.set_cancel(FileTransferCancel {
        id: transfer_id,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_file_action(action);
    message
}
