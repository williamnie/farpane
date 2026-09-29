fn native_stream_configuration_message(custom_fps: i32) -> Message {
    let mut misc = Misc::new();
    misc.set_option(OptionMessage {
        // The native bridge consumes encoded frames before RustDesk creates its
        // decoder thread, so upstream fps_control has no decode rate from which
        // to publish an automatic cap. The Swift/VideoToolbox path is validated
        // for the normal desktop maximum and reports its own backpressure. A
        // 36 FPS capture ceiling leaves scheduling headroom for a 30 Hz source;
        // the host still only emits frames when the display content changes.
        custom_fps,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_misc(misc);
    message
}

unsafe fn required_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        return Err(-3);
    }
    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| -3)
}

unsafe fn optional_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        Ok(String::new())
    } else {
        required_string(pointer)
    }
}

fn native_viewer_remote_listing(entries: &[FileEntry]) -> Option<Vec<NativeViewerRemoteListEntry>> {
    if entries.len() > MAX_FILE_TRANSFER_LIST_ENTRIES {
        return None;
    }
    let mut metadata_utf8_bytes = 0usize;
    let mut collision_keys = HashSet::with_capacity(entries.len());
    let mut normalized = Vec::with_capacity(entries.len());
    for entry in entries {
        let name = entry.name.as_str();
        if name.is_empty()
            || name == "."
            || name == ".."
            || name.starts_with('/')
            || name.ends_with('/')
            || name.contains('/')
            || name.contains('\\')
            || name.chars().any(char::is_control)
            || name
                .to_ascii_lowercase()
                .ends_with(FILE_TRANSFER_PRIVATE_STAGING_SUFFIX)
        {
            return None;
        }
        metadata_utf8_bytes = metadata_utf8_bytes.checked_add(name.len())?;
        if metadata_utf8_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES {
            return None;
        }
        if !collision_keys.insert(name.to_ascii_lowercase()) {
            return None;
        }
        if entry.is_hidden {
            return None;
        }
        let kind = match entry.entry_type.enum_value() {
            Ok(FileType::Dir) if entry.size == 0 => NativeViewerRemoteListEntryKind::Directory,
            Ok(FileType::File) => NativeViewerRemoteListEntryKind::File,
            _ => return None,
        };
        normalized.push(NativeViewerRemoteListEntry {
            kind,
            relative_path: name.to_owned(),
            size: entry.size,
            modified_time: entry.modified_time,
        });
    }
    Some(normalized)
}

fn native_viewer_manifest_relative_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.ends_with('/')
        && !path.contains('\\')
        && !path.chars().any(char::is_control)
        && path.split('/').all(|component| {
            !component.is_empty()
                && component != "."
                && component != ".."
                && !component
                    .to_ascii_lowercase()
                    .ends_with(FILE_TRANSFER_PRIVATE_STAGING_SUFFIX)
        })
}

fn native_viewer_remote_manifest_files(
    entries: &[FileEntry],
) -> Option<Vec<NativeViewerRemoteListEntry>> {
    if entries.len() > MAX_FILE_TRANSFER_LIST_ENTRIES {
        return None;
    }
    let mut metadata_utf8_bytes = 0usize;
    let mut collision_keys = HashSet::with_capacity(entries.len());
    let mut normalized = Vec::with_capacity(entries.len());
    for entry in entries {
        let path = entry.name.as_str();
        if entry.is_hidden
            || entry.entry_type.enum_value() != Ok(FileType::File)
            || !native_viewer_manifest_relative_path(path)
        {
            return None;
        }
        metadata_utf8_bytes = metadata_utf8_bytes.checked_add(path.len())?;
        if metadata_utf8_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES
            || !collision_keys.insert(path.to_ascii_lowercase())
        {
            return None;
        }
        normalized.push(NativeViewerRemoteListEntry {
            kind: NativeViewerRemoteListEntryKind::File,
            relative_path: path.to_owned(),
            size: entry.size,
            modified_time: entry.modified_time,
        });
    }
    Some(normalized)
}

fn native_viewer_remote_manifest_empty_directories(
    response: &ReadEmptyDirsResponse,
) -> Option<Vec<NativeViewerRemoteListEntry>> {
    if response.path != "/" || response.empty_dirs.len() > MAX_FILE_TRANSFER_LIST_ENTRIES {
        return None;
    }
    let mut metadata_utf8_bytes = 0usize;
    let mut collision_keys = HashSet::with_capacity(response.empty_dirs.len());
    let mut normalized = Vec::with_capacity(response.empty_dirs.len());
    for directory in &response.empty_dirs {
        let wire_path = directory.path.as_str();
        let path = wire_path.strip_prefix('/')?;
        if directory.id != 0
            || !directory.entries.is_empty()
            || !native_viewer_manifest_relative_path(path)
        {
            return None;
        }
        metadata_utf8_bytes = metadata_utf8_bytes.checked_add(path.len())?;
        if metadata_utf8_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES
            || !collision_keys.insert(path.to_ascii_lowercase())
        {
            return None;
        }
        normalized.push(NativeViewerRemoteListEntry {
            kind: NativeViewerRemoteListEntryKind::Directory,
            relative_path: path.to_owned(),
            size: 0,
            modified_time: 0,
        });
    }
    Some(normalized)
}

