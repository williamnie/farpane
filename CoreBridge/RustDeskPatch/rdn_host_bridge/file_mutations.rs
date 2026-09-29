#[cfg(target_os = "macos")]
fn prepare_native_host_write_job(
    id: i32,
    owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
    base_path: &str,
    start_file_num: i32,
    entries: Vec<NativeHostWriteEntry>,
    total_size: u64,
    overwrite_detection: bool,
) -> Result<NativeHostWriteJob, NativeHostWriteJobError> {
    if start_file_num != 0 || entries.is_empty() {
        return Err(NativeHostWriteJobError::InvalidBatch);
    }
    if entries.len() > MAX_NATIVE_HOST_WRITE_FILES {
        return Err(NativeHostWriteJobError::TooManyFiles);
    }
    let base_is_receive_root = base_path.is_empty();
    let base_path = Path::new(base_path);
    if !base_is_receive_root && !native_host_write_relative_path_is_valid(base_path) {
        return Err(NativeHostWriteJobError::InvalidPath);
    }
    let mut metadata_bytes = base_path.as_os_str().as_bytes().len();
    let mut expected_total_size = 0_u64;
    let mut destinations = HashSet::with_capacity(entries.len());
    let mut prepared = Vec::with_capacity(entries.len());
    let single_entry = entries.len() == 1;
    for entry in entries {
        metadata_bytes = metadata_bytes
            .checked_add(entry.name.len())
            .ok_or(NativeHostWriteJobError::MetadataTooLarge)?;
        if metadata_bytes > MAX_NATIVE_HOST_WRITE_METADATA_BYTES {
            return Err(NativeHostWriteJobError::MetadataTooLarge);
        }
        if entry.modified_time > i64::MAX as u64 {
            return Err(NativeHostWriteJobError::InvalidBatch);
        }
        expected_total_size = expected_total_size
            .checked_add(entry.expected_size)
            .ok_or(NativeHostWriteJobError::TotalSizeMismatch)?;
        let destination_path = if base_is_receive_root {
            if entry.name.is_empty() {
                return Err(NativeHostWriteJobError::InvalidPath);
            }
            PathBuf::from(&entry.name)
        } else if single_entry && entry.name.is_empty() {
            base_path.to_path_buf()
        } else {
            if entry.name.is_empty() {
                return Err(NativeHostWriteJobError::InvalidPath);
            }
            base_path.join(&entry.name)
        };
        if !native_host_write_relative_path_is_valid(&destination_path)
            || native_host_file_path_is_reserved(&destination_path)
            || destination_path.as_os_str().as_bytes().len() > MAX_NATIVE_HOST_WRITE_PATH_BYTES
        {
            return Err(NativeHostWriteJobError::InvalidPath);
        }
        if !destinations.insert(destination_path.clone()) {
            return Err(NativeHostWriteJobError::DuplicateDestination);
        }
        let staging_path = native_host_write_staging_path(&destination_path)?;
        prepared.push(NativeHostPreparedWriteEntry {
            destination_path,
            staging_path,
            expected_size: entry.expected_size,
            modified_time: entry.modified_time,
        });
    }
    if total_size != expected_total_size {
        return Err(NativeHostWriteJobError::TotalSizeMismatch);
    }
    let staging_paths = prepared
        .iter()
        .map(|entry| entry.staging_path.clone())
        .collect::<Vec<_>>();
    let reservations = owner
        .reserve_write_paths(&staging_paths)
        .map_err(|error| match error {
            rdn_host_file_transfer::NativeFileTransferRootError::WritePathBusy => {
                NativeHostWriteJobError::DuplicateDestination
            }
            _ => NativeHostWriteJobError::InvalidPath,
        })?;
    Ok(NativeHostWriteJob {
        id,
        owner,
        _reservations: reservations,
        entries: prepared,
        current: None,
        next_file_num: 0,
        expected_total_size,
        written_total_size: 0,
        skipped_total_size: 0,
        overwrite_detection,
        awaiting_existing_target: None,
    })
}

