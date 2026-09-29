#[derive(Clone)]
struct BridgeUi {
    shared: Arc<BridgeShared>,
}

impl Default for BridgeUi {
    fn default() -> Self {
        Self {
            shared: Arc::new(BridgeShared {
                callbacks: RDNCallbacks {
                    abi_version: ABI_VERSION,
                    on_state: None,
                    on_remote_permission: None,
                    on_video: None,
                    on_display_catalog: None,
                    on_display_selection: None,
                    on_metrics: None,
                    on_clipboard_text: None,
                    on_clipboard_rich_text: None,
                    on_clipboard_image: None,
                    on_file_transfer_event: None,
                    on_file_transfer_list: None,
                    on_file_transfer_manifest: None,
                    on_file_transfer_receive_block: None,
                    on_file_transfer_upload_read: None,
                },
                context: 0,
                active: AtomicBool::new(false),
                terminal_retry_allowed: AtomicBool::new(true),
                sequence: AtomicU64::new(0),
                dimensions: RwLock::new((0, 0)),
                connection_epoch: AtomicU64::new(0),
                display_catalog: Mutex::new(NativeViewerDisplayCatalogState::default()),
                display_catalog_delivery: Mutex::new(()),
                authenticated: AtomicBool::new(false),
                remote_keyboard_enabled: AtomicBool::new(true),
                remote_audio_enabled: AtomicBool::new(true),
                input_allowed: AtomicBool::new(false),
                receive_clipboard_text: AtomicBool::new(false),
                send_clipboard_text: AtomicBool::new(false),
                receive_clipboard_rich_text: AtomicBool::new(false),
                send_clipboard_rich_text: AtomicBool::new(false),
                receive_clipboard_image: AtomicBool::new(false),
                send_clipboard_image: AtomicBool::new(false),
                remote_clipboard_enabled: AtomicBool::new(REMOTE_CLIPBOARD_ENABLED_BY_DEFAULT),
                remote_file_transfer_enabled: AtomicBool::new(false),
                file_transfer_enabled: AtomicBool::new(false),
                file_transfer_session_epoch: AtomicU64::new(0),
                pending_file_list_request: Mutex::new(None),
                file_manifest_request_epoch: AtomicU64::new(0),
                pending_file_manifest_request: Mutex::new(None),
                completed_file_manifest_request: Mutex::new(None),
                active_file_download_jobs: Mutex::new(HashMap::new()),
                active_file_upload_jobs: Mutex::new(HashMap::new()),
                file_upload_poll_cursor: AtomicU64::new(0),
            }),
        }
    }
}

fn viewer_terminal_error_state(text: &str, retry: bool) -> (i32, &'static str) {
    if !retry {
        return (TERMINAL_NO_RETRY_CODE, "connection-no-retry");
    }
    let lower = text.to_ascii_lowercase();
    if lower == "timeout" {
        (10, "connection-timeout")
    } else if lower.contains("reset by the peer") || lower.contains("connection reset") {
        (11, "connection-reset")
    } else if lower.contains("deadline") {
        (12, "connection-deadline")
    } else if lower.contains("broken pipe") {
        (13, "connection-broken-pipe")
    } else if lower.contains("closed") || lower.contains("eof") {
        (14, "connection-closed")
    } else {
        (3, "rustdesk-session-error")
    }
}

impl InvokeUiSession for BridgeUi {
    fn set_cursor_data(&self, _value: CursorData) {}
    fn set_cursor_id(&self, _value: String) {}
    fn set_cursor_position(&self, _value: CursorPosition) {}

    fn set_display(
        &self,
        _x: i32,
        _y: i32,
        width: i32,
        height: i32,
        _cursor_embedded: bool,
        _scale: f64,
    ) {
        *self.shared.dimensions.write().unwrap() = (width.max(0) as u32, height.max(0) as u32);
    }

    fn switch_display(&self, display: &SwitchDisplay) {
        *self.shared.dimensions.write().unwrap() =
            (display.width.max(0) as u32, display.height.max(0) as u32);
        self.shared.publish_selected_display(
            display.display,
            NativeViewerDisplaySelectionIngress::SwitchEcho,
        );
    }

