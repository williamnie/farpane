struct BridgeShared {
    callbacks: RDNCallbacks,
    context: usize,
    active: AtomicBool,
    terminal_retry_allowed: AtomicBool,
    sequence: AtomicU64,
    dimensions: RwLock<(u32, u32)>,
    connection_epoch: AtomicU64,
    display_catalog: Mutex<NativeViewerDisplayCatalogState>,
    display_catalog_delivery: Mutex<()>,
    authenticated: AtomicBool,
    remote_keyboard_enabled: AtomicBool,
    remote_audio_enabled: AtomicBool,
    input_allowed: AtomicBool,
    receive_clipboard_text: AtomicBool,
    send_clipboard_text: AtomicBool,
    receive_clipboard_rich_text: AtomicBool,
    send_clipboard_rich_text: AtomicBool,
    receive_clipboard_image: AtomicBool,
    send_clipboard_image: AtomicBool,
    remote_clipboard_enabled: AtomicBool,
    remote_file_transfer_enabled: AtomicBool,
    file_transfer_enabled: AtomicBool,
    file_transfer_session_epoch: AtomicU64,
    pending_file_list_request: Mutex<Option<NativeViewerListRequest>>,
    file_manifest_request_epoch: AtomicU64,
    pending_file_manifest_request: Mutex<Option<NativeViewerManifestRequest>>,
    completed_file_manifest_request: Mutex<Option<NativeViewerCompletedManifest>>,
    active_file_download_jobs: Mutex<HashMap<i32, NativeViewerDownloadJob>>,
    active_file_upload_jobs: Mutex<HashMap<i32, NativeViewerUploadJob>>,
    file_upload_poll_cursor: AtomicU64,
}

impl BridgeShared {
    fn emit_file_transfer_ready_if_available(&self) {
        if self.active.load(Ordering::Acquire)
            && self.authenticated.load(Ordering::Acquire)
            && self.file_transfer_enabled.load(Ordering::Acquire)
            && self.remote_file_transfer_enabled.load(Ordering::Acquire)
        {
            self.emit_state(RDNState::Streaming, 0, "file-transfer-ready");
        }
    }

    fn read_file_transfer_upload_source(
        &self,
        transfer_id: i32,
        file_number: u32,
        offset: u64,
        length: usize,
    ) -> Option<Vec<u8>> {
        let job = self
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .get(&transfer_id)
            .cloned()?;
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != job.session_epoch
        {
            return None;
        }
        let callback = self.callbacks.on_file_transfer_upload_read?;
        let mut payload = job.read_source(callback, self.context, file_number, offset, length)?;
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != job.session_epoch
            || self
                .active_file_upload_jobs
                .lock()
                .unwrap()
                .get(&transfer_id)
                != Some(&job)
        {
            payload.fill(0);
            return None;
        }
        Some(payload)
    }

    fn file_transfer_upload_poll_interval_ms(&self) -> u64 {
        self.active_file_upload_jobs
            .lock()
            .unwrap()
            .values()
            .map(NativeViewerUploadJob::poll_interval_ms)
            .min()
            .unwrap_or(0)
    }

