// FarPane Native Host file-transfer receive-root primitives.
//
// This module is feature-isolated by its `rdn_host_bridge` parent and compiled
// only on macOS. The Native Host file-service owner is the only public module
// authority over descriptor-relative receive-root operations.

use hbb_common::libc;
use std::{
    collections::HashSet,
    ffi::{CStr, CString, OsStr},
    fmt,
    fs::File,
    os::unix::{
        ffi::OsStrExt,
        io::{AsRawFd, FromRawFd},
    },
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

const NATIVE_HOST_READ_MAX_ENTRIES: usize = 1_024;
const NATIVE_HOST_READ_MAX_METADATA_BYTES: usize = 1024 * 1024;
const NATIVE_HOST_READ_MAX_DEPTH: usize = 64;
const NATIVE_HOST_PRIVATE_STAGING_SUFFIX: &[u8] = b".farpane-part";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeFileTransferRootError {
    InvalidRoot,
    InvalidOwnerConfiguration,
    OpenRoot,
    UnsafeRoot,
    InvalidRelativePath,
    OpenDirectory,
    CreateDirectory,
    UnsafeDirectory,
    CreateFile,
    OpenFile,
    UnsafeFile,
    RemoveFile,
    RemoveDirectory,
    RecursiveRemovalUnsupported,
    RenameEntry,
    WritePathBusy,
    ReadDirectory,
    ReadFile,
    ReadLimitExceeded,
    ReadSnapshotChanged,
}

impl fmt::Display for NativeFileTransferRootError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidRoot => "invalid native file-transfer root",
            Self::InvalidOwnerConfiguration => "invalid native file-transfer owner configuration",
            Self::OpenRoot => "unable to open native file-transfer root",
            Self::UnsafeRoot => "unsafe native file-transfer root",
            Self::InvalidRelativePath => "invalid native file-transfer relative path",
            Self::OpenDirectory => "unable to open native file-transfer directory",
            Self::CreateDirectory => "unable to create native file-transfer directory",
            Self::UnsafeDirectory => "unsafe native file-transfer directory",
            Self::CreateFile => "unable to create native file-transfer file",
            Self::OpenFile => "unable to open native file-transfer file",
            Self::UnsafeFile => "unsafe native file-transfer file",
            Self::RemoveFile => "unable to remove native file-transfer file",
            Self::RemoveDirectory => "unable to remove native file-transfer directory",
            Self::RecursiveRemovalUnsupported => {
                "recursive native file-transfer removal is unsupported"
            }
            Self::RenameEntry => "unable to rename native file-transfer entry",
            Self::WritePathBusy => "native file-transfer write path is already reserved",
            Self::ReadDirectory => "unable to read native file-transfer directory",
            Self::ReadFile => "unable to read native file-transfer file",
            Self::ReadLimitExceeded => "native file-transfer read limit exceeded",
            Self::ReadSnapshotChanged => "native file-transfer read snapshot changed",
        })
    }
}

impl std::error::Error for NativeFileTransferRootError {}