#[cfg(target_os = "macos")]
fn native_host_write_relative_path_is_valid(path: &Path) -> bool {
    let bytes = path.as_os_str().as_bytes();
    !bytes.is_empty()
        && !bytes.starts_with(b"/")
        && !bytes.ends_with(b"/")
        && !bytes.contains(&0)
        && !bytes
            .split(|byte| *byte == b'/')
            .any(|component| component.is_empty() || component == b"." || component == b"..")
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

#[cfg(target_os = "macos")]
fn native_host_file_path_is_reserved(path: &Path) -> bool {
    path.components().any(|component| {
        let Component::Normal(component) = component else {
            return false;
        };
        component
            .as_bytes()
            .ends_with(NATIVE_HOST_WRITE_STAGING_SUFFIX.as_bytes())
    })
}

#[cfg(target_os = "macos")]
fn native_host_write_staging_path(
    destination_path: &Path,
) -> Result<PathBuf, NativeHostWriteJobError> {
    let file_name = destination_path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or(NativeHostWriteJobError::InvalidPath)?;
    let staging_name = format!("{file_name}{NATIVE_HOST_WRITE_STAGING_SUFFIX}");
    let staging_path = destination_path.with_file_name(staging_name);
    if staging_path.as_os_str().as_bytes().len() > MAX_NATIVE_HOST_WRITE_PATH_BYTES {
        return Err(NativeHostWriteJobError::InvalidPath);
    }
    Ok(staging_path)
}

#[cfg(target_os = "macos")]
fn native_host_set_file_modified_time(
    file: &File,
    modified_time: u64,
) -> Result<(), NativeHostWriteJobError> {
    let times = [
        libc::timespec {
            tv_sec: 0,
            tv_nsec: libc::UTIME_OMIT,
        },
        libc::timespec {
            tv_sec: modified_time as libc::time_t,
            tv_nsec: 0,
        },
    ];
    if unsafe { libc::futimens(file.as_raw_fd(), times.as_ptr()) } != 0 {
        return Err(NativeHostWriteJobError::Storage);
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn native_host_rename_destination(path: &str, new_name: &str) -> Option<PathBuf> {
    let mut components = Path::new(new_name).components();
    let Component::Normal(new_name) = components.next()? else {
        return None;
    };
    if components.next().is_some() {
        return None;
    }
    Path::new(path).parent().map(|parent| parent.join(new_name))
}

#[cfg(target_os = "macos")]
fn apply_native_host_file_mutation(
    owner: &rdn_host_file_transfer::NativeHostFileServiceOwner,
    mutation: NativeHostFileMutation<'_>,
) -> Result<(), rdn_host_file_transfer::NativeFileTransferRootError> {
    let path = match mutation {
        NativeHostFileMutation::CreateDirectory { path }
        | NativeHostFileMutation::RemoveFile { path }
        | NativeHostFileMutation::RemoveDirectory { path, .. }
        | NativeHostFileMutation::Rename { path, .. } => Path::new(path),
    };
    if native_host_file_path_is_reserved(path) {
        return Err(rdn_host_file_transfer::NativeFileTransferRootError::InvalidRelativePath);
    }
    match mutation {
        NativeHostFileMutation::CreateDirectory { path } => owner.create_directory(Path::new(path)),
        NativeHostFileMutation::RemoveFile { path } => owner.remove_file(Path::new(path)),
        NativeHostFileMutation::RemoveDirectory { path, recursive } => {
            owner.remove_directory(Path::new(path), recursive)
        }
        NativeHostFileMutation::Rename { path, new_name } => {
            let destination = native_host_rename_destination(path, new_name)
                .ok_or(rdn_host_file_transfer::NativeFileTransferRootError::InvalidRelativePath)?;
            if native_host_file_path_is_reserved(&destination) {
                return Err(
                    rdn_host_file_transfer::NativeFileTransferRootError::InvalidRelativePath,
                );
            }
            owner.rename_entry(Path::new(path), &destination)
        }
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_dispatch_file_mutation(
    mutation: NativeHostFileMutation<'_>,
) -> NativeHostFileMutationOutcome {
    let broker = MEDIA_BROKER.lock().unwrap();
    if broker.binding.is_none() {
        return if HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
            NativeHostFileMutationOutcome::Unavailable
        } else {
            NativeHostFileMutationOutcome::NotNativeHost
        };
    }
    let Some(owner) = broker.file_service_owner.as_deref() else {
        return NativeHostFileMutationOutcome::Unavailable;
    };
    match apply_native_host_file_mutation(owner, mutation) {
        Ok(()) => NativeHostFileMutationOutcome::Succeeded,
        Err(_) => NativeHostFileMutationOutcome::Rejected,
    }
}

fn native_host_session_availability_payload(
    available: bool,
) -> (&'static str, Option<&'static str>) {
    if available {
        ("available", None)
    } else {
        ("limited", Some("sessionUnavailable"))
    }
}
