struct NativeDirectoryStream(*mut libc::DIR);

impl Drop for NativeDirectoryStream {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
}

fn read_private_directory_entries(
    directory: &File,
    relative_path: &Path,
    include_hidden: bool,
) -> RootResult<Vec<NativeHostReadEntry>> {
    let current_directory = CString::new(".").expect("current directory has no NUL");
    let duplicated_fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            current_directory.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if duplicated_fd < 0 {
        return Err(NativeFileTransferRootError::ReadDirectory);
    }
    let stream = unsafe { libc::fdopendir(duplicated_fd) };
    if stream.is_null() {
        unsafe {
            libc::close(duplicated_fd);
        }
        return Err(NativeFileTransferRootError::ReadDirectory);
    }
    let stream = NativeDirectoryStream(stream);
    let mut entries = Vec::new();
    let mut metadata_bytes = 0_usize;
    loop {
        unsafe {
            *libc::__error() = 0;
        }
        let raw_entry = unsafe { libc::readdir(stream.0) };
        if raw_entry.is_null() {
            if std::io::Error::last_os_error().raw_os_error() == Some(0) {
                break;
            }
            return Err(NativeFileTransferRootError::ReadDirectory);
        }
        let name_bytes = unsafe { CStr::from_ptr((*raw_entry).d_name.as_ptr()) }.to_bytes();
        if name_bytes == b"." || name_bytes == b".." {
            continue;
        }
        if name_bytes.ends_with(NATIVE_HOST_PRIVATE_STAGING_SUFFIX) {
            continue;
        }
        let is_hidden = name_bytes.first() == Some(&b'.');
        if is_hidden && !include_hidden {
            continue;
        }
        let name = std::str::from_utf8(name_bytes)
            .map_err(|_| NativeFileTransferRootError::InvalidRelativePath)?
            .to_owned();
        metadata_bytes = metadata_bytes
            .checked_add(name.len())
            .ok_or(NativeFileTransferRootError::ReadLimitExceeded)?;
        if entries.len() >= NATIVE_HOST_READ_MAX_ENTRIES
            || metadata_bytes > NATIVE_HOST_READ_MAX_METADATA_BYTES
        {
            return Err(NativeFileTransferRootError::ReadLimitExceeded);
        }
        let c_name = CString::new(name_bytes)
            .map_err(|_| NativeFileTransferRootError::InvalidRelativePath)?;
        let stat = checked_stat_at(
            directory,
            &c_name,
            NativeFileTransferRootError::ReadDirectory,
        )?;
        let kind = match stat.st_mode & libc::S_IFMT {
            libc::S_IFREG => {
                validate_private_regular_stat(&stat)?;
                NativeHostReadEntryKind::File
            }
            libc::S_IFDIR => {
                validate_private_directory_stat(&stat)?;
                NativeHostReadEntryKind::Directory
            }
            _ => return Err(NativeFileTransferRootError::UnsafeFile),
        };
        let path = if relative_path.as_os_str().is_empty() {
            PathBuf::from(&name)
        } else {
            relative_path.join(&name)
        };
        entries.push(native_host_read_entry_from_stat(path, name, kind, &stat)?);
    }
    entries.sort_by(|left, right| left.wire_name.as_bytes().cmp(right.wire_name.as_bytes()));
    Ok(entries)
}

fn native_host_read_entry_from_stat(
    relative_path: PathBuf,
    wire_name: String,
    kind: NativeHostReadEntryKind,
    stat: &libc::stat,
) -> RootResult<NativeHostReadEntry> {
    if stat.st_size < 0 {
        return Err(NativeFileTransferRootError::ReadFile);
    }
    let (modified_time, modified_time_nanoseconds) = native_host_modified_time(stat)?;
    let (change_time, change_time_nanoseconds) = native_host_change_time(stat)?;
    Ok(NativeHostReadEntry {
        relative_path,
        wire_name,
        kind,
        size: if kind == NativeHostReadEntryKind::File {
            stat.st_size as u64
        } else {
            0
        },
        modified_time,
        modified_time_nanoseconds,
        change_time,
        change_time_nanoseconds,
        device: stat.st_dev as u64,
        inode: stat.st_ino as u64,
    })
}

fn native_host_modified_time(stat: &libc::stat) -> RootResult<(u64, i64)> {
    if stat.st_mtime < 0 || !(0..1_000_000_000).contains(&stat.st_mtime_nsec) {
        return Err(NativeFileTransferRootError::ReadFile);
    }
    Ok((stat.st_mtime as u64, stat.st_mtime_nsec))
}

fn native_host_change_time(stat: &libc::stat) -> RootResult<(u64, i64)> {
    if stat.st_ctime < 0 || !(0..1_000_000_000).contains(&stat.st_ctime_nsec) {
        return Err(NativeFileTransferRootError::ReadFile);
    }
    Ok((stat.st_ctime as u64, stat.st_ctime_nsec))
}

fn validate_private_directory_stat(stat: &libc::stat) -> RootResult<()> {
    if stat.st_mode & libc::S_IFMT != libc::S_IFDIR
        || stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_mode & 0o777 != 0o700
    {
        return Err(NativeFileTransferRootError::UnsafeDirectory);
    }
    Ok(())
}

fn reject_reserved_read_path(path: &Path) -> RootResult<()> {
    if path
        .as_os_str()
        .as_bytes()
        .split(|byte| *byte == b'/')
        .any(|component| component.ends_with(NATIVE_HOST_PRIVATE_STAGING_SUFFIX))
    {
        return Err(NativeFileTransferRootError::InvalidRelativePath);
    }
    Ok(())
}