    fn set_peer_info(&self, peer_info: &PeerInfo) {
        let selected = u32::try_from(peer_info.current_display).ok();
        self.shared
            .publish_display_catalog(&peer_info.displays, Some(selected));
    }
    fn set_displays(&self, displays: &Vec<DisplayInfo>) {
        self.shared.publish_display_catalog(displays, None);
    }
    fn set_platform_additions(&self, _data: &str) {}

    fn on_connected(&self, _conn_type: ConnType) {
        self.shared.authenticated.store(true, Ordering::Release);
        self.shared.emit_remote_audio_permission();
        let file_transfer = self.shared.file_transfer_enabled.load(Ordering::Acquire);
        let allowed = !file_transfer
            && input_is_allowed(
                true,
                self.shared.remote_keyboard_enabled.load(Ordering::Acquire),
            );
        self.shared.input_allowed.store(allowed, Ordering::Release);
        self.shared
            .emit_state(RDNState::Authenticated, 0, "authenticated");
        if file_transfer {
            self.shared.emit_file_transfer_ready_if_available();
        } else if allowed {
            self.shared
                .emit_state(RDNState::ControlReady, 0, "control-ready");
        }
    }

    fn update_privacy_mode(&self) {}
    fn set_permission(&self, name: &str, value: bool) {
        if name == "keyboard" {
            self.shared
                .remote_keyboard_enabled
                .store(value, Ordering::Release);
            let allowed = !self.shared.file_transfer_enabled.load(Ordering::Acquire)
                && input_is_allowed(self.shared.authenticated.load(Ordering::Acquire), value);
            self.shared.input_allowed.store(allowed, Ordering::Release);
            if allowed {
                self.shared
                    .emit_state(RDNState::ControlReady, 0, "control-ready");
            }
        } else if name == "clipboard" {
            self.shared
                .remote_clipboard_enabled
                .store(value, Ordering::Release);
        } else if name == "audio" {
            self.shared
                .remote_audio_enabled
                .store(value, Ordering::Release);
            self.shared.emit_remote_audio_permission();
        } else if name == "file" {
            let changed = self
                .shared
                .remote_file_transfer_enabled
                .swap(value, Ordering::AcqRel)
                != value;
            if value && changed {
                self.shared.emit_file_transfer_ready_if_available();
            }
        }
    }

    fn close_success(&self) {
        if !self.shared.file_transfer_enabled.load(Ordering::Acquire) {
            self.shared.emit_state(RDNState::Streaming, 0, "streaming");
        }
    }

    fn update_quality_status(&self, status: QualityStatus) {
        self.shared.emit_metrics(status);
    }

    fn set_connection_type(&self, secured: bool, direct: bool, _stream_type: &str) {
        let code = i32::from(secured) | (i32::from(direct) << 1);
        let message = match (secured, direct) {
            (true, true) => "transport-ready-secure-direct",
            (true, false) => "transport-ready-secure-relay",
            (false, true) => "transport-ready-insecure-direct",
            (false, false) => "transport-ready-insecure-relay",
        };
        self.shared
            .emit_state(RDNState::TransportReady, code, message);
    }

    fn set_fingerprint(&self, _fingerprint: String) {}
    fn job_error(&self, id: i32, _error: String, _file_num: i32) {
        let request = if id == 0 {
            self.shared.pending_file_list_request.lock().unwrap().take()
        } else {
            None
        };
        if let Some(request) = request {
            self.shared
                .emit_file_transfer_list(request, FILE_TRANSFER_LIST_UNAVAILABLE, &[]);
        }
        let manifest_request = {
            let mut pending = self.shared.pending_file_manifest_request.lock().unwrap();
            if pending
                .as_ref()
                .is_some_and(|request| id == 0 || request.request_id == id)
            {
                pending.take()
            } else {
                None
            }
        };
        if let Some(request) = manifest_request {
            client_clear_completed_manifest(&self.shared, request.session_epoch);
            self.shared.emit_file_transfer_manifest(
                request,
                FILE_TRANSFER_LIST_UNAVAILABLE,
                FILE_TRANSFER_MANIFEST_PART_FILES,
                &[],
            );
        }
        let event = self
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .remove(&id)
            .and_then(|job| {
                job.terminal(
                    FILE_TRANSFER_EVENT_FAILED,
                    FILE_TRANSFER_FAILURE_UNAVAILABLE,
                )
            });
        if let Some(event) = event {
            self.shared.emit_file_transfer_event(event);
        }
    }
    fn job_done(&self, id: i32, _file_num: i32) {
        let event = self
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .remove(&id)
            .and_then(|job| {
                job.terminal(FILE_TRANSFER_EVENT_COMPLETED, FILE_TRANSFER_FAILURE_NONE)
            });
        if let Some(event) = event {
            self.shared.emit_file_transfer_event(event);
        }
    }
    fn clear_all_jobs(&self) {
        self.shared.pending_file_list_request.lock().unwrap().take();
        self.shared
            .pending_file_manifest_request
            .lock()
            .unwrap()
            .take();
        self.shared
            .completed_file_manifest_request
            .lock()
            .unwrap()
            .take();
        self.shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .clear();
        self.shared.active_file_upload_jobs.lock().unwrap().clear();
    }
    fn new_message(&self, _message: String) {}
    fn update_transfer_list(&self) {}
    fn load_last_job(&self, _count: i32, _json: &str, _auto_start: bool) {}

