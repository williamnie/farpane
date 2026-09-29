#[no_mangle]
pub extern "C" fn rdn_core_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn rdn_core_upstream_commit() -> *const c_char {
    UPSTREAM_COMMIT.as_ptr() as *const c_char
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_create(
    callbacks: *const RDNCallbacks,
    context: *mut c_void,
) -> *mut RDNClient {
    if callbacks.is_null() || (*callbacks).abi_version != ABI_VERSION {
        return ptr::null_mut();
    }
    let shared = Arc::new(BridgeShared {
        callbacks: *callbacks,
        context: context as usize,
        active: AtomicBool::new(true),
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
    });
    Box::into_raw(Box::new(RDNClient {
        shared,
        session: Mutex::new(None),
        worker: Mutex::new(None),
        housekeeping: Mutex::new(None),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_destroy(client: *mut RDNClient) {
    if client.is_null() {
        return;
    }
    let client = Box::from_raw(client);
    client.disconnect(false);
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_connect(
    client: *mut RDNClient,
    config: *const RDNConnectionConfig,
) -> i32 {
    if client.is_null() || config.is_null() {
        return -1;
    }
    if (*config).abi_version != ABI_VERSION {
        return -2;
    }
    let desktop_clipboard_requested = (*config).receive_clipboard_text
        || (*config).send_clipboard_text
        || (*config).receive_clipboard_rich_text
        || (*config).send_clipboard_rich_text
        || (*config).receive_clipboard_image
        || (*config).send_clipboard_image;
    let receive_audio = (*config).receive_audio;
    let file_transfer_admission = viewer_file_transfer_mode_admission(
        (*config).enable_file_transfer,
        (*config).file_transfer_session_epoch,
        desktop_clipboard_requested || receive_audio,
    );
    if file_transfer_admission != 0 {
        return file_transfer_admission;
    }
    let file_transfer_mode = (*config).enable_file_transfer;
    let client = &*client;
    if client.worker.lock().unwrap().is_some() {
        return -4;
    }
    let server = match required_string((*config).rendezvous_server) {
        Ok(value) if !value.is_empty() => value,
        _ => return -5,
    };
    let key = match required_string((*config).server_public_key) {
        Ok(value) if !value.is_empty() => value,
        _ => return -5,
    };
    let peer_id = match required_string((*config).peer_id) {
        Ok(value) if !value.is_empty() => value,
        _ => return -5,
    };
    let password = match optional_string((*config).password) {
        Ok(value) => value,
        Err(code) => return code,
    };
    if server.contains('@') || peer_id.contains('@') || key.contains('&') {
        return -5;
    }

    let Some(connection_epoch) = next_viewer_connection_epoch() else {
        return -3;
    };

    client.shared.active.store(true, Ordering::Release);
    client
        .shared
        .connection_epoch
        .store(connection_epoch, Ordering::Release);
    *client.shared.display_catalog.lock().unwrap() = NativeViewerDisplayCatalogState::default();
    client.shared.authenticated.store(false, Ordering::Release);
    client
        .shared
        .remote_keyboard_enabled
        .store(true, Ordering::Release);
    client
        .shared
        .remote_audio_enabled
        .store(true, Ordering::Release);
    client.shared.input_allowed.store(false, Ordering::Release);
    client
        .shared
        .receive_clipboard_text
        .store((*config).receive_clipboard_text, Ordering::Release);
    client
        .shared
        .send_clipboard_text
        .store((*config).send_clipboard_text, Ordering::Release);
    client
        .shared
        .receive_clipboard_rich_text
        .store((*config).receive_clipboard_rich_text, Ordering::Release);
    client
        .shared
        .send_clipboard_rich_text
        .store((*config).send_clipboard_rich_text, Ordering::Release);
    client
        .shared
        .receive_clipboard_image
        .store((*config).receive_clipboard_image, Ordering::Release);
    client
        .shared
        .send_clipboard_image
        .store((*config).send_clipboard_image, Ordering::Release);
    client
        .shared
        .remote_clipboard_enabled
        .store(REMOTE_CLIPBOARD_ENABLED_BY_DEFAULT, Ordering::Release);
    client
        .shared
        .remote_file_transfer_enabled
        .store(false, Ordering::Release);
    client
        .shared
        .file_transfer_enabled
        .store(file_transfer_mode, Ordering::Release);
    client
        .shared
        .file_transfer_session_epoch
        .store((*config).file_transfer_session_epoch, Ordering::Release);
    client
        .shared
        .pending_file_list_request
        .lock()
        .unwrap()
        .take();
    client
        .shared
        .file_manifest_request_epoch
        .store(0, Ordering::Release);
    client
        .shared
        .pending_file_manifest_request
        .lock()
        .unwrap()
        .take();
    client
        .shared
        .completed_file_manifest_request
        .lock()
        .unwrap()
        .take();
    client
        .shared
        .active_file_download_jobs
        .lock()
        .unwrap()
        .clear();
    client
        .shared
        .active_file_upload_jobs
        .lock()
        .unwrap()
        .clear();
    client.shared.sequence.store(0, Ordering::Relaxed);
    *client.shared.dimensions.write().unwrap() = (0, 0);
    client
        .shared
        .emit_state(RDNState::Connecting, 0, "connecting");

    let target = format!("{peer_id}@{server}?key={key}");
    let ui = BridgeUi {
        shared: client.shared.clone(),
    };
    let session: Session<BridgeUi> = Session {
        password,
        ui_handler: ui.clone(),
        // RustDesk's desktop protocol treats keyboard control as enabled unless
        // the peer sends an explicit PermissionInfo(false).
        server_keyboard_enabled: Arc::new(RwLock::new(true)),
        server_file_transfer_enabled: Arc::new(RwLock::new(false)),
        server_clipboard_enabled: Arc::new(RwLock::new(false)),
        ..Default::default()
    };
    session.lc.write().unwrap().initialize(
        target,
        if file_transfer_mode {
            ConnType::FILE_TRANSFER
        } else {
            ConnType::DEFAULT_CONN
        },
        None,
        (*config).force_relay,
        None,
        None,
        None,
    );
    session
        .lc
        .write()
        .unwrap()
        .configure_native_viewer(
            &peer_id,
            desktop_clipboard_requested,
            receive_audio,
        );
    let round = session.connection_round_state.lock().unwrap().new_round();
    let worker_session = session.clone();
    let worker_shared = client.shared.clone();
    let worker = std::thread::spawn(move || {
        io_loop(worker_session, round);
        worker_shared.terminate_display_selection(DISPLAY_SELECTION_FAILURE_CONNECTION_CLOSED);
        worker_shared.authenticated.store(false, Ordering::Release);
        worker_shared.input_allowed.store(false, Ordering::Release);
        worker_shared
            .file_transfer_enabled
            .store(false, Ordering::Release);
        worker_shared
            .file_transfer_session_epoch
            .store(0, Ordering::Release);
        worker_shared.connection_epoch.store(0, Ordering::Release);
        *worker_shared.display_catalog.lock().unwrap() = NativeViewerDisplayCatalogState::default();
        worker_shared
            .pending_file_list_request
            .lock()
            .unwrap()
            .take();
        worker_shared
            .file_manifest_request_epoch
            .store(0, Ordering::Release);
        worker_shared
            .pending_file_manifest_request
            .lock()
            .unwrap()
            .take();
        worker_shared
            .completed_file_manifest_request
            .lock()
            .unwrap()
            .take();
        worker_shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .clear();
        worker_shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .clear();
        let retry_allowed = worker_shared.terminal_retry_allowed.load(Ordering::Acquire);
        worker_shared.emit_state(
            RDNState::Disconnected,
            if retry_allowed {
                0
            } else {
                TERMINAL_NO_RETRY_CODE
            },
            if retry_allowed {
                "disconnected"
            } else {
                "disconnected-no-retry"
            },
        );
    });
    let housekeeping = if file_transfer_mode {
        None
    } else {
        let housekeeping_session = session.clone();
        let housekeeping_shared = client.shared.clone();
        let custom_fps = native_stream_fps((*config).force_relay);
        Some(std::thread::spawn(move || {
            let mut ticks = 0;
            let mut configuration_sent = false;
            while housekeeping_shared.active.load(Ordering::Acquire) {
                std::thread::sleep(Duration::from_millis(100));
                if !housekeeping_shared.active.load(Ordering::Acquire) {
                    break;
                }
                if !configuration_sent {
                    if let Some(sender) = housekeeping_session.sender.read().unwrap().as_ref() {
                        if sender
                            .send(Data::Message(native_stream_configuration_message(
                                custom_fps,
                            )))
                            .is_err()
                        {
                            break;
                        }
                        configuration_sent = true;
                    }
                }
                ticks += 1;
                if ticks < 50 {
                    continue;
                }
                ticks = 0;
                if let Some(sender) = housekeeping_session.sender.read().unwrap().as_ref() {
                    if sender.send(Data::Message(housekeeping_message())).is_err() {
                        break;
                    }
                }
            }
        }))
    };
    *client.session.lock().unwrap() = Some(session);
    *client.worker.lock().unwrap() = Some(worker);
    *client.housekeeping.lock().unwrap() = housekeeping;
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_disconnect(client: *mut RDNClient) {
    if let Some(client) = client.as_ref() {
        client.disconnect(true);
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_select_display(
    client: *mut RDNClient,
    request: *const RDNDisplaySelectionRequest,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    let Some(request) = request.as_ref() else {
        return -1;
    };
    if request.abi_version != ABI_VERSION {
        return -2;
    }
    if request.connection_epoch == 0 || request.command_id == 0 || request.catalog_revision == 0 {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if client.shared.connection_epoch.load(Ordering::Acquire) != request.connection_epoch {
        return -10;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if session.sender.read().unwrap().is_none() {
        return -3;
    }

    let delivery = client.shared.display_catalog_delivery.lock().unwrap();
    if !client.shared.active.load(Ordering::Acquire)
        || !client.shared.authenticated.load(Ordering::Acquire)
        || client.shared.connection_epoch.load(Ordering::Acquire) != request.connection_epoch
    {
        return -10;
    }
    let mut state = client.shared.display_catalog.lock().unwrap();
    if !state.initialized || state.entries.is_none() || state.revision != request.catalog_revision {
        return -10;
    }
    if state.pending_selection.is_some() {
        return -3;
    }
    if request.command_id <= state.last_selection_command_id {
        return -5;
    }
    let selectable = state.entries.as_deref().is_some_and(|entries| {
        entries
            .get(request.display_index as usize)
            .is_some_and(|entry| entry.display_index == request.display_index && entry.online)
    });
    if !selectable {
        return -5;
    }
    state.last_selection_command_id = request.command_id;
    let pending = NativeViewerDisplaySelectionPending {
        connection_epoch: request.connection_epoch,
        command_id: request.command_id,
        catalog_revision: request.catalog_revision,
        display_index: request.display_index,
    };
    if state.selected_display_index == Some(request.display_index) {
        drop(state);
        client
            .shared
            .emit_display_selection(NativeViewerDisplaySelectionSnapshot {
                pending,
                result: DISPLAY_SELECTION_RESULT_ALREADY_SELECTED,
                failure: DISPLAY_SELECTION_FAILURE_NONE,
            });
        drop(delivery);
        return 0;
    }
    state.pending_selection = Some(pending);
    drop(state);
    session.switch_display(request.display_index as i32);
    drop(delivery);
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_request_keyframe(client: *mut RDNClient, display: u32) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -2;
    };
    session.refresh_video(display.min(i32::MAX as u32) as i32);
    0
}