    fn file_transfer_upload_poll(&self) -> Option<Message> {
        let now = Instant::now();
        let cursor = self.file_upload_poll_cursor.load(Ordering::Acquire) as i32;
        let candidate = {
            let jobs = self.active_file_upload_jobs.lock().unwrap();
            let mut ids: Vec<_> = jobs.keys().copied().collect();
            ids.sort_unstable();
            let split = ids.iter().position(|id| *id > cursor).unwrap_or(0);
            ids.rotate_left(split);
            ids.into_iter().find_map(|id| {
                let job = jobs.get(&id)?;
                let ready = matches!(
                    job.stage,
                    NativeViewerUploadStage::ReadyDigest { .. }
                        | NativeViewerUploadStage::Sending { .. }
                        | NativeViewerUploadStage::ReadyDone
                );
                (ready || job.timed_out(now)).then(|| (id, job.clone()))
            })
        }?;
        self.file_upload_poll_cursor
            .store(candidate.0 as u64, Ordering::Release);
        let (transfer_id, snapshot) = candidate;

        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != snapshot.session_epoch
        {
            self.active_file_upload_jobs
                .lock()
                .unwrap()
                .remove(&transfer_id);
            return None;
        }
        if snapshot.timed_out(now) {
            let event = self
                .active_file_upload_jobs
                .lock()
                .unwrap()
                .remove(&transfer_id)
                .filter(|job| job == &snapshot)
                .and_then(|job| {
                    job.terminal(
                        FILE_TRANSFER_EVENT_FAILED,
                        FILE_TRANSFER_FAILURE_UNAVAILABLE,
                    )
                });
            if let Some(event) = event {
                self.emit_file_transfer_event(event);
                return Some(native_viewer_upload_cancel_message(transfer_id));
            }
            return None;
        }

        match snapshot.stage {
            NativeViewerUploadStage::ReadyDigest { file_number } => {
                let message = {
                    let mut jobs = self.active_file_upload_jobs.lock().unwrap();
                    let job = jobs.get_mut(&transfer_id)?;
                    if job != &snapshot {
                        return None;
                    }
                    job.next_digest_message(file_number)
                };
                message
            }
            NativeViewerUploadStage::ReadyDone => {
                let message = {
                    let mut jobs = self.active_file_upload_jobs.lock().unwrap();
                    let job = jobs.get_mut(&transfer_id)?;
                    if job != &snapshot {
                        return None;
                    }
                    job.next_done_message()
                };
                message
            }
            NativeViewerUploadStage::Sending {
                file_number,
                offset,
            } => {
                let file = snapshot.files.get(file_number as usize)?;
                if offset == file.size {
                    let event = {
                        let mut jobs = self.active_file_upload_jobs.lock().unwrap();
                        let job = jobs.get_mut(&transfer_id)?;
                        if job != &snapshot || !job.advance_file(file_number, false) {
                            return None;
                        }
                        job.progress_event(-1)
                    };
                    if let Some(event) = event {
                        self.emit_file_transfer_event(event);
                    }
                    return None;
                }
                let remaining = file.size.checked_sub(offset)?;
                let length = usize::try_from(
                    remaining.min(hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES as u64),
                )
                .ok()?;
                let Some(mut payload) =
                    self.read_file_transfer_upload_source(transfer_id, file_number, offset, length)
                else {
                    let event = self
                        .active_file_upload_jobs
                        .lock()
                        .unwrap()
                        .remove(&transfer_id)
                        .filter(|job| job == &snapshot)
                        .and_then(|job| {
                            job.terminal(FILE_TRANSFER_EVENT_FAILED, FILE_TRANSFER_FAILURE_LOCAL_IO)
                        });
                    if let Some(event) = event {
                        self.emit_file_transfer_event(event);
                        return Some(native_viewer_upload_cancel_message(transfer_id));
                    }
                    return None;
                };
                let encoded = hbb_common::compress::compress(&payload);
                let (mut data, compressed) = if encoded.len() < payload.len() {
                    payload.fill(0);
                    (encoded, true)
                } else {
                    (payload, false)
                };
                let next_offset = offset.checked_add(length as u64)?;
                let event = {
                    let mut jobs = self.active_file_upload_jobs.lock().unwrap();
                    let job = jobs.get_mut(&transfer_id)?;
                    if job != &snapshot || next_offset > file.size {
                        data.fill(0);
                        return None;
                    }
                    job.bytes_completed = job.bytes_completed.checked_add(length as u64)?;
                    if job.bytes_completed > job.total_bytes {
                        return None;
                    }
                    job.transition(NativeViewerUploadStage::Sending {
                        file_number,
                        offset: next_offset,
                    });
                    job.progress_event(file_number as i32)
                };
                if let Some(event) = event {
                    self.emit_file_transfer_event(event);
                }
                Some(hbb_common::fs::new_block(FileTransferBlock {
                    id: transfer_id,
                    file_num: file_number as i32,
                    data: data.into(),
                    compressed,
                    ..Default::default()
                }))
            }
            NativeViewerUploadStage::AwaitingCreate { .. }
            | NativeViewerUploadStage::AwaitingConfirmation { .. }
            | NativeViewerUploadStage::AwaitingDone => None,
        }
    }