    fn update_folder_files(
        &self,
        id: i32,
        entries: &Vec<FileEntry>,
        path: String,
        is_local: bool,
        only_count: bool,
    ) {
        if id > 0 {
            let request = {
                let pending = self.shared.pending_file_manifest_request.lock().unwrap();
                pending
                    .as_ref()
                    .filter(|request| request.request_id == id)
                    .cloned()
            };
            let Some(request) = request else { return };
            if is_local || only_count || path != "/" {
                self.shared
                    .pending_file_manifest_request
                    .lock()
                    .unwrap()
                    .take();
                client_clear_completed_manifest(&self.shared, request.session_epoch);
                self.shared.emit_file_transfer_manifest(
                    request,
                    FILE_TRANSFER_LIST_REJECTED,
                    FILE_TRANSFER_MANIFEST_PART_FILES,
                    &[],
                );
                return;
            }
            let Some(listing) = native_viewer_remote_manifest_files(entries) else {
                self.shared
                    .pending_file_manifest_request
                    .lock()
                    .unwrap()
                    .take();
                client_clear_completed_manifest(&self.shared, request.session_epoch);
                self.shared.emit_file_transfer_manifest(
                    request,
                    FILE_TRANSFER_LIST_REJECTED,
                    FILE_TRANSFER_MANIFEST_PART_FILES,
                    &[],
                );
                return;
            };
            let Some(total_bytes) = listing
                .iter()
                .try_fold(0u64, |total, entry| total.checked_add(entry.size))
            else {
                self.shared
                    .pending_file_manifest_request
                    .lock()
                    .unwrap()
                    .take();
                client_clear_completed_manifest(&self.shared, request.session_epoch);
                self.shared.emit_file_transfer_manifest(
                    request,
                    FILE_TRANSFER_LIST_REJECTED,
                    FILE_TRANSFER_MANIFEST_PART_FILES,
                    &[],
                );
                return;
            };
            let total_files = listing.len() as u32;
            let files = listing
                .iter()
                .map(|entry| NativeViewerManifestFileAuthority {
                    size: entry.size,
                    modified_time: entry.modified_time,
                })
                .collect();
            let (duplicate, completed) = {
                let mut pending = self.shared.pending_file_manifest_request.lock().unwrap();
                let Some(active) = pending.as_mut() else {
                    return;
                };
                if active.request_id != id || active.files_delivered {
                    pending.take();
                    (true, None)
                } else {
                    active.files_delivered = true;
                    active.total_files = Some(total_files);
                    active.total_bytes = Some(total_bytes);
                    active.files = Some(files);
                    if active.empty_directories_delivered {
                        let completed = pending.take().and_then(|request| {
                            Some(NativeViewerCompletedManifest {
                                session_epoch: request.session_epoch,
                                request_id: request.request_id,
                                total_files: request.total_files?,
                                total_bytes: request.total_bytes?,
                                files: request.files?.into(),
                            })
                        });
                        (false, completed)
                    } else {
                        (false, None)
                    }
                }
            };
            if let Some(completed) = completed {
                *self.shared.completed_file_manifest_request.lock().unwrap() = Some(completed);
            } else if duplicate {
                client_clear_completed_manifest(&self.shared, request.session_epoch);
            }
            self.shared.emit_file_transfer_manifest(
                request,
                if duplicate {
                    FILE_TRANSFER_LIST_REJECTED
                } else {
                    FILE_TRANSFER_LIST_SUCCESS
                },
                FILE_TRANSFER_MANIFEST_PART_FILES,
                if duplicate { &[] } else { &listing },
            );
            return;
        }
        let request = self.shared.pending_file_list_request.lock().unwrap().take();
        let Some(request) = request else { return };
        if is_local || only_count || path != "/" {
            self.shared
                .emit_file_transfer_list(request, FILE_TRANSFER_LIST_REJECTED, &[]);
            return;
        }
        match native_viewer_remote_listing(entries) {
            Some(listing) => {
                self.shared
                    .emit_file_transfer_list(request, FILE_TRANSFER_LIST_SUCCESS, &listing)
            }
            None => self
                .shared
                .emit_file_transfer_list(request, FILE_TRANSFER_LIST_REJECTED, &[]),
        }
    }