type RootResult<T> = Result<T, NativeFileTransferRootError>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostReadEntryKind {
    Directory,
    File,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NativeHostReadEntry {
    relative_path: PathBuf,
    wire_name: String,
    kind: NativeHostReadEntryKind,
    size: u64,
    modified_time: u64,
    modified_time_nanoseconds: i64,
    change_time: u64,
    change_time_nanoseconds: i64,
    device: u64,
    inode: u64,
}

impl NativeHostReadEntry {
    pub(crate) fn relative_path(&self) -> &Path {
        &self.relative_path
    }

    pub(crate) fn wire_name(&self) -> &str {
        &self.wire_name
    }

    pub(crate) fn kind(&self) -> NativeHostReadEntryKind {
        self.kind
    }

    pub(crate) fn size(&self) -> u64 {
        self.size
    }

    pub(crate) fn modified_time(&self) -> u64 {
        self.modified_time
    }
}

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
        Ok(file)
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
}

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

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        io::{Read, Seek, SeekFrom, Write},
        os::unix::fs::{symlink, MetadataExt, PermissionsExt},
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    struct TestDirectory {
        path: PathBuf,
    }

    impl TestDirectory {
        fn new(label: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "farpane_native_file_root_{}_{}_{}",
                label,
                std::process::id(),
                nonce
            ));
            fs::create_dir(&path).expect("create test directory");
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                .expect("secure test directory");
            Self {
                path: fs::canonicalize(path).expect("canonical test directory"),
            }
        }

        fn child(&self, name: &str) -> PathBuf {
            self.path.join(name)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn create_private_directory(path: &Path) {
        fs::create_dir(path).expect("create private directory");
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .expect("secure private directory");
    }

    #[test]
    fn receive_root_rejects_symlink_and_unsafe_mode() {
        let sandbox = TestDirectory::new("root_admission");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let alias = sandbox.child("alias");
        symlink(&trusted, &alias).expect("create root symlink");

        assert_eq!(
            NativeFileTransferRoot::open_existing(&alias).unwrap_err(),
            NativeFileTransferRootError::OpenRoot
        );

        fs::set_permissions(&trusted, fs::Permissions::from_mode(0o755))
            .expect("make root too broad");
        assert_eq!(
            NativeFileTransferRoot::open_existing(&trusted).unwrap_err(),
            NativeFileTransferRootError::UnsafeRoot
        );
    }

    #[test]
    fn create_is_descriptor_relative_private_and_nested() {
        let sandbox = TestDirectory::new("create");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        let mut file = root
            .create_new_file(Path::new("nested/example.txt.download"))
            .expect("create nested file");
        file.write_all(b"bounded").expect("write fixture");
        file.sync_all().expect("sync fixture");

        assert_eq!(
            fs::read(trusted.join("nested/example.txt.download")).expect("read fixture"),
            b"bounded"
        );
        assert_eq!(
            fs::metadata(trusted.join("nested"))
                .expect("nested metadata")
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(trusted.join("nested/example.txt.download"))
                .expect("file metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn create_rejects_escape_absolute_and_symlink_parent() {
        let sandbox = TestDirectory::new("escape");
        let trusted = sandbox.child("trusted");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        symlink(&outside, trusted.join("link")).expect("create nested symlink");
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        assert_eq!(
            root.create_new_file(Path::new("../outside/escape.txt"))
                .unwrap_err(),
            NativeFileTransferRootError::InvalidRelativePath
        );
        assert_eq!(
            root.create_new_file(outside.join("absolute.txt").as_path())
                .unwrap_err(),
            NativeFileTransferRootError::InvalidRelativePath
        );
        assert!(root.create_new_file(Path::new("link/escape.txt")).is_err());
        assert!(!outside.join("escape.txt").exists());
    }

    #[test]
    fn resume_requires_owned_private_single_link_regular_file() {
        let sandbox = TestDirectory::new("resume");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        let mut created = root
            .create_new_file(Path::new("resume.download"))
            .expect("create resume fixture");
        created.write_all(b"prefix").expect("write prefix");
        drop(created);

        let mut resumed = root
            .open_existing_file_for_resume(Path::new("resume.download"))
            .expect("open resume fixture");
        resumed.seek(SeekFrom::End(0)).expect("seek end");
        resumed.write_all(b"-suffix").expect("write suffix");
        drop(resumed);
        let mut contents = String::new();
        File::open(trusted.join("resume.download"))
            .expect("open result")
            .read_to_string(&mut contents)
            .expect("read result");
        assert_eq!(contents, "prefix-suffix");

        fs::hard_link(
            trusted.join("resume.download"),
            trusted.join("linked.download"),
        )
        .expect("create hard link");
        assert_eq!(
            root.open_existing_file_for_resume(Path::new("linked.download"))
                .unwrap_err(),
            NativeFileTransferRootError::UnsafeFile
        );

        let broad = trusted.join("broad.download");
        fs::write(&broad, b"unsafe").expect("create broad file");
        fs::set_permissions(&broad, fs::Permissions::from_mode(0o644)).expect("set broad mode");
        assert_eq!(
            root.open_existing_file_for_resume(Path::new("broad.download"))
                .unwrap_err(),
            NativeFileTransferRootError::UnsafeFile
        );
    }

    #[test]
    fn write_path_reservations_are_atomic_and_release_on_drop() {
        let sandbox = TestDirectory::new("write_reservations");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = Arc::new(
            NativeHostFileServiceOwner::open_existing(&trusted).expect("open file-service owner"),
        );
        let paths = vec![
            PathBuf::from("first.download"),
            PathBuf::from("nested/second.download"),
        ];

        let reservation = owner
            .reserve_write_paths(&paths)
            .expect("reserve distinct write paths");
        assert_eq!(
            owner
                .reserve_write_paths(&[PathBuf::from("nested/second.download")])
                .unwrap_err(),
            NativeFileTransferRootError::WritePathBusy
        );
        assert_eq!(
            owner
                .reserve_write_paths(&[
                    PathBuf::from("third.download"),
                    PathBuf::from("nested/second.download"),
                ])
                .unwrap_err(),
            NativeFileTransferRootError::WritePathBusy
        );
        let independent = owner
            .reserve_write_paths(&[PathBuf::from("third.download")])
            .expect("failed atomic attempt must not reserve a prefix");
        drop(independent);
        drop(reservation);
        owner
            .reserve_write_paths(&paths)
            .expect("released paths can be reserved again");
    }

    #[test]
    fn open_root_descriptor_survives_path_replacement() {
        let sandbox = TestDirectory::new("replacement");
        let trusted = sandbox.child("trusted");
        let moved = sandbox.child("moved");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        fs::rename(&trusted, &moved).expect("move admitted root");
        symlink(&outside, &trusted).expect("replace original path with symlink");
        let mut file = root
            .create_new_file(Path::new("pinned.download"))
            .expect("create through pinned descriptor");
        file.write_all(b"pinned").expect("write pinned fixture");
        drop(file);

        assert_eq!(
            fs::read(moved.join("pinned.download")).expect("read pinned fixture"),
            b"pinned"
        );
        assert!(!outside.join("pinned.download").exists());
    }

    #[test]
    fn mutations_create_and_remove_only_private_entries() {
        let sandbox = TestDirectory::new("mutations");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        root.create_directory(Path::new("folder"))
            .expect("create directory");
        assert_eq!(
            fs::metadata(trusted.join("folder"))
                .expect("directory metadata")
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        drop(
            root.create_new_file(Path::new("folder/item.download"))
                .expect("create file"),
        );
        root.remove_file(Path::new("folder/item.download"))
            .expect("remove file");
        root.remove_empty_directory(Path::new("folder"))
            .expect("remove empty directory");
        assert!(!trusted.join("folder").exists());
    }

    #[test]
    fn remove_rejects_symlink_hardlink_type_confusion_and_nonempty_directory() {
        let sandbox = TestDirectory::new("remove_guards");
        let trusted = sandbox.child("trusted");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let outside_file = outside.join("outside.txt");
        fs::write(&outside_file, b"outside").expect("create outside file");
        symlink(&outside_file, trusted.join("link.download")).expect("create file symlink");
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        assert!(root.remove_file(Path::new("link.download")).is_err());
        assert!(outside_file.exists());
        assert!(fs::symlink_metadata(trusted.join("link.download")).is_ok());

        drop(
            root.create_new_file(Path::new("original.download"))
                .expect("create original"),
        );
        fs::hard_link(
            trusted.join("original.download"),
            trusted.join("alias.download"),
        )
        .expect("create hard link");
        assert_eq!(
            root.remove_file(Path::new("original.download"))
                .unwrap_err(),
            NativeFileTransferRootError::UnsafeFile
        );
        assert!(trusted.join("original.download").exists());

        root.create_directory(Path::new("nonempty"))
            .expect("create nonempty directory");
        drop(
            root.create_new_file(Path::new("nonempty/child.download"))
                .expect("create child"),
        );
        assert_eq!(
            root.remove_empty_directory(Path::new("nonempty"))
                .unwrap_err(),
            NativeFileTransferRootError::RemoveDirectory
        );
        assert!(trusted.join("nonempty/child.download").exists());
        assert!(root.remove_file(Path::new("nonempty")).is_err());
    }

    #[test]
    fn rename_is_no_replace_and_preserves_source_inode_on_success() {
        let sandbox = TestDirectory::new("rename");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");
        let mut source = root
            .create_new_file(Path::new("source.download"))
            .expect("create source");
        source.write_all(b"source").expect("write source");
        drop(source);
        let source_inode = fs::metadata(trusted.join("source.download"))
            .expect("source metadata")
            .ino();
        drop(
            root.create_new_file(Path::new("existing.download"))
                .expect("create destination collision"),
        );

        assert_eq!(
            root.rename_entry(Path::new("source.download"), Path::new("existing.download"),)
                .unwrap_err(),
            NativeFileTransferRootError::RenameEntry
        );
        assert_eq!(
            fs::read(trusted.join("source.download")).expect("source retained"),
            b"source"
        );

        root.create_directory(Path::new("archive"))
            .expect("create archive");
        root.rename_entry(
            Path::new("source.download"),
            Path::new("archive/moved.download"),
        )
        .expect("rename without replacement");
        assert!(!trusted.join("source.download").exists());
        assert_eq!(
            fs::metadata(trusted.join("archive/moved.download"))
                .expect("moved metadata")
                .ino(),
            source_inode
        );
    }

    #[test]
    fn rename_rejects_symlink_broad_mode_and_hardlinked_source() {
        let sandbox = TestDirectory::new("rename_guards");
        let trusted = sandbox.child("trusted");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let outside_file = outside.join("outside.txt");
        fs::write(&outside_file, b"outside").expect("create outside file");
        symlink(&outside_file, trusted.join("link.download")).expect("create symlink");
        let broad = trusted.join("broad.download");
        fs::write(&broad, b"broad").expect("create broad file");
        fs::set_permissions(&broad, fs::Permissions::from_mode(0o644)).expect("set broad mode");
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");
        drop(
            root.create_new_file(Path::new("linked.download"))
                .expect("create linked source"),
        );
        fs::hard_link(
            trusted.join("linked.download"),
            trusted.join("linked-alias.download"),
        )
        .expect("create source hard link");

        assert!(root
            .rename_entry(Path::new("link.download"), Path::new("link-moved.download"))
            .is_err());
        assert!(root
            .rename_entry(
                Path::new("broad.download"),
                Path::new("broad-moved.download"),
            )
            .is_err());
        assert_eq!(
            root.rename_entry(
                Path::new("linked.download"),
                Path::new("linked-moved.download"),
            )
            .unwrap_err(),
            NativeFileTransferRootError::UnsafeFile
        );
        assert!(outside_file.exists());
        assert!(broad.exists());
        assert!(trusted.join("linked.download").exists());
    }

    #[test]
    fn mutations_remain_pinned_after_root_path_replacement() {
        let sandbox = TestDirectory::new("mutation_replacement");
        let trusted = sandbox.child("trusted");
        let moved = sandbox.child("moved");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");
        drop(
            root.create_new_file(Path::new("source.download"))
                .expect("create source"),
        );

        fs::rename(&trusted, &moved).expect("move admitted root");
        symlink(&outside, &trusted).expect("replace original path");
        root.create_directory(Path::new("folder"))
            .expect("create in pinned root");
        root.rename_entry(
            Path::new("source.download"),
            Path::new("folder/renamed.download"),
        )
        .expect("rename in pinned root");
        root.remove_file(Path::new("folder/renamed.download"))
            .expect("remove in pinned root");
        root.remove_empty_directory(Path::new("folder"))
            .expect("remove directory in pinned root");

        assert!(!moved.join("source.download").exists());
        assert!(!moved.join("folder").exists());
        assert_eq!(fs::read_dir(&outside).expect("read outside").count(), 0);
    }

    #[test]
    fn native_owner_is_the_single_safe_root_mutation_authority() {
        let sandbox = TestDirectory::new("owner_authority");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");

        owner
            .create_directory(Path::new("folder"))
            .expect("create directory");
        drop(
            owner
                .create_new_file(Path::new("folder/item.download"))
                .expect("create file"),
        );
        drop(
            owner
                .open_existing_file_for_resume(Path::new("folder/item.download"))
                .expect("resume file"),
        );
        owner
            .rename_entry(
                Path::new("folder/item.download"),
                Path::new("folder/renamed.download"),
            )
            .expect("rename file");
        owner
            .remove_file(Path::new("folder/renamed.download"))
            .expect("remove file");
        owner
            .remove_directory(Path::new("folder"), false)
            .expect("remove empty directory");
        assert!(!trusted.join("folder").exists());
    }

    #[test]
    fn native_owner_rejects_recursive_remove_without_touching_tree() {
        let sandbox = TestDirectory::new("owner_recursive_remove");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        owner
            .create_directory(Path::new("folder"))
            .expect("create directory");
        drop(
            owner
                .create_new_file(Path::new("folder/item.download"))
                .expect("create file"),
        );

        assert_eq!(
            owner
                .remove_directory(Path::new("folder"), true)
                .unwrap_err(),
            NativeFileTransferRootError::RecursiveRemovalUnsupported
        );
        assert!(trusted.join("folder/item.download").is_file());
    }

    #[test]
    fn immutable_owner_configuration_requires_exact_policy_root_pair() {
        let sandbox = TestDirectory::new("owner_configuration");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);

        assert!(
            NativeHostFileServiceOwner::from_immutable_configuration(false, None)
                .expect("disabled without root")
                .is_none()
        );
        assert_eq!(
            NativeHostFileServiceOwner::from_immutable_configuration(
                false,
                Some(trusted.as_path()),
            )
            .unwrap_err(),
            NativeFileTransferRootError::InvalidOwnerConfiguration
        );
        assert_eq!(
            NativeHostFileServiceOwner::from_immutable_configuration(true, None).unwrap_err(),
            NativeFileTransferRootError::InvalidOwnerConfiguration
        );
        assert!(NativeHostFileServiceOwner::from_immutable_configuration(
            true,
            Some(trusted.as_path()),
        )
        .expect("enabled with safe root")
        .is_some());
    }

    #[test]
    fn native_owner_lists_only_safe_visible_entries_and_hides_staging() {
        let sandbox = TestDirectory::new("read_list");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        owner
            .create_directory(Path::new("nested"))
            .expect("create nested directory");
        let mut visible = owner
            .create_new_file(Path::new("visible.txt"))
            .expect("create visible file");
        visible.write_all(b"visible").expect("write visible file");
        drop(visible);
        drop(
            owner
                .create_new_file(Path::new(".hidden.txt"))
                .expect("create hidden file"),
        );
        drop(
            owner
                .create_new_file(Path::new("pending.txt.farpane-part"))
                .expect("create private staging file"),
        );

        let visible_entries = owner
            .list_directory(Path::new(""), false)
            .expect("list visible entries");
        assert_eq!(
            visible_entries
                .iter()
                .map(|entry| (entry.wire_name(), entry.kind()))
                .collect::<Vec<_>>(),
            vec![
                ("nested", NativeHostReadEntryKind::Directory),
                ("visible.txt", NativeHostReadEntryKind::File),
            ]
        );
        let all_entries = owner
            .list_directory(Path::new(""), true)
            .expect("list hidden entries");
        assert_eq!(
            all_entries
                .iter()
                .map(|entry| entry.wire_name())
                .collect::<Vec<_>>(),
            vec![".hidden.txt", "nested", "visible.txt"]
        );
    }

    #[test]
    fn native_owner_recursively_snapshots_and_reads_pinned_private_files() {
        let sandbox = TestDirectory::new("read_recursive");
        let trusted = sandbox.child("trusted");
        let moved = sandbox.child("moved");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        owner
            .create_directory(Path::new("folder"))
            .expect("create folder");
        let mut first = owner
            .create_new_file(Path::new("folder/first.txt"))
            .expect("create first file");
        first.write_all(b"first").expect("write first file");
        drop(first);
        let mut second = owner
            .create_new_file(Path::new("folder/second.txt"))
            .expect("create second file");
        second.write_all(b"second").expect("write second file");
        drop(second);

        let entries = owner
            .snapshot_files_recursive(Path::new("folder"), false)
            .expect("snapshot folder");
        assert_eq!(
            entries
                .iter()
                .map(|entry| (entry.wire_name(), entry.size()))
                .collect::<Vec<_>>(),
            vec![("first.txt", 5), ("second.txt", 6)]
        );

        fs::rename(&trusted, &moved).expect("move admitted root");
        symlink(&outside, &trusted).expect("replace root path");
        let mut contents = String::new();
        owner
            .open_read_file(&entries[0])
            .expect("open pinned snapshot")
            .read_to_string(&mut contents)
            .expect("read pinned snapshot");
        assert_eq!(contents, "first");
        assert_eq!(fs::read_dir(&outside).expect("read outside").count(), 0);
    }

    #[test]
    fn native_owner_read_snapshot_rejects_replacement_symlink_and_unsafe_mode() {
        let sandbox = TestDirectory::new("read_guards");
        let trusted = sandbox.child("trusted");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        let mut original = owner
            .create_new_file(Path::new("item.txt"))
            .expect("create original");
        original.write_all(b"original").expect("write original");
        drop(original);
        let snapshot = owner
            .snapshot_files_recursive(Path::new("item.txt"), false)
            .expect("snapshot file")
            .pop()
            .expect("single file snapshot");

        fs::rename(trusted.join("item.txt"), trusted.join("old.txt")).expect("move original");
        let mut replacement = owner
            .create_new_file(Path::new("item.txt"))
            .expect("create replacement");
        replacement
            .write_all(b"original")
            .expect("write replacement");
        drop(replacement);
        assert_eq!(
            owner.open_read_file(&snapshot).unwrap_err(),
            NativeFileTransferRootError::ReadSnapshotChanged
        );

        symlink(outside.join("outside.txt"), trusted.join("link.txt")).expect("create symlink");
        assert!(owner.list_directory(Path::new(""), true).is_err());
        let broad = trusted.join("broad.txt");
        fs::write(&broad, b"broad").expect("create broad file");
        fs::set_permissions(&broad, fs::Permissions::from_mode(0o644)).expect("set broad mode");
        assert!(owner
            .snapshot_files_recursive(Path::new("broad.txt"), false)
            .is_err());
        assert!(owner
            .snapshot_files_recursive(Path::new("pending.farpane-part"), false)
            .is_err());
    }

    #[test]
    fn native_owner_read_listing_enforces_entry_limit_before_partial_success() {
        let sandbox = TestDirectory::new("read_limit");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        for index in 0..=NATIVE_HOST_READ_MAX_ENTRIES {
            drop(
                owner
                    .create_new_file(Path::new(&format!("entry-{index:04}.txt")))
                    .expect("create bounded listing fixture"),
            );
        }

        assert_eq!(
            owner.list_directory(Path::new(""), true).unwrap_err(),
            NativeFileTransferRootError::ReadLimitExceeded
        );
    }
}
