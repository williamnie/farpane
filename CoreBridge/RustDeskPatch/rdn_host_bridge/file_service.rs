#[cfg(target_os = "macos")]
pub(crate) enum NativeHostWriteJobAdmission {
    NotNativeHost,
    Admitted(NativeHostWriteJob),
    Rejected(NativeHostWriteJobError),
    Unavailable,
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_write_service_state() -> NativeHostWriteServiceState {
    let broker = MEDIA_BROKER.lock().unwrap();
    if broker.binding.is_none() {
        return if HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
            NativeHostWriteServiceState::Unavailable
        } else {
            NativeHostWriteServiceState::NotNativeHost
        };
    }
    if broker.file_service_owner.is_some() {
        NativeHostWriteServiceState::Available
    } else {
        NativeHostWriteServiceState::Unavailable
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_begin_new_file_write_job(
    id: i32,
    base_path: &str,
    start_file_num: i32,
    entries: Vec<NativeHostWriteEntry>,
    total_size: u64,
    overwrite_detection: bool,
) -> NativeHostWriteJobAdmission {
    let owner = {
        let broker = MEDIA_BROKER.lock().unwrap();
        if broker.binding.is_none() {
            return if HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
                NativeHostWriteJobAdmission::Unavailable
            } else {
                NativeHostWriteJobAdmission::NotNativeHost
            };
        }
        let Some(owner) = broker.file_service_owner.as_ref() else {
            return NativeHostWriteJobAdmission::Unavailable;
        };
        owner.clone()
    };
    match prepare_native_host_write_job(
        id,
        owner,
        base_path,
        start_file_num,
        entries,
        total_size,
        overwrite_detection,
    ) {
        Ok(job) => NativeHostWriteJobAdmission::Admitted(job),
        Err(error) => NativeHostWriteJobAdmission::Rejected(error),
    }
}

#[cfg(target_os = "macos")]
enum NativeHostReadOwnerState {
    NotNativeHost,
    Available(Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>),
    Unavailable,
}

#[cfg(target_os = "macos")]
fn native_host_read_owner() -> NativeHostReadOwnerState {
    let broker = MEDIA_BROKER.lock().unwrap();
    if broker.binding.is_none() {
        return if HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
            NativeHostReadOwnerState::Unavailable
        } else {
            NativeHostReadOwnerState::NotNativeHost
        };
    }
    match broker.file_service_owner.as_ref() {
        Some(owner) => NativeHostReadOwnerState::Available(owner.clone()),
        None => NativeHostReadOwnerState::Unavailable,
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_list_directory(
    path: &str,
    include_hidden: bool,
) -> NativeHostFileReadOutcome<(String, Vec<NativeHostReadListEntry>)> {
    let owner = match native_host_read_owner() {
        NativeHostReadOwnerState::NotNativeHost => {
            return NativeHostFileReadOutcome::NotNativeHost;
        }
        NativeHostReadOwnerState::Unavailable => {
            return NativeHostFileReadOutcome::Unavailable;
        }
        NativeHostReadOwnerState::Available(owner) => owner,
    };
    let (relative_path, wire_path) = match native_host_read_wire_path(path) {
        Ok(value) => value,
        Err(error) => return NativeHostFileReadOutcome::Rejected(error),
    };
    match owner.list_directory(&relative_path, include_hidden) {
        Ok(entries) => NativeHostFileReadOutcome::Succeeded((
            wire_path,
            entries.iter().map(native_host_read_list_entry).collect(),
        )),
        Err(error) => NativeHostFileReadOutcome::Rejected(native_host_read_job_error(error)),
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_list_files_recursive(
    path: &str,
    include_hidden: bool,
) -> NativeHostFileReadOutcome<(String, Vec<NativeHostReadListEntry>)> {
    let owner = match native_host_read_owner() {
        NativeHostReadOwnerState::NotNativeHost => {
            return NativeHostFileReadOutcome::NotNativeHost;
        }
        NativeHostReadOwnerState::Unavailable => {
            return NativeHostFileReadOutcome::Unavailable;
        }
        NativeHostReadOwnerState::Available(owner) => owner,
    };
    let (relative_path, wire_path) = match native_host_read_wire_path(path) {
        Ok(value) => value,
        Err(error) => return NativeHostFileReadOutcome::Rejected(error),
    };
    match owner.snapshot_files_recursive(&relative_path, include_hidden) {
        Ok(entries) => NativeHostFileReadOutcome::Succeeded((
            wire_path,
            entries.iter().map(native_host_read_list_entry).collect(),
        )),
        Err(error) => NativeHostFileReadOutcome::Rejected(native_host_read_job_error(error)),
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_list_empty_directories(
    path: &str,
    include_hidden: bool,
) -> NativeHostFileReadOutcome<(String, Vec<String>)> {
    let owner = match native_host_read_owner() {
        NativeHostReadOwnerState::NotNativeHost => {
            return NativeHostFileReadOutcome::NotNativeHost;
        }
        NativeHostReadOwnerState::Unavailable => {
            return NativeHostFileReadOutcome::Unavailable;
        }
        NativeHostReadOwnerState::Available(owner) => owner,
    };
    let (relative_path, wire_path) = match native_host_read_wire_path(path) {
        Ok(value) => value,
        Err(error) => return NativeHostFileReadOutcome::Rejected(error),
    };
    match owner.snapshot_empty_directories(&relative_path, include_hidden) {
        Ok(paths) => {
            let mut wire_paths = Vec::with_capacity(paths.len());
            for path in paths {
                match native_host_relative_to_wire_path(&path) {
                    Ok(path) => wire_paths.push(path),
                    Err(error) => return NativeHostFileReadOutcome::Rejected(error),
                }
            }
            NativeHostFileReadOutcome::Succeeded((wire_path, wire_paths))
        }
        Err(error) => NativeHostFileReadOutcome::Rejected(native_host_read_job_error(error)),
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_begin_read_job(
    id: i32,
    path: &str,
    start_file_num: i32,
    include_hidden: bool,
    overwrite_detection: bool,
) -> NativeHostReadJobAdmission {
    let owner = match native_host_read_owner() {
        NativeHostReadOwnerState::NotNativeHost => {
            return NativeHostReadJobAdmission::NotNativeHost;
        }
        NativeHostReadOwnerState::Unavailable => {
            return NativeHostReadJobAdmission::Unavailable;
        }
        NativeHostReadOwnerState::Available(owner) => owner,
    };
    let (relative_path, wire_path) = match native_host_read_wire_path(path) {
        Ok(value) => value,
        Err(error) => return NativeHostReadJobAdmission::Rejected(error),
    };
    let entries = match owner.snapshot_files_recursive(&relative_path, include_hidden) {
        Ok(entries) => entries,
        Err(error) => {
            return NativeHostReadJobAdmission::Rejected(native_host_read_job_error(error));
        }
    };
    let start_file_num = match usize::try_from(start_file_num) {
        Ok(value) => value,
        Err(_) => {
            return NativeHostReadJobAdmission::Rejected(NativeHostReadJobError::InvalidFileNumber);
        }
    };
    if (entries.is_empty() && start_file_num != 0)
        || (!entries.is_empty() && start_file_num >= entries.len())
    {
        return NativeHostReadJobAdmission::Rejected(NativeHostReadJobError::InvalidFileNumber);
    }
    NativeHostReadJobAdmission::Admitted(NativeHostReadJob {
        id,
        owner,
        wire_path,
        entries,
        next_file_num: start_file_num,
        current_file: None,
        current_offset: 0,
        awaiting_confirmation: None,
        overwrite_detection,
    })
}

#[cfg(target_os = "macos")]
fn native_host_read_wire_path(path: &str) -> Result<(PathBuf, String), NativeHostReadJobError> {
    if path.is_empty() || path == "/" {
        return Ok((PathBuf::new(), "/".to_owned()));
    }
    let relative = path.strip_prefix('/').unwrap_or(path);
    if relative.is_empty()
        || relative.starts_with('/')
        || relative.ends_with('/')
        || relative.as_bytes().contains(&0)
    {
        return Err(NativeHostReadJobError::InvalidPath);
    }
    let relative_path = PathBuf::from(relative);
    if relative_path.components().any(|component| {
        !matches!(component, Component::Normal(value) if value.as_bytes() != b"." && value.as_bytes() != b"..")
    }) {
        return Err(NativeHostReadJobError::InvalidPath);
    }
    Ok((relative_path, format!("/{relative}")))
}

#[cfg(target_os = "macos")]
fn native_host_relative_to_wire_path(path: &Path) -> Result<String, NativeHostReadJobError> {
    if path.as_os_str().is_empty() {
        return Ok("/".to_owned());
    }
    let path = path.to_str().ok_or(NativeHostReadJobError::InvalidPath)?;
    Ok(format!("/{path}"))
}

#[cfg(target_os = "macos")]
fn native_host_read_list_entry(
    entry: &rdn_host_file_transfer::NativeHostReadEntry,
) -> NativeHostReadListEntry {
    NativeHostReadListEntry {
        name: entry.wire_name().to_owned(),
        kind: match entry.kind() {
            rdn_host_file_transfer::NativeHostReadEntryKind::Directory => {
                NativeHostReadEntryKind::Directory
            }
            rdn_host_file_transfer::NativeHostReadEntryKind::File => NativeHostReadEntryKind::File,
        },
        size: entry.size(),
        modified_time: entry.modified_time(),
    }
}

#[cfg(target_os = "macos")]
fn native_host_read_job_error(
    error: rdn_host_file_transfer::NativeFileTransferRootError,
) -> NativeHostReadJobError {
    match error {
        rdn_host_file_transfer::NativeFileTransferRootError::InvalidRelativePath => {
            NativeHostReadJobError::InvalidPath
        }
        rdn_host_file_transfer::NativeFileTransferRootError::ReadSnapshotChanged => {
            NativeHostReadJobError::SnapshotChanged
        }
        _ => NativeHostReadJobError::ReadFailed,
    }
}