    fn update_empty_dirs(&self, response: ReadEmptyDirsResponse) {
        let request = {
            let pending = self.shared.pending_file_manifest_request.lock().unwrap();
            pending.as_ref().cloned()
        };
        let Some(request) = request else { return };
        let Some(listing) = native_viewer_remote_manifest_empty_directories(&response) else {
            self.shared
                .pending_file_manifest_request
                .lock()
                .unwrap()
                .take();
            client_clear_completed_manifest(&self.shared, request.session_epoch);
            self.shared.emit_file_transfer_manifest(
                request,
                FILE_TRANSFER_LIST_REJECTED,
                FILE_TRANSFER_MANIFEST_PART_EMPTY_DIRECTORIES,
                &[],
            );
            return;
        };
        let (duplicate, completed) = {
            let mut pending = self.shared.pending_file_manifest_request.lock().unwrap();
            let Some(active) = pending.as_mut() else {
                return;
            };
            if active.empty_directories_delivered {
                pending.take();
                (true, None)
            } else {
                active.empty_directories_delivered = true;
                if active.files_delivered {
                    let completed = pending.take().and_then(|request| {
                        Some(NativeViewerCompletedManifest {
                            session_epoch: request.session_epoch,
                            request_id: request.request_id,
                            total_files: request.total_files?,
                            total_bytes: request.total_bytes?,
                            files: request.files?.into(),
                        })
                    });
                    (false, completed)
                } else {
                    (false, None)
                }
            }
        };
        if let Some(completed) = completed {
            *self.shared.completed_file_manifest_request.lock().unwrap() = Some(completed);
        } else if duplicate {
            client_clear_completed_manifest(&self.shared, request.session_epoch);
        }
        self.shared.emit_file_transfer_manifest(
            request,
            if duplicate {
                FILE_TRANSFER_LIST_REJECTED
            } else {
                FILE_TRANSFER_LIST_SUCCESS
            },
            FILE_TRANSFER_MANIFEST_PART_EMPTY_DIRECTORIES,
            if duplicate { &[] } else { &listing },
        );
    }

    fn confirm_delete_files(&self, _id: i32, _index: i32, _name: String) {}

    fn override_file_confirm(
        &self,
        _id: i32,
        _file_num: i32,
        _path: String,
        _is_upload: bool,
        _is_identical: bool,
    ) {
    }

    fn update_block_input_state(&self, _on: bool) {}
    fn job_progress(&self, id: i32, file_num: i32, speed: f64, finished_size: f64) {
        let event = self
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .get_mut(&id)
            .and_then(|job| job.progress(file_num, speed, finished_size));
        if let Some(event) = event {
            self.shared.emit_file_transfer_event(event);
        }
    }
    fn adapt_size(&self) {}
    fn on_rgba(&self, _display: usize, _rgba: &mut scrap::ImageRgb) {}

    fn msgbox(&self, message_type: &str, _title: &str, text: &str, _link: &str, retry: bool) {
        match message_type {
            "input-password" => {
                self.shared
                    .emit_state(RDNState::PasswordRequired, 1, "password-required")
            }
            "re-input-password" | "input-2fa" => {
                self.shared
                    .emit_state(RDNState::AuthenticationFailed, 2, "authentication-failed")
            }
            "success" => {}
            _ => {
                if !retry {
                    self.shared
                        .terminal_retry_allowed
                        .store(false, Ordering::Release);
                }
                let (code, message) = viewer_terminal_error_state(text, retry);
                self.shared.emit_state(RDNState::Error, code, message)
            }
        }
    }