    fn file_transfer_upload_confirmation(
        &self,
        request: &FileTransferSendConfirmRequest,
    ) -> (bool, Vec<Message>) {
        let mut event = None;
        let mut failed = false;
        {
            let mut jobs = self.active_file_upload_jobs.lock().unwrap();
            let Some(job) = jobs.get_mut(&request.id) else {
                return (false, Vec::new());
            };
            let NativeViewerUploadStage::AwaitingConfirmation { file_number } = job.stage else {
                drop(jobs);
                return self.fail_file_transfer_upload(
                    request.id,
                    FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                    true,
                );
            };
            if request.file_num != file_number as i32 {
                failed = true;
            } else {
                match request.union {
                    Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)) => {
                        let Some(file) = job.files.get(file_number as usize) else {
                            drop(jobs);
                            return self.fail_file_transfer_upload(
                                request.id,
                                FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                                true,
                            );
                        };
                        if file.size == 0 {
                            if !job.advance_file(file_number, false) {
                                failed = true;
                            } else {
                                event = job.progress_event(-1);
                            }
                        } else {
                            job.transition(NativeViewerUploadStage::Sending {
                                file_number,
                                offset: 0,
                            });
                        }
                    }
                    Some(file_transfer_send_confirm_request::Union::Skip(true)) => {
                        if !job.advance_file(file_number, true) {
                            failed = true;
                        } else {
                            event = job.progress_event(-1);
                        }
                    }
                    _ => failed = true,
                }
            }
        }
        if failed {
            return self.fail_file_transfer_upload(
                request.id,
                FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                true,
            );
        }
        if let Some(event) = event {
            self.emit_file_transfer_event(event);
        }
        (true, Vec::new())
    }

    fn file_transfer_upload_existing_target(
        &self,
        digest: &FileTransferDigest,
    ) -> (bool, Vec<Message>) {
        let mut event = None;
        let mut failed = false;
        {
            let mut jobs = self.active_file_upload_jobs.lock().unwrap();
            let Some(job) = jobs.get_mut(&digest.id) else {
                return (false, Vec::new());
            };
            let NativeViewerUploadStage::AwaitingConfirmation { file_number } = job.stage else {
                drop(jobs);
                return self.fail_file_transfer_upload(
                    digest.id,
                    FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                    true,
                );
            };
            if !digest.is_upload
                || digest.is_resume
                || digest.transferred_size != 0
                || digest.file_num != file_number as i32
                || !job.advance_file(file_number, true)
            {
                failed = true;
            } else {
                event = job.progress_event(-1);
            }
        }
        if failed {
            return self.fail_file_transfer_upload(
                digest.id,
                FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                true,
            );
        }
        if let Some(event) = event {
            self.emit_file_transfer_event(event);
        }
        let confirmation = FileTransferSendConfirmRequest {
            id: digest.id,
            file_num: digest.file_num,
            union: Some(file_transfer_send_confirm_request::Union::Skip(true)),
            ..Default::default()
        };
        (true, vec![hbb_common::fs::new_send_confirm(confirmation)])
    }

    fn file_transfer_upload_done(&self, done: &FileTransferDone) -> (bool, Vec<Message>) {
        let mut messages = Vec::new();
        let mut terminal = None;
        let mut failed = false;
        {
            let mut jobs = self.active_file_upload_jobs.lock().unwrap();
            let Some(job) = jobs.get_mut(&done.id) else {
                return (false, messages);
            };
            match job.stage {
                NativeViewerUploadStage::AwaitingCreate { directory_number }
                    if done.file_num == 0 =>
                {
                    let next = directory_number + 1;
                    if next < job.empty_directories.len() {
                        job.transition(NativeViewerUploadStage::AwaitingCreate {
                            directory_number: next,
                        });
                        if let Some(message) = native_viewer_upload_create_message(
                            job.transfer_id,
                            job.empty_directories[next].clone(),
                        ) {
                            messages.push(message);
                        } else {
                            failed = true;
                        }
                    } else if job.files.is_empty() {
                        let job = jobs
                            .remove(&done.id)
                            .expect("upload job remains registered");
                        terminal =
                            job.terminal(FILE_TRANSFER_EVENT_COMPLETED, FILE_TRANSFER_FAILURE_NONE);
                    } else {
                        job.transition(NativeViewerUploadStage::ReadyDigest { file_number: 0 });
                        if let Some(message) = native_viewer_upload_receive_message(job) {
                            messages.push(message);
                        } else {
                            failed = true;
                        }
                    }
                }
                NativeViewerUploadStage::AwaitingDone
                    if done.file_num == job.files.len() as i32 =>
                {
                    let job = jobs
                        .remove(&done.id)
                        .expect("upload job remains registered");
                    terminal =
                        job.terminal(FILE_TRANSFER_EVENT_COMPLETED, FILE_TRANSFER_FAILURE_NONE);
                }
                _ => failed = true,
            }
        }
        if failed {
            return self.fail_file_transfer_upload(
                done.id,
                FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION,
                true,
            );
        }
        if let Some(event) = terminal {
            self.emit_file_transfer_event(event);
        }
        (true, messages)
    }

    fn file_transfer_upload_error(&self, error: &FileTransferError) -> (bool, Vec<Message>) {
        if !self
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .contains_key(&error.id)
        {
            return (false, Vec::new());
        }
        self.fail_file_transfer_upload(error.id, FILE_TRANSFER_FAILURE_REJECTED, false)
    }

    fn fail_file_transfer_upload(
        &self,
        transfer_id: i32,
        failure: u32,
        send_cancel: bool,
    ) -> (bool, Vec<Message>) {
        let event = self
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .remove(&transfer_id)
            .and_then(|job| job.terminal(FILE_TRANSFER_EVENT_FAILED, failure));
        if let Some(event) = event {
            self.emit_file_transfer_event(event);
        }
        let messages = if send_cancel {
            vec![native_viewer_upload_cancel_message(transfer_id)]
        } else {
            Vec::new()
        };
        (true, messages)
    }

    fn emit_file_transfer_event(&self, event: NativeViewerDownloadEvent) {
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != event.session_epoch
        {
            return;
        }
        let Some(callback) = self.callbacks.on_file_transfer_event else {
            return;
        };
        let raw = RDNFileTransferEvent {
            abi_version: ABI_VERSION,
            session_epoch: event.session_epoch,
            transfer_id: event.transfer_id,
            sequence: event.sequence,
            kind: event.kind,
            failure: event.failure,
            current_file_number: event.current_file_number,
            files_completed: event.files_completed,
            total_files: event.total_files,
            bytes_completed: event.bytes_completed,
            total_bytes: event.total_bytes,
            bytes_per_second: event.bytes_per_second,
        };
        unsafe { callback(self.context as *mut c_void, &raw) };
    }

    fn emit_state(&self, state: RDNState, code: i32, message: &'static str) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        self.emit_state_unchecked(state, code, message);
    }

    fn emit_state_unchecked(&self, state: RDNState, code: i32, message: &'static str) {
        let Some(callback) = self.callbacks.on_state else {
            return;
        };
        let message = CString::new(message).expect("static bridge message contains no NUL");
        unsafe { callback(self.context as *mut c_void, state, code, message.as_ptr()) };
    }

    fn emit_remote_audio_permission(&self) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        let connection_epoch = self.connection_epoch.load(Ordering::Acquire);
        let Some(callback) = self.callbacks.on_remote_permission else {
            return;
        };
        let Some(event) = native_remote_audio_permission_event(
            connection_epoch,
            self.remote_audio_enabled.load(Ordering::Acquire),
        ) else { return };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn emit_metrics(&self, status: QualityStatus) {
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        let Some(callback) = self.callbacks.on_metrics else {
            return;
        };
        let metrics = RDNCoreMetrics {
            abi_version: ABI_VERSION,
            remote_fps: status.fps.values().copied().max().unwrap_or_default() as f64,
            network_delay_ms: status.delay.unwrap_or(-1),
            target_bitrate: status.target_bitrate.unwrap_or_default().max(0) as u64,
        };
        unsafe { callback(self.context as *mut c_void, &metrics) };
    }

    fn emit_clipboard_text(&self, text: &str) {
        if !clipboard_receive_allowed(
            self.active.load(Ordering::Acquire),
            self.authenticated.load(Ordering::Acquire),
            self.receive_clipboard_text.load(Ordering::Acquire),
            self.remote_clipboard_enabled.load(Ordering::Acquire),
        ) {
            return;
        }
        let Some(callback) = self.callbacks.on_clipboard_text else {
            return;
        };
        unsafe {
            callback(
                self.context as *mut c_void,
                text.as_bytes().as_ptr(),
                text.len(),
            )
        };
    }

    fn emit_clipboard_rich_text(&self, rich: NativeViewerRichTextBundle) {
        if !clipboard_receive_allowed(
            self.active.load(Ordering::Acquire),
            self.authenticated.load(Ordering::Acquire),
            self.receive_clipboard_rich_text.load(Ordering::Acquire),
            self.remote_clipboard_enabled.load(Ordering::Acquire),
        ) {
            return;
        }
        let Some(callback) = self.callbacks.on_clipboard_rich_text else {
            return;
        };
        let (plain_utf8, plain_length) = optional_string_bytes(&rich.plain_text);
        let (rtf_utf8, rtf_length) = optional_string_bytes(&rich.rtf);
        let (html_utf8, html_length) = optional_string_bytes(&rich.html);
        let payload = RDNClipboardRichTextPayload {
            abi_version: ABI_VERSION,
            plain_utf8,
            plain_length,
            rtf_utf8,
            rtf_length,
            html_utf8,
            html_length,
        };
        unsafe { callback(self.context as *mut c_void, &payload) };
    }

    fn emit_clipboard_image(&self, image: NativeViewerClipboardImage) {
        if !clipboard_receive_allowed(
            self.active.load(Ordering::Acquire),
            self.authenticated.load(Ordering::Acquire),
            self.receive_clipboard_image.load(Ordering::Acquire),
            self.remote_clipboard_enabled.load(Ordering::Acquire),
        ) {
            return;
        }
        let Some(callback) = self.callbacks.on_clipboard_image else {
            return;
        };
        let (format, width, height) = match image.kind {
            NativeViewerClipboardImageKind::Rgba { width, height } => {
                (CLIPBOARD_IMAGE_FORMAT_RGBA, width, height)
            }
            NativeViewerClipboardImageKind::Png => (CLIPBOARD_IMAGE_FORMAT_PNG, 0, 0),
            NativeViewerClipboardImageKind::Svg => (CLIPBOARD_IMAGE_FORMAT_SVG, 0, 0),
        };
        let payload = RDNClipboardImagePayload {
            abi_version: ABI_VERSION,
            format,
            data: image.payload.as_ptr(),
            length: image.payload.len(),
            width,
            height,
        };
        unsafe { callback(self.context as *mut c_void, &payload) };
    }

    fn emit_file_transfer_list(
        &self,
        request: NativeViewerListRequest,
        status: u32,
        listing: &[NativeViewerRemoteListEntry],
    ) {
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != request.session_epoch
        {
            return;
        }
        let Some(callback) = self.callbacks.on_file_transfer_list else {
            return;
        };
        let entries: Vec<_> = listing
            .iter()
            .map(|entry| RDNFileTransferListEntry {
                kind: match entry.kind {
                    NativeViewerRemoteListEntryKind::Directory => {
                        FILE_TRANSFER_LIST_ENTRY_DIRECTORY
                    }
                    NativeViewerRemoteListEntryKind::File => FILE_TRANSFER_LIST_ENTRY_FILE,
                },
                relative_path_utf8: entry.relative_path.as_bytes().as_ptr(),
                relative_path_length: entry.relative_path.len(),
                size: entry.size,
                modified_time: entry.modified_time,
            })
            .collect();
        let event = RDNFileTransferListEvent {
            abi_version: ABI_VERSION,
            session_epoch: request.session_epoch,
            request_id: request.request_id,
            status,
            entries: if entries.is_empty() {
                ptr::null()
            } else {
                entries.as_ptr()
            },
            entry_count: entries.len(),
        };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn emit_file_transfer_manifest(
        &self,
        request: NativeViewerManifestRequest,
        status: u32,
        part: u32,
        listing: &[NativeViewerRemoteListEntry],
    ) {
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != request.session_epoch
        {
            return;
        }
        let Some(callback) = self.callbacks.on_file_transfer_manifest else {
            return;
        };
        let entries: Vec<_> = listing
            .iter()
            .map(|entry| RDNFileTransferListEntry {
                kind: match entry.kind {
                    NativeViewerRemoteListEntryKind::Directory => {
                        FILE_TRANSFER_LIST_ENTRY_DIRECTORY
                    }
                    NativeViewerRemoteListEntryKind::File => FILE_TRANSFER_LIST_ENTRY_FILE,
                },
                relative_path_utf8: entry.relative_path.as_bytes().as_ptr(),
                relative_path_length: entry.relative_path.len(),
                size: entry.size,
                modified_time: entry.modified_time,
            })
            .collect();
        let event = RDNFileTransferManifestEvent {
            abi_version: ABI_VERSION,
            session_epoch: request.session_epoch,
            request_id: request.request_id,
            status,
            part,
            entries: if entries.is_empty() {
                ptr::null()
            } else {
                entries.as_ptr()
            },
            entry_count: entries.len(),
        };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn emit_file_transfer_receive_block(&self, block: &NativeViewerReceiveBlock) -> bool {
        if !self.active.load(Ordering::Acquire)
            || !self.authenticated.load(Ordering::Acquire)
            || !self.file_transfer_enabled.load(Ordering::Acquire)
            || block.session_epoch == 0
            || self.file_transfer_session_epoch.load(Ordering::Acquire) != block.session_epoch
            || block.transfer_id <= 0
            || block.file_number as usize >= MAX_FILE_TRANSFER_LIST_ENTRIES
            || block.payload.is_empty()
            || block.payload.len() > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES
        {
            return false;
        }
        let Some(callback) = self.callbacks.on_file_transfer_receive_block else {
            return false;
        };
        let raw = RDNFileTransferReceiveBlock {
            abi_version: ABI_VERSION,
            session_epoch: block.session_epoch,
            transfer_id: block.transfer_id,
            file_number: block.file_number,
            data: block.payload.as_ptr(),
            length: block.payload.len(),
        };
        unsafe { callback(self.context as *mut c_void, &raw) };
        true
    }

    fn emit_display_catalog(&self, snapshot: NativeViewerDisplayCatalogSnapshot) {
        let Some(callback) = self.callbacks.on_display_catalog else {
            return;
        };
        let raw_entries: Vec<RDNDisplayCatalogEntry> = snapshot
            .entries
            .as_deref()
            .unwrap_or(&[])
            .iter()
            .map(|entry| RDNDisplayCatalogEntry {
                display_index: entry.display_index,
                x: entry.x,
                y: entry.y,
                width: entry.width,
                height: entry.height,
                online: entry.online,
                scale: entry.scale,
                name_utf8: if entry.name.is_empty() {
                    ptr::null()
                } else {
                    entry.name.as_ptr()
                },
                name_length: entry.name.len(),
            })
            .collect();
        let event = RDNDisplayCatalogEvent {
            abi_version: ABI_VERSION,
            connection_epoch: snapshot.connection_epoch,
            catalog_revision: snapshot.revision,
            status: if snapshot.entries.is_some() {
                DISPLAY_CATALOG_STATUS_AVAILABLE
            } else {
                DISPLAY_CATALOG_STATUS_UNAVAILABLE
            },
            selected_display_index: snapshot
                .selected_display_index
                .unwrap_or(DISPLAY_INDEX_UNKNOWN),
            selected_display_known: snapshot.selected_display_index.is_some(),
            entries: if raw_entries.is_empty() {
                ptr::null()
            } else {
                raw_entries.as_ptr()
            },
            entry_count: raw_entries.len(),
        };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn emit_display_selection(&self, snapshot: NativeViewerDisplaySelectionSnapshot) {
        let Some(callback) = self.callbacks.on_display_selection else {
            return;
        };
        let event = RDNDisplaySelectionEvent {
            abi_version: ABI_VERSION,
            connection_epoch: snapshot.pending.connection_epoch,
            command_id: snapshot.pending.command_id,
            catalog_revision: snapshot.pending.catalog_revision,
            display_index: snapshot.pending.display_index,
            result: snapshot.result,
            failure: snapshot.failure,
        };
        unsafe { callback(self.context as *mut c_void, &event) };
    }

    fn publish_display_catalog(&self, displays: &[DisplayInfo], selected: Option<Option<u32>>) {
        if !self.active.load(Ordering::Acquire)
            || self.file_transfer_enabled.load(Ordering::Acquire)
        {
            return;
        }
        let connection_epoch = self.connection_epoch.load(Ordering::Acquire);
        if connection_epoch == 0 {
            return;
        }
        let delivery = self.display_catalog_delivery.lock().unwrap();
        let normalized = normalized_native_viewer_display_catalog(displays).map(Arc::from);
        let mut state = self.display_catalog.lock().unwrap();
        let catalog_changed =
            !state.initialized || state.entries.as_deref() != normalized.as_deref();
        let selection_terminal = catalog_changed
            .then(|| {
                state
                    .pending_selection
                    .take()
                    .map(|pending| NativeViewerDisplaySelectionSnapshot {
                        pending,
                        result: DISPLAY_SELECTION_RESULT_FAILED,
                        failure: DISPLAY_SELECTION_FAILURE_CATALOG_CHANGED,
                    })
            })
            .flatten();
        if catalog_changed {
            state.initialized = true;
            state.revision = state.revision.saturating_add(1).max(1);
            state.entries = normalized;
        }
        let candidate = selected.unwrap_or(state.selected_display_index);
        let validated = state.entries.as_deref().and_then(|entries| {
            candidate.and_then(|index| {
                entries
                    .get(index as usize)
                    .filter(|entry| entry.display_index == index && entry.online)
                    .map(|_| index)
            })
        });
        let selection_changed = state.selected_display_index != validated;
        state.selected_display_index = validated;
        if !catalog_changed && !selection_changed {
            return;
        }
        let snapshot = NativeViewerDisplayCatalogSnapshot {
            connection_epoch,
            revision: state.revision,
            entries: state.entries.clone(),
            selected_display_index: state.selected_display_index,
        };
        drop(state);
        if let Some(terminal) = selection_terminal {
            self.emit_display_selection(terminal);
        }
        self.emit_display_catalog(snapshot);
        drop(delivery);
    }

    fn publish_selected_display(&self, display: i32, ingress: NativeViewerDisplaySelectionIngress) {
        if !self.active.load(Ordering::Acquire)
            || self.file_transfer_enabled.load(Ordering::Acquire)
        {
            return;
        }
        let connection_epoch = self.connection_epoch.load(Ordering::Acquire);
        if connection_epoch == 0 {
            return;
        }
        let delivery = self.display_catalog_delivery.lock().unwrap();
        let mut state = self.display_catalog.lock().unwrap();
        if !state.initialized {
            return;
        }
        let index = u32::try_from(display).ok();
        let valid_index = index.filter(|index| {
            state.entries.as_deref().is_some_and(|entries| {
                entries
                    .get(*index as usize)
                    .is_some_and(|entry| entry.display_index == *index && entry.online)
            })
        });
        let terminal = state.pending_selection.take().map(|pending| {
            let selected = matches!(ingress, NativeViewerDisplaySelectionIngress::SwitchEcho)
                && valid_index == Some(pending.display_index)
                && pending.connection_epoch == connection_epoch
                && pending.catalog_revision == state.revision;
            NativeViewerDisplaySelectionSnapshot {
                pending,
                result: if selected {
                    DISPLAY_SELECTION_RESULT_SELECTED
                } else {
                    DISPLAY_SELECTION_RESULT_FAILED
                },
                failure: if selected {
                    DISPLAY_SELECTION_FAILURE_NONE
                } else {
                    DISPLAY_SELECTION_FAILURE_REMOTE_SELECTION_DRIFT
                },
            }
        });
        let catalog_snapshot =
            if valid_index.is_some() && state.selected_display_index != valid_index {
                state.selected_display_index = valid_index;
                Some(NativeViewerDisplayCatalogSnapshot {
                    connection_epoch,
                    revision: state.revision,
                    entries: state.entries.clone(),
                    selected_display_index: state.selected_display_index,
                })
            } else {
                None
            };
        drop(state);
        if let Some(snapshot) = catalog_snapshot {
            self.emit_display_catalog(snapshot);
        }
        if let Some(terminal) = terminal {
            self.emit_display_selection(terminal);
        }
        drop(delivery);
    }

    fn terminate_display_selection(&self, failure: u32) {
        let delivery = self.display_catalog_delivery.lock().unwrap();
        let terminal = self
            .display_catalog
            .lock()
            .unwrap()
            .pending_selection
            .take()
            .map(|pending| NativeViewerDisplaySelectionSnapshot {
                pending,
                result: DISPLAY_SELECTION_RESULT_FAILED,
                failure,
            });
        if let Some(terminal) = terminal {
            self.emit_display_selection(terminal);
        }
        drop(delivery);
    }

    fn video_catalog_binding(&self, display: u32) -> Option<(u64, u64)> {
        if !self.active.load(Ordering::Acquire)
            || self.file_transfer_enabled.load(Ordering::Acquire)
        {
            return None;
        }
        let connection_epoch = self.connection_epoch.load(Ordering::Acquire);
        let state = self.display_catalog.lock().unwrap();
        (connection_epoch > 0
            && state.initialized
            && state.revision > 0
            && state.entries.is_some()
            && state.selected_display_index == Some(display))
        .then_some((connection_epoch, state.revision))
    }

    fn emit_video(&self, frame: &VideoFrame) -> bool {
        if !self.active.load(Ordering::Acquire) {
            return true;
        }
        let Some(callback) = self.callbacks.on_video else {
            return false;
        };
        let (codec, encoded_frames) = match frame.union.as_ref() {
            Some(video_frame::Union::H265s(frames)) => (RDNCodec::H265, frames),
            Some(video_frame::Union::H264s(frames)) => (RDNCodec::H264, frames),
            _ => return false,
        };
        let (width, height) = *self.dimensions.read().unwrap();
        let display = frame.display.max(0) as u32;
        let Some((connection_epoch, display_catalog_revision)) =
            self.video_catalog_binding(display)
        else {
            return true;
        };
        for encoded in encoded_frames.frames.iter() {
            let inspection = inspect_packet(&encoded.data);
            let mut flags = inspection.flags;
            if encoded.key {
                flags |= FLAG_KEYFRAME;
            }
            let packet = RDNEncodedVideoFrame {
                abi_version: ABI_VERSION,
                codec,
                packet_format: inspection.format,
                data: encoded.data.as_ptr(),
                length: encoded.data.len(),
                sequence: self.sequence.fetch_add(1, Ordering::Relaxed),
                timestamp_us: encoded.pts.max(0) as u64 * 1_000,
                flags,
                width,
                height,
                display,
                connection_epoch,
                display_catalog_revision,
            };
            // encoded.data is owned by the protobuf frame and remains valid only
            // for this synchronous callback. The Swift side copies compressed bytes.
            unsafe { callback(self.context as *mut c_void, &packet) };
        }
        true
    }
}
