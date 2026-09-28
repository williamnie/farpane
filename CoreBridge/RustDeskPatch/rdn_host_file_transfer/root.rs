#[derive(Debug)]
struct NativeFileTransferRoot {
    directory: File,
}

impl NativeFileTransferRoot {
    fn open_existing(path: &Path) -> RootResult<Self> {
        let components = absolute_root_components(path)?;
        let root_path = CString::new("/").expect("root path has no NUL");
        let root_fd = unsafe {
            libc::open(
                root_path.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if root_fd < 0 {
            return Err(NativeFileTransferRootError::OpenRoot);
        }
        let mut directory = unsafe { File::from_raw_fd(root_fd) };
        validate_trusted_ancestor(&directory)?;

        for component in components {
            let component = component_c_string(component)
                .map_err(|_| NativeFileTransferRootError::InvalidRoot)?;
            let fd = unsafe {
                libc::openat(
                    directory.as_raw_fd(),
                    component.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(NativeFileTransferRootError::OpenRoot);
            }
            let next = unsafe { File::from_raw_fd(fd) };
            validate_trusted_ancestor(&next)?;
            directory = next;
        }
        validate_private_directory(&directory, NativeFileTransferRootError::UnsafeRoot)?;
        Ok(Self { directory })
    }

    fn create_new_file(&self, relative_path: &Path) -> RootResult<File> {
        let (parent, file_name) = self.open_relative_parent(relative_path, true)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                file_name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600 as libc::c_uint,
            )
        };
        if fd < 0 {
            return Err(NativeFileTransferRootError::CreateFile);
        }
        let file = unsafe { File::from_raw_fd(fd) };
        if unsafe { libc::fchmod(file.as_raw_fd(), 0o600 as libc::mode_t) } != 0 {
            return Err(NativeFileTransferRootError::CreateFile);
        }
        validate_private_regular_file(&file)?;
        Ok(file)
    }

    fn try_open_existing_file_for_resume(&self, relative_path: &Path) -> RootResult<Option<File>> {
        let (parent, file_name) = match self.open_relative_parent(relative_path, false) {
            Ok(value) => value,
            Err(NativeFileTransferRootError::OpenDirectory) => return Ok(None),
            Err(error) => return Err(error),
        };
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                file_name.as_ptr(),
                libc::O_RDWR | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
                return Ok(None);
            }
            return Err(NativeFileTransferRootError::OpenFile);
        }
        let file = unsafe { File::from_raw_fd(fd) };
        validate_private_regular_file(&file)?;
        Ok(Some(file))
    }

    fn try_open_existing_file_for_digest(&self, relative_path: &Path) -> RootResult<Option<File>> {
        let (parent, file_name) = match self.open_relative_parent(relative_path, false) {
            Ok(value) => value,
            Err(NativeFileTransferRootError::OpenDirectory) => return Ok(None),
            Err(error) => return Err(error),
        };
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                file_name.as_ptr(),
                libc::O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
                return Ok(None);
            }
            return Err(NativeFileTransferRootError::OpenFile);
        }
        let file = unsafe { File::from_raw_fd(fd) };
        validate_private_regular_file(&file)?;
        Ok(Some(file))
    }

    fn open_existing_file_for_resume(&self, relative_path: &Path) -> RootResult<File> {
        self.try_open_existing_file_for_resume(relative_path)?
            .ok_or(NativeFileTransferRootError::OpenFile)
    }

    fn create_directory(&self, relative_path: &Path) -> RootResult<()> {
        let (parent, directory_name) = self.open_relative_parent(relative_path, false)?;
        if unsafe {
            libc::mkdirat(
                parent.as_raw_fd(),
                directory_name.as_ptr(),
                0o700 as libc::mode_t,
            )
        } != 0
        {
            return Err(NativeFileTransferRootError::CreateDirectory);
        }
        set_created_directory_mode(&parent, &directory_name)?;
        let directory = open_private_child_directory(
            &parent,
            OsStr::from_bytes(directory_name.as_bytes()),
            false,
        )
        .map_err(|_| NativeFileTransferRootError::CreateDirectory)?;
        validate_private_directory(&directory, NativeFileTransferRootError::UnsafeDirectory)?;
        Ok(())
    }

    fn remove_file(&self, relative_path: &Path) -> RootResult<()> {
        let (parent, file_name) = self.open_relative_parent(relative_path, false)?;
        let stat = checked_stat_at(&parent, &file_name, NativeFileTransferRootError::RemoveFile)?;
        validate_private_regular_stat(&stat)?;
        if unsafe { libc::unlinkat(parent.as_raw_fd(), file_name.as_ptr(), 0) } != 0 {
            return Err(NativeFileTransferRootError::RemoveFile);
        }
        Ok(())
    }

    fn remove_file_if_exists(&self, relative_path: &Path) -> RootResult<bool> {
        let (parent, file_name) = match self.open_relative_parent(relative_path, false) {
            Ok(value) => value,
            Err(NativeFileTransferRootError::OpenDirectory) => return Ok(false),
            Err(error) => return Err(error),
        };
        let stat =
            match checked_stat_at(&parent, &file_name, NativeFileTransferRootError::RemoveFile) {
                Ok(stat) => stat,
                Err(NativeFileTransferRootError::RemoveFile)
                    if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) =>
                {
                    return Ok(false);
                }
                Err(error) => return Err(error),
            };
        validate_private_regular_stat(&stat)?;
        if unsafe { libc::unlinkat(parent.as_raw_fd(), file_name.as_ptr(), 0) } != 0 {
            return Err(NativeFileTransferRootError::RemoveFile);
        }
        Ok(true)
    }

    fn remove_empty_directory(&self, relative_path: &Path) -> RootResult<()> {
        let (parent, directory_name) = self.open_relative_parent(relative_path, false)?;
        let directory = open_private_child_directory(
            &parent,
            OsStr::from_bytes(directory_name.as_bytes()),
            false,
        )
        .map_err(|_| NativeFileTransferRootError::RemoveDirectory)?;
        validate_private_directory(&directory, NativeFileTransferRootError::UnsafeDirectory)?;
        if unsafe {
            libc::unlinkat(
                parent.as_raw_fd(),
                directory_name.as_ptr(),
                libc::AT_REMOVEDIR,
            )
        } != 0
        {
            return Err(NativeFileTransferRootError::RemoveDirectory);
        }
        Ok(())
    }

    fn rename_entry(&self, source: &Path, destination: &Path) -> RootResult<()> {
        let (source_parent, source_name) = self.open_relative_parent(source, false)?;
        let source_stat = checked_stat_at(
            &source_parent,
            &source_name,
            NativeFileTransferRootError::RenameEntry,
        )?;
        validate_private_entry_stat(&source_stat)?;
        let (destination_parent, destination_name) =
            self.open_relative_parent(destination, false)?;
        if unsafe {
            libc::renameatx_np(
                source_parent.as_raw_fd(),
                source_name.as_ptr(),
                destination_parent.as_raw_fd(),
                destination_name.as_ptr(),
                libc::RENAME_EXCL,
            )
        } != 0
        {
            return Err(NativeFileTransferRootError::RenameEntry);
        }
        Ok(())
    }

    fn list_directory(
        &self,
        relative_path: &Path,
        include_hidden: bool,
    ) -> RootResult<Vec<NativeHostReadEntry>> {
        let directory = self.open_relative_directory_for_read(relative_path)?;
        read_private_directory_entries(&directory, relative_path, include_hidden)
    }

    fn snapshot_files_recursive(
        &self,
        relative_path: &Path,
        include_hidden: bool,
    ) -> RootResult<Vec<NativeHostReadEntry>> {
        reject_reserved_read_path(relative_path)?;
        if !relative_path.as_os_str().is_empty() {
            let (parent, name) = self.open_relative_parent(relative_path, false)?;
            let stat = checked_stat_at(&parent, &name, NativeFileTransferRootError::ReadFile)?;
            match stat.st_mode & libc::S_IFMT {
                libc::S_IFREG => {
                    validate_private_regular_stat(&stat)?;
                    return Ok(vec![native_host_read_entry_from_stat(
                        relative_path.to_path_buf(),
                        String::new(),
                        NativeHostReadEntryKind::File,
                        &stat,
                    )?]);
                }
                libc::S_IFDIR => validate_private_directory_stat(&stat)?,
                _ => return Err(NativeFileTransferRootError::UnsafeFile),
            }
        }

        let mut files = Vec::new();
        let mut metadata_bytes = 0_usize;
        let mut visited_entries = 0_usize;
        self.snapshot_directory_recursive(
            relative_path,
            Path::new(""),
            include_hidden,
            0,
            &mut metadata_bytes,
            &mut visited_entries,
            &mut files,
        )?;
        Ok(files)
    }

    fn snapshot_directory_recursive(
        &self,
        directory_path: &Path,
        wire_prefix: &Path,
        include_hidden: bool,
        depth: usize,
        metadata_bytes: &mut usize,
        visited_entries: &mut usize,
        files: &mut Vec<NativeHostReadEntry>,
    ) -> RootResult<()> {
        if depth > NATIVE_HOST_READ_MAX_DEPTH {
            return Err(NativeFileTransferRootError::ReadLimitExceeded);
        }
        let entries = self.list_directory(directory_path, include_hidden)?;
        for mut entry in entries {
            *visited_entries = visited_entries
                .checked_add(1)
                .ok_or(NativeFileTransferRootError::ReadLimitExceeded)?;
            if *visited_entries > NATIVE_HOST_READ_MAX_ENTRIES {
                return Err(NativeFileTransferRootError::ReadLimitExceeded);
            }
            let wire_path = if wire_prefix.as_os_str().is_empty() {
                PathBuf::from(entry.wire_name())
            } else {
                wire_prefix.join(entry.wire_name())
            };
            let wire_name = wire_path
                .to_str()
                .ok_or(NativeFileTransferRootError::InvalidRelativePath)?
                .to_owned();
            *metadata_bytes = metadata_bytes
                .checked_add(wire_name.len())
                .ok_or(NativeFileTransferRootError::ReadLimitExceeded)?;
            if *metadata_bytes > NATIVE_HOST_READ_MAX_METADATA_BYTES {
                return Err(NativeFileTransferRootError::ReadLimitExceeded);
            }
            match entry.kind {
                NativeHostReadEntryKind::File => {
                    entry.wire_name = wire_name;
                    files.push(entry);
                }
                NativeHostReadEntryKind::Directory => self.snapshot_directory_recursive(
                    &entry.relative_path,
                    &wire_path,
                    include_hidden,
                    depth + 1,
                    metadata_bytes,
                    visited_entries,
                    files,
                )?,
            }
        }
        Ok(())
    }

    fn open_read_file(&self, entry: &NativeHostReadEntry) -> RootResult<File> {
        if entry.kind != NativeHostReadEntryKind::File {
            return Err(NativeFileTransferRootError::ReadFile);
        }
        reject_reserved_read_path(&entry.relative_path)?;
        let (parent, name) = self.open_relative_parent(&entry.relative_path, false)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(NativeFileTransferRootError::ReadFile);
        }
        let file = unsafe { File::from_raw_fd(fd) };
        self.verify_read_file(&file, entry)?;
        Ok(file)
    }

    fn verify_read_file(&self, file: &File, entry: &NativeHostReadEntry) -> RootResult<()> {
        if entry.kind != NativeHostReadEntryKind::File {
            return Err(NativeFileTransferRootError::ReadFile);
        }
        let stat = checked_stat(&file).map_err(|_| NativeFileTransferRootError::ReadFile)?;
        validate_private_regular_stat(&stat)?;
        let (modified_time, modified_time_nanoseconds) = native_host_modified_time(&stat)?;
        let (change_time, change_time_nanoseconds) = native_host_change_time(&stat)?;
        if stat.st_dev as u64 != entry.device
            || stat.st_ino as u64 != entry.inode
            || stat.st_size < 0
            || stat.st_size as u64 != entry.size
            || modified_time != entry.modified_time
            || modified_time_nanoseconds != entry.modified_time_nanoseconds
            || change_time != entry.change_time
            || change_time_nanoseconds != entry.change_time_nanoseconds
        {
            return Err(NativeFileTransferRootError::ReadSnapshotChanged);
        }
        Ok(())
    }

    fn snapshot_empty_directories(
        &self,
        relative_path: &Path,
        include_hidden: bool,
    ) -> RootResult<Vec<PathBuf>> {
        reject_reserved_read_path(relative_path)?;
        self.open_relative_directory_for_read(relative_path)?;
        let mut empty_directories = Vec::new();
        let mut metadata_bytes = 0_usize;
        let mut visited_entries = 0_usize;
        self.snapshot_empty_directories_recursive(
            relative_path,
            include_hidden,
            0,
            &mut metadata_bytes,
            &mut visited_entries,
            &mut empty_directories,
        )?;
        Ok(empty_directories)
    }

    fn snapshot_empty_directories_recursive(
        &self,
        directory_path: &Path,
        include_hidden: bool,
        depth: usize,
        metadata_bytes: &mut usize,
        visited_entries: &mut usize,
        empty_directories: &mut Vec<PathBuf>,
    ) -> RootResult<()> {
        if depth > NATIVE_HOST_READ_MAX_DEPTH {
            return Err(NativeFileTransferRootError::ReadLimitExceeded);
        }
        let entries = self.list_directory(directory_path, include_hidden)?;
        if entries.is_empty() {
            empty_directories.push(directory_path.to_path_buf());
            return Ok(());
        }
        for entry in entries {
            *visited_entries = visited_entries
                .checked_add(1)
                .ok_or(NativeFileTransferRootError::ReadLimitExceeded)?;
            if *visited_entries > NATIVE_HOST_READ_MAX_ENTRIES {
                return Err(NativeFileTransferRootError::ReadLimitExceeded);
            }
            *metadata_bytes = metadata_bytes
                .checked_add(entry.relative_path.as_os_str().as_bytes().len())
                .ok_or(NativeFileTransferRootError::ReadLimitExceeded)?;
            if *metadata_bytes > NATIVE_HOST_READ_MAX_METADATA_BYTES {
                return Err(NativeFileTransferRootError::ReadLimitExceeded);
            }
            if entry.kind == NativeHostReadEntryKind::Directory {
                self.snapshot_empty_directories_recursive(
                    &entry.relative_path,
                    include_hidden,
                    depth + 1,
                    metadata_bytes,
                    visited_entries,
                    empty_directories,
                )?;
            }
        }
        Ok(())
    }

    fn open_relative_directory_for_read(&self, relative_path: &Path) -> RootResult<File> {
        if relative_path.as_os_str().is_empty() {
            return self
                .directory
                .try_clone()
                .map_err(|_| NativeFileTransferRootError::ReadDirectory);
        }
        reject_reserved_read_path(relative_path)?;
        let mut directory = self
            .directory
            .try_clone()
            .map_err(|_| NativeFileTransferRootError::ReadDirectory)?;
        for component in relative_path_components(relative_path)? {
            directory = open_private_child_directory(&directory, component, false)
                .map_err(|_| NativeFileTransferRootError::ReadDirectory)?;
        }
        Ok(directory)
    }

    fn open_relative_parent(
        &self,
        relative_path: &Path,
        create_missing: bool,
    ) -> RootResult<(File, CString)> {
        let mut components = relative_path_components(relative_path)?;
        let file_name = components
            .pop()
            .ok_or(NativeFileTransferRootError::InvalidRelativePath)?;
        let file_name = component_c_string(file_name)?;
        let mut parent = self
            .directory
            .try_clone()
            .map_err(|_| NativeFileTransferRootError::OpenDirectory)?;

        for component in components {
            parent = open_private_child_directory(&parent, component, create_missing)?;
        }
        Ok((parent, file_name))
    }
}
