#[allow(dead_code)]
#[derive(Debug)]
pub(crate) struct NativeHostFileServiceOwner {
    root: NativeFileTransferRoot,
    write_reservations: Mutex<HashSet<PathBuf>>,
}

#[derive(Debug)]
pub(crate) struct NativeHostWriteReservations {
    owner: Arc<NativeHostFileServiceOwner>,
    paths: Vec<PathBuf>,
}

impl Drop for NativeHostWriteReservations {
    fn drop(&mut self) {
        let mut reservations = self
            .owner
            .write_reservations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for path in &self.paths {
            reservations.remove(path);
        }
    }
}

#[allow(dead_code)]
impl NativeHostFileServiceOwner {
    pub(crate) fn from_immutable_configuration(
        enabled: bool,
        root_path: Option<&Path>,
    ) -> RootResult<Option<Self>> {
        match (enabled, root_path) {
            (false, None) => Ok(None),
            (true, Some(root_path)) => Self::open_existing(root_path).map(Some),
            _ => Err(NativeFileTransferRootError::InvalidOwnerConfiguration),
        }
    }

    pub(crate) fn open_existing(root_path: &Path) -> RootResult<Self> {
        Ok(Self {
            root: NativeFileTransferRoot::open_existing(root_path)?,
            write_reservations: Mutex::new(HashSet::new()),
        })
    }

    pub(crate) fn reserve_write_paths(
        self: &Arc<Self>,
        relative_paths: &[PathBuf],
    ) -> RootResult<NativeHostWriteReservations> {
        if relative_paths.is_empty() {
            return Err(NativeFileTransferRootError::InvalidRelativePath);
        }
        let mut unique = HashSet::with_capacity(relative_paths.len());
        for path in relative_paths {
            relative_path_components(path)?;
            if !unique.insert(path.clone()) {
                return Err(NativeFileTransferRootError::InvalidRelativePath);
            }
        }

        let mut reservations = self
            .write_reservations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if unique.iter().any(|path| reservations.contains(path)) {
            return Err(NativeFileTransferRootError::WritePathBusy);
        }
        reservations.extend(unique.iter().cloned());
        drop(reservations);
        Ok(NativeHostWriteReservations {
            owner: self.clone(),
            paths: unique.into_iter().collect(),
        })
    }

    pub(crate) fn create_new_file(&self, relative_path: &Path) -> RootResult<File> {
        self.root.create_new_file(relative_path)
    }

    pub(crate) fn open_existing_file_for_resume(&self, relative_path: &Path) -> RootResult<File> {
        self.root.open_existing_file_for_resume(relative_path)
    }

    pub(crate) fn try_open_existing_file_for_resume(
        &self,
        relative_path: &Path,
    ) -> RootResult<Option<File>> {
        self.root.try_open_existing_file_for_resume(relative_path)
    }

    pub(crate) fn try_open_existing_file_for_digest(
        &self,
        relative_path: &Path,
    ) -> RootResult<Option<File>> {
        self.root.try_open_existing_file_for_digest(relative_path)
    }

    pub(crate) fn create_directory(&self, relative_path: &Path) -> RootResult<()> {
        self.root.create_directory(relative_path)
    }

    pub(crate) fn remove_file(&self, relative_path: &Path) -> RootResult<()> {
        self.root.remove_file(relative_path)
    }

    pub(crate) fn remove_file_if_exists(&self, relative_path: &Path) -> RootResult<bool> {
        self.root.remove_file_if_exists(relative_path)
    }

    pub(crate) fn remove_directory(&self, relative_path: &Path, recursive: bool) -> RootResult<()> {
        if recursive {
            return Err(NativeFileTransferRootError::RecursiveRemovalUnsupported);
        }
        self.root.remove_empty_directory(relative_path)
    }

    pub(crate) fn rename_entry(&self, source: &Path, destination: &Path) -> RootResult<()> {
        self.root.rename_entry(source, destination)
    }

    pub(crate) fn list_directory(
        &self,
        relative_path: &Path,
        include_hidden: bool,
    ) -> RootResult<Vec<NativeHostReadEntry>> {
        self.root.list_directory(relative_path, include_hidden)
    }

    pub(crate) fn snapshot_files_recursive(
        &self,
        relative_path: &Path,
        include_hidden: bool,
    ) -> RootResult<Vec<NativeHostReadEntry>> {
        self.root
            .snapshot_files_recursive(relative_path, include_hidden)
    }

    pub(crate) fn open_read_file(&self, entry: &NativeHostReadEntry) -> RootResult<File> {
        self.root.open_read_file(entry)
    }

    pub(crate) fn verify_read_file(
        &self,
        file: &File,
        entry: &NativeHostReadEntry,
    ) -> RootResult<()> {
        self.root.verify_read_file(file, entry)
    }

    pub(crate) fn snapshot_empty_directories(
        &self,
        relative_path: &Path,
        include_hidden: bool,
    ) -> RootResult<Vec<PathBuf>> {
        self.root
            .snapshot_empty_directories(relative_path, include_hidden)
    }
}
