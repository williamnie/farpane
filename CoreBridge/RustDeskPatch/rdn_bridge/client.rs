pub struct RDNClient {
    shared: Arc<BridgeShared>,
    session: Mutex<Option<Session<BridgeUi>>>,
    worker: Mutex<Option<JoinHandle<()>>>,
    housekeeping: Mutex<Option<JoinHandle<()>>>,
}

impl RDNClient {
    fn disconnect(&self, emit_state: bool) {
        self.shared
            .terminate_display_selection(DISPLAY_SELECTION_FAILURE_CONNECTION_CLOSED);
        self.shared.authenticated.store(false, Ordering::Release);
        self.shared.input_allowed.store(false, Ordering::Release);
        self.shared
            .receive_clipboard_text
            .store(false, Ordering::Release);
        self.shared
            .send_clipboard_text
            .store(false, Ordering::Release);
        self.shared
            .receive_clipboard_rich_text
            .store(false, Ordering::Release);
        self.shared
            .send_clipboard_rich_text
            .store(false, Ordering::Release);
        self.shared
            .receive_clipboard_image
            .store(false, Ordering::Release);
        self.shared
            .send_clipboard_image
            .store(false, Ordering::Release);
        self.shared
            .remote_clipboard_enabled
            .store(false, Ordering::Release);
        self.shared
            .remote_file_transfer_enabled
            .store(false, Ordering::Release);
        self.shared
            .file_transfer_enabled
            .store(false, Ordering::Release);
        self.shared
            .file_transfer_session_epoch
            .store(0, Ordering::Release);
        self.shared.connection_epoch.store(0, Ordering::Release);
        *self.shared.display_catalog.lock().unwrap() = NativeViewerDisplayCatalogState::default();
        self.shared.pending_file_list_request.lock().unwrap().take();
        self.shared
            .file_manifest_request_epoch
            .store(0, Ordering::Release);
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
        self.shared.active.store(false, Ordering::Release);
        if let Some(session) = self.session.lock().unwrap().as_ref() {
            if let Some(sender) = session.sender.read().unwrap().as_ref() {
                let _ = sender.send(Data::Close);
            }
        }
        if let Some(worker) = self.worker.lock().unwrap().take() {
            let _ = worker.join();
        }
        if let Some(housekeeping) = self.housekeeping.lock().unwrap().take() {
            let _ = housekeeping.join();
        }
        self.session.lock().unwrap().take();
        if emit_state {
            self.shared
                .emit_state_unchecked(RDNState::Disconnected, 0, "disconnected");
        }
    }
}

fn housekeeping_message() -> Message {
    let mut delay = TestDelay::new();
    delay.from_client = true;
    let mut message = Message::new();
    message.set_test_delay(delay);
    message
}

fn native_stream_fps(force_relay: bool) -> i32 {
    // RustDesk's own adaptive controller leaves more scheduling margin on a
    // relay (4/5 of decoder rate) than on a direct connection (9/10).
    if force_relay {
        38
    } else {
        36
    }
}