    fn cancel_msgbox(&self, _tag: &str) {}
    fn switch_back(&self, _id: &str) {}
    fn portable_service_running(&self, _running: bool) {}
    fn on_voice_call_started(&self) {}
    fn on_voice_call_closed(&self, _reason: &str) {}
    fn on_voice_call_waiting(&self) {}
    fn on_voice_call_incoming(&self) {}
    fn get_rgba(&self, _display: usize) -> *const u8 {
        ptr::null()
    }
    fn next_rgba(&self, _display: usize) {}
    fn set_multiple_windows_session(&self, _sessions: Vec<WindowsSession>) {}
    fn set_current_display(&self, display: i32) {
        self.shared
            .publish_selected_display(display, NativeViewerDisplaySelectionIngress::RemoteFollow);
    }
    fn update_record_status(&self, _start: bool) {}
    fn printer_request(&self, _id: i32, _path: String) {}
    fn handle_screenshot_resp(&self, _sid: String, _message: String) {}
    fn handle_terminal_response(&self, _response: TerminalResponse) {}

    fn on_encoded_video(&self, frame: &VideoFrame) -> bool {
        self.shared.emit_video(frame)
    }

    fn native_clipboard_text(&self, text: String) {
        self.shared.emit_clipboard_text(&text);
    }

    fn native_clipboard_rich_text_enabled(&self) -> bool {
        clipboard_receive_allowed(
            self.shared.active.load(Ordering::Acquire),
            self.shared.authenticated.load(Ordering::Acquire),
            self.shared
                .receive_clipboard_rich_text
                .load(Ordering::Acquire),
            self.shared.remote_clipboard_enabled.load(Ordering::Acquire),
        )
    }

    fn native_clipboard_rich_text(
        &self,
        plain_text: Option<String>,
        rtf: Option<String>,
        html: Option<String>,
    ) {
        self.shared
            .emit_clipboard_rich_text(NativeViewerRichTextBundle {
                plain_text,
                rtf,
                html,
            });
    }

    fn native_clipboard_image_enabled(&self) -> bool {
        clipboard_receive_allowed(
            self.shared.active.load(Ordering::Acquire),
            self.shared.authenticated.load(Ordering::Acquire),
            self.shared.receive_clipboard_image.load(Ordering::Acquire),
            self.shared.remote_clipboard_enabled.load(Ordering::Acquire),
        )
    }

    fn native_clipboard_image(&self, image: NativeViewerClipboardImage) {
        self.shared.emit_clipboard_image(image);
    }

    fn native_file_transfer_download_digest_confirmation(
        &self,
        digest: &FileTransferDigest,
    ) -> (bool, Option<FileTransferSendConfirmRequest>) {
        let mut jobs = self.shared.active_file_download_jobs.lock().unwrap();
        let Some(job) = jobs.get_mut(&digest.id) else {
            return (false, None);
        };
        (true, job.confirm_digest(digest))
    }

    fn native_file_transfer_receive_block(&self, block: &FileTransferBlock) -> bool {
        let job = {
            let jobs = self.shared.active_file_download_jobs.lock().unwrap();
            let Some(job) = jobs.get(&block.id) else {
                return false;
            };
            job.clone()
        };
        let semantic = job.receive_block(block);
        if let Some(block) = semantic {
            self.shared.emit_file_transfer_receive_block(&block);
        }
        true
    }

    fn native_file_transfer_upload_poll_interval_ms(&self) -> u64 {
        self.shared.file_transfer_upload_poll_interval_ms()
    }

    fn native_file_transfer_upload_poll(&self) -> Option<Message> {
        self.shared.file_transfer_upload_poll()
    }

    fn native_file_transfer_upload_confirmation(
        &self,
        request: &FileTransferSendConfirmRequest,
    ) -> (bool, Vec<Message>) {
        self.shared.file_transfer_upload_confirmation(request)
    }

    fn native_file_transfer_upload_existing_target(
        &self,
        digest: &FileTransferDigest,
    ) -> (bool, Vec<Message>) {
        self.shared.file_transfer_upload_existing_target(digest)
    }

    fn native_file_transfer_upload_done(&self, done: &FileTransferDone) -> (bool, Vec<Message>) {
        self.shared.file_transfer_upload_done(done)
    }

    fn native_file_transfer_upload_error(&self, error: &FileTransferError) -> (bool, Vec<Message>) {
        self.shared.file_transfer_upload_error(error)
    }
}
