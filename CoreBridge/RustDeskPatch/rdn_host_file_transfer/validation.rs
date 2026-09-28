fn absolute_root_components(path: &Path) -> RootResult<Vec<&OsStr>> {
    if !path.is_absolute() {
        return Err(NativeFileTransferRootError::InvalidRoot);
    }
    let bytes = path.as_os_str().as_bytes();
    if bytes.is_empty() || bytes.contains(&0) {
        return Err(NativeFileTransferRootError::InvalidRoot);
    }
    let components = path
        .components()
        .filter_map(|component| match component {
            std::path::Component::RootDir => None,
            std::path::Component::Normal(value) => Some(Ok(value)),
            _ => Some(Err(NativeFileTransferRootError::InvalidRoot)),
        })
        .collect::<RootResult<Vec<_>>>()?;
    if components.is_empty() {
        return Err(NativeFileTransferRootError::InvalidRoot);
    }
    Ok(components)
}

fn relative_path_components(path: &Path) -> RootResult<Vec<&OsStr>> {
    let bytes = path.as_os_str().as_bytes();
    if bytes.is_empty()
        || bytes.starts_with(b"/")
        || bytes.ends_with(b"/")
        || bytes.contains(&0)
        || bytes
            .split(|byte| *byte == b'/')
            .any(|component| component.is_empty() || component == b"." || component == b"..")
    {
        return Err(NativeFileTransferRootError::InvalidRelativePath);
    }
    path.components()
        .map(|component| match component {
            std::path::Component::Normal(value) => Ok(value),
            _ => Err(NativeFileTransferRootError::InvalidRelativePath),
        })
        .collect()
}

fn component_c_string(component: &OsStr) -> RootResult<CString> {
    CString::new(component.as_bytes()).map_err(|_| NativeFileTransferRootError::InvalidRelativePath)
}

fn checked_stat(file: &File) -> RootResult<libc::stat> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(file.as_raw_fd(), stat.as_mut_ptr()) } != 0 {
        return Err(NativeFileTransferRootError::UnsafeFile);
    }
    Ok(unsafe { stat.assume_init() })
}

fn checked_stat_at(
    parent: &File,
    name: &CString,
    error: NativeFileTransferRootError,
) -> RootResult<libc::stat> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(error);
    }
    Ok(unsafe { stat.assume_init() })
}

fn validate_trusted_ancestor(directory: &File) -> RootResult<()> {
    let stat = checked_stat(directory).map_err(|_| NativeFileTransferRootError::UnsafeRoot)?;
    let effective_uid = unsafe { libc::geteuid() };
    if stat.st_mode & libc::S_IFMT != libc::S_IFDIR
        || (stat.st_uid != 0 && stat.st_uid != effective_uid)
        || stat.st_mode & 0o022 != 0
    {
        return Err(NativeFileTransferRootError::UnsafeRoot);
    }
    Ok(())
}

fn validate_private_directory(
    directory: &File,
    error: NativeFileTransferRootError,
) -> RootResult<()> {
    let stat = checked_stat(directory).map_err(|_| error)?;
    if stat.st_mode & libc::S_IFMT != libc::S_IFDIR
        || stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_mode & 0o777 != 0o700
    {
        return Err(error);
    }
    Ok(())
}

fn open_private_child_directory(
    parent: &File,
    component: &OsStr,
    create_missing: bool,
) -> RootResult<File> {
    let component = component_c_string(component)?;
    let mut fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            component.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0
        && create_missing
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT)
    {
        let mkdir_result = unsafe {
            libc::mkdirat(
                parent.as_raw_fd(),
                component.as_ptr(),
                0o700 as libc::mode_t,
            )
        };
        if mkdir_result != 0 {
            return Err(NativeFileTransferRootError::CreateDirectory);
        }
        set_created_directory_mode(parent, &component)?;
        fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                component.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
    }
    if fd < 0 {
        return Err(NativeFileTransferRootError::OpenDirectory);
    }
    let directory = unsafe { File::from_raw_fd(fd) };
    validate_private_directory(&directory, NativeFileTransferRootError::UnsafeDirectory)?;
    Ok(directory)
}

fn set_created_directory_mode(parent: &File, name: &CString) -> RootResult<()> {
    if unsafe {
        libc::fchmodat(
            parent.as_raw_fd(),
            name.as_ptr(),
            0o700 as libc::mode_t,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(NativeFileTransferRootError::CreateDirectory);
    }
    Ok(())
}

fn validate_private_regular_file(file: &File) -> RootResult<()> {
    let stat = checked_stat(file)?;
    validate_private_regular_stat(&stat)
}

fn validate_private_regular_stat(stat: &libc::stat) -> RootResult<()> {
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_mode & 0o777 != 0o600
        || stat.st_nlink != 1
    {
        return Err(NativeFileTransferRootError::UnsafeFile);
    }
    Ok(())
}

fn validate_private_entry_stat(stat: &libc::stat) -> RootResult<()> {
    match stat.st_mode & libc::S_IFMT {
        libc::S_IFREG => validate_private_regular_stat(stat),
        libc::S_IFDIR
            if stat.st_uid == unsafe { libc::geteuid() } && stat.st_mode & 0o777 == 0o700 =>
        {
            Ok(())
        }
        libc::S_IFDIR => Err(NativeFileTransferRootError::UnsafeDirectory),
        _ => Err(NativeFileTransferRootError::UnsafeFile),
    }
}
