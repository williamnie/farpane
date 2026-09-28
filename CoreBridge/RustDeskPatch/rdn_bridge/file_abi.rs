#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_cancel(
    client: *mut RDNClient,
    session_epoch: u64,
    transfer_id: i32,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if session_epoch == 0 || transfer_id <= 0 {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    if sender.send(Data::CancelJob(transfer_id)).is_err() {
        let upload_event = client
            .shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .remove(&transfer_id)
            .filter(|job| job.session_epoch == session_epoch)
            .and_then(|job| {
                job.terminal(
                    FILE_TRANSFER_EVENT_FAILED,
                    FILE_TRANSFER_FAILURE_CONNECTION_CLOSED,
                )
            });
        if let Some(event) = upload_event {
            client.shared.emit_file_transfer_event(event);
        }
        return -3;
    }
    let upload_event = {
        let mut jobs = client.shared.active_file_upload_jobs.lock().unwrap();
        if jobs
            .get(&transfer_id)
            .is_some_and(|job| job.session_epoch == session_epoch)
        {
            jobs.remove(&transfer_id).and_then(|job| {
                job.terminal(FILE_TRANSFER_EVENT_CANCELLED, FILE_TRANSFER_FAILURE_NONE)
            })
        } else {
            None
        }
    };
    if let Some(event) = upload_event {
        client.shared.emit_file_transfer_event(event);
        return 0;
    }
    let event = {
        let mut jobs = client.shared.active_file_download_jobs.lock().unwrap();
        if jobs
            .get(&transfer_id)
            .is_some_and(|job| job.session_epoch == session_epoch)
        {
            jobs.remove(&transfer_id).and_then(|job| {
                job.terminal(FILE_TRANSFER_EVENT_CANCELLED, FILE_TRANSFER_FAILURE_NONE)
            })
        } else {
            None
        }
    };
    if let Some(event) = event {
        client.shared.emit_file_transfer_event(event);
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_list_root(
    client: *mut RDNClient,
    session_epoch: u64,
    request_id: i32,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if session_epoch == 0 || request_id <= 0 {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    let request = NativeViewerListRequest {
        session_epoch,
        request_id,
    };
    {
        let mut pending = client.shared.pending_file_list_request.lock().unwrap();
        if pending.is_some() {
            return -3;
        }
        *pending = Some(request.clone());
    }
    if sender
        .send(Data::Message(native_viewer_file_list_root_message()))
        .is_err()
    {
        let mut pending = client.shared.pending_file_list_request.lock().unwrap();
        if pending.as_ref() == Some(&request) {
            pending.take();
        }
        return -3;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_manifest_root(
    client: *mut RDNClient,
    session_epoch: u64,
    request_id: i32,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if session_epoch == 0 || request_id <= 0 {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    let request = NativeViewerManifestRequest {
        session_epoch,
        request_id,
        files_delivered: false,
        empty_directories_delivered: false,
        total_files: None,
        total_bytes: None,
        files: None,
    };
    if client
        .shared
        .file_manifest_request_epoch
        .compare_exchange(0, session_epoch, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return -3;
    }
    {
        let mut pending = client.shared.pending_file_manifest_request.lock().unwrap();
        debug_assert!(pending.is_none());
        *pending = Some(request.clone());
    }
    let (files_message, directories_message) =
        native_viewer_file_manifest_root_messages(request_id);
    if sender.send(Data::Message(files_message)).is_err()
        || sender.send(Data::Message(directories_message)).is_err()
    {
        let mut pending = client.shared.pending_file_manifest_request.lock().unwrap();
        if pending.as_ref() == Some(&request) {
            pending.take();
        }
        return -3;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_download_start(
    client: *mut RDNClient,
    request: *const RDNFileTransferDownloadStart,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    let Some(request) = request.as_ref() else {
        return -4;
    };
    if request.abi_version != ABI_VERSION
        || request.session_epoch == 0
        || request.manifest_request_id <= 0
        || request.transfer_id <= 0
        || request.total_files as usize > MAX_FILE_TRANSFER_LIST_ENTRIES
        || (request.total_files == 0 && request.total_bytes != 0)
    {
        return -4;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != request.session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    let manifest_files = {
        let completed_manifest = client
            .shared
            .completed_file_manifest_request
            .lock()
            .unwrap();
        let Some(completed_manifest) = completed_manifest.as_ref() else {
            return -3;
        };
        if completed_manifest.session_epoch != request.session_epoch
            || completed_manifest.request_id != request.manifest_request_id
            || completed_manifest.total_files != request.total_files
            || completed_manifest.total_bytes != request.total_bytes
            || completed_manifest.files.len() != request.total_files as usize
        {
            return -3;
        }
        completed_manifest.files.clone()
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    let job = NativeViewerDownloadJob {
        session_epoch: request.session_epoch,
        manifest_request_id: request.manifest_request_id,
        transfer_id: request.transfer_id,
        total_files: request.total_files,
        total_bytes: request.total_bytes,
        manifest_files,
        next_digest_file_number: 0,
        sequence: 0,
        files_completed: 0,
        bytes_completed: 0,
    };
    let mut jobs = client.shared.active_file_download_jobs.lock().unwrap();
    if !client.shared.active.load(Ordering::Acquire)
        || !client.shared.file_transfer_enabled.load(Ordering::Acquire)
        || client
            .shared
            .file_transfer_session_epoch
            .load(Ordering::Acquire)
            != request.session_epoch
        || !client.shared.authenticated.load(Ordering::Acquire)
    {
        return -3;
    }
    if jobs.len() >= MAX_VIEWER_DOWNLOAD_JOBS || jobs.contains_key(&request.transfer_id) {
        return -3;
    }
    jobs.insert(request.transfer_id, job);
    // The unbounded channel enqueue is nonblocking. Keeping the job mutex here
    // makes a closed queue rollback atomic with registration, so cancel/retry
    // cannot observe or replace a half-dispatched transfer ID.
    if sender
        .send(Data::Message(native_viewer_file_download_root_message(
            request.transfer_id,
        )))
        .is_err()
    {
        jobs.remove(&request.transfer_id);
        return -3;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_file_transfer_upload_start(
    client: *mut RDNClient,
    request: *const RDNFileTransferUploadStart,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    let Some(request) = request.as_ref() else {
        return -4;
    };
    if request.abi_version != ABI_VERSION
        || request.session_epoch == 0
        || request.transfer_id <= 0
        || request.source_token == 0
    {
        return -4;
    }
    let Some((files, empty_directories)) = native_viewer_upload_manifest(request) else {
        return -4;
    };
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.file_transfer_enabled.load(Ordering::Acquire) {
        return -7;
    }
    if client
        .shared
        .file_transfer_session_epoch
        .load(Ordering::Acquire)
        != request.session_epoch
    {
        return -10;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if !files.is_empty()
        && client
            .shared
            .callbacks
            .on_file_transfer_upload_read
            .is_none()
    {
        return -5;
    }
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if !*session.server_file_transfer_enabled.read().unwrap() {
        return -8;
    }
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    let stage = if empty_directories.is_empty() {
        NativeViewerUploadStage::ReadyDigest { file_number: 0 }
    } else {
        NativeViewerUploadStage::AwaitingCreate {
            directory_number: 0,
        }
    };
    let job = NativeViewerUploadJob {
        session_epoch: request.session_epoch,
        transfer_id: request.transfer_id,
        source_token: request.source_token,
        files: files.into(),
        empty_directories: empty_directories.into(),
        total_bytes: request.total_bytes,
        stage,
        stage_started: Instant::now(),
        sequence: 0,
        files_completed: 0,
        bytes_completed: 0,
    };
    let Some(initial_message) = job.initial_message() else {
        return -4;
    };
    let download_jobs = client.shared.active_file_download_jobs.lock().unwrap();
    let mut upload_jobs = client.shared.active_file_upload_jobs.lock().unwrap();
    if !client.shared.active.load(Ordering::Acquire)
        || !client.shared.file_transfer_enabled.load(Ordering::Acquire)
        || client
            .shared
            .file_transfer_session_epoch
            .load(Ordering::Acquire)
            != request.session_epoch
        || !client.shared.authenticated.load(Ordering::Acquire)
        || upload_jobs.len() >= MAX_VIEWER_UPLOAD_JOBS
        || upload_jobs.contains_key(&request.transfer_id)
        || download_jobs.contains_key(&request.transfer_id)
    {
        return -3;
    }
    upload_jobs.insert(request.transfer_id, job);
    if sender.send(Data::Message(initial_message)).is_err() {
        upload_jobs.remove(&request.transfer_id);
        return -3;
    }
    0
}