fn native_viewer_upload_directory_projection(leaves: &[String]) -> Option<Vec<String>> {
    let mut projected = HashSet::new();
    for leaf in leaves {
        let mut path = String::new();
        for component in leaf.split('/') {
            if !path.is_empty() {
                path.push('/');
            }
            path.push_str(component);
            projected.insert(path.clone());
        }
    }
    if projected.len() > MAX_FILE_TRANSFER_LIST_ENTRIES {
        return None;
    }
    let metadata_bytes = projected
        .iter()
        .try_fold(0usize, |total, path| total.checked_add(path.len()))?;
    if metadata_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES {
        return None;
    }
    let mut projected: Vec<_> = projected.into_iter().collect();
    projected.sort_by(|left, right| {
        left.matches('/')
            .count()
            .cmp(&right.matches('/').count())
            .then_with(|| left.as_bytes().cmp(right.as_bytes()))
    });
    Some(projected)
}

unsafe fn native_viewer_upload_manifest(
    request: &RDNFileTransferUploadStart,
) -> Option<(Vec<NativeViewerUploadFileAuthority>, Vec<String>)> {
    if request.entry_count == 0
        || request.entry_count > MAX_FILE_TRANSFER_LIST_ENTRIES
        || request.entries.is_null()
    {
        return None;
    }
    let entries = slice::from_raw_parts(request.entries, request.entry_count);
    let mut metadata_utf8_bytes = 0usize;
    let mut collision_keys = HashSet::with_capacity(entries.len());
    let mut all_collision_keys = Vec::with_capacity(entries.len());
    let mut files = Vec::new();
    let mut empty_directories = Vec::new();
    let mut total_bytes = 0u64;
    for entry in entries {
        if entry.relative_path_utf8.is_null() || entry.relative_path_length == 0 {
            return None;
        }
        metadata_utf8_bytes = metadata_utf8_bytes.checked_add(entry.relative_path_length)?;
        if metadata_utf8_bytes > MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES {
            return None;
        }
        let bytes = slice::from_raw_parts(entry.relative_path_utf8, entry.relative_path_length);
        let path = std::str::from_utf8(bytes).ok()?;
        if !native_viewer_manifest_relative_path(path) {
            return None;
        }
        let collision_key = path.to_ascii_lowercase();
        if !collision_keys.insert(collision_key.clone()) {
            return None;
        }
        all_collision_keys.push(collision_key);
        match entry.kind {
            FILE_TRANSFER_LIST_ENTRY_FILE => {
                total_bytes = total_bytes.checked_add(entry.size)?;
                files.push(NativeViewerUploadFileAuthority {
                    relative_path: path.to_owned(),
                    size: entry.size,
                    modified_time: entry.modified_time,
                });
            }
            FILE_TRANSFER_LIST_ENTRY_DIRECTORY if entry.size == 0 && entry.modified_time == 0 => {
                empty_directories.push(path.to_owned());
            }
            _ => return None,
        }
    }
    if total_bytes != request.total_bytes {
        return None;
    }
    for path in &all_collision_keys {
        let components: Vec<_> = path.split('/').collect();
        let mut ancestor = String::new();
        for component in components.iter().take(components.len().saturating_sub(1)) {
            if !ancestor.is_empty() {
                ancestor.push('/');
            }
            ancestor.push_str(component);
            if collision_keys.contains(&ancestor) {
                return None;
            }
        }
    }
    let empty_directories = native_viewer_upload_directory_projection(&empty_directories)?;
    Some((files, empty_directories))
}

fn native_viewer_file_list_root_message() -> Message {
    let mut action = FileAction::new();
    action.set_read_dir(ReadDir {
        path: "/".to_owned(),
        include_hidden: false,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_file_action(action);
    message
}

fn native_viewer_file_manifest_root_messages(request_id: i32) -> (Message, Message) {
    let mut files_action = FileAction::new();
    files_action.set_all_files(ReadAllFiles {
        id: request_id,
        path: "/".to_owned(),
        include_hidden: false,
        ..Default::default()
    });
    let mut files_message = Message::new();
    files_message.set_file_action(files_action);

    let mut directories_action = FileAction::new();
    directories_action.set_read_empty_dirs(ReadEmptyDirs {
        path: "/".to_owned(),
        include_hidden: false,
        ..Default::default()
    });
    let mut directories_message = Message::new();
    directories_message.set_file_action(directories_action);
    (files_message, directories_message)
}

fn native_viewer_file_download_root_message(transfer_id: i32) -> Message {
    hbb_common::fs::new_send(
        transfer_id,
        hbb_common::fs::JobType::Generic,
        "/".to_owned(),
        0,
        false,
    )
}

fn client_clear_completed_manifest(shared: &BridgeShared, session_epoch: u64) {
    let mut completed = shared.completed_file_manifest_request.lock().unwrap();
    if completed
        .as_ref()
        .is_some_and(|request| request.session_epoch == session_epoch)
    {
        completed.take();
    }
}

fn viewer_file_transfer_mode_admission(
    enabled: bool,
    session_epoch: u64,
    desktop_capability_requested: bool,
) -> i32 {
    if enabled != (session_epoch > 0) {
        -5
    } else if enabled && desktop_capability_requested {
        -5
    } else {
        0
    }
}
