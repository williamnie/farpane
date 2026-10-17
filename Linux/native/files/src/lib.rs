//! Descriptor-relative file operations for native Host and Viewer transfers.
//! Only the selected root is an authority. Remote strings never become host paths.
use std::{
    ffi::{CStr, CString},
    fs::File,
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd, RawFd},
        unix::fs::MetadataExt,
    },
    path::Path,
    sync::Arc,
};

pub const BLOCK_BYTES: usize = 128 * 1024;
pub const PAGE_ENTRIES: usize = 128;
pub const PAGE_BYTES: usize = 16 * 1024;
const STAGING: &str = ".farpane-part-";
fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
fn denied(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

/// Components are preserved exactly: no collapsing `..`, empty or platform prefixes.
pub fn validate_relative(path: &str, allow_root: bool) -> io::Result<()> {
    if path.is_empty() && allow_root {
        return Ok(());
    }
    if path.is_empty() || path.len() > 4096 || path.split('/').count() > 64 {
        return Err(invalid("Invalid transfer path length"));
    }
    for part in path.split('/') {
        if part.is_empty()
            || part == "."
            || part == ".."
            || part.len() > 255
            || part.starts_with(STAGING)
            || part.contains(['\\', ':'])
            || part.chars().any(char::is_control)
        {
            return Err(invalid("Unsafe or unsupported transfer path"));
        }
    }
    Ok(())
}
fn cstr(path: &str) -> io::Result<CString> {
    CString::new(path).map_err(|_| invalid("NUL in file path"))
}
#[repr(C)]
struct OpenHow {
    flags: u64,
    mode: u64,
    resolve: u64,
}
fn open_at(dir: RawFd, path: &str, flags: i32, beneath: bool) -> io::Result<File> {
    let path = cstr(path)?;
    let how = OpenHow {
        flags: (flags | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK) as u64,
        mode: 0,
        resolve: 0x04 | 0x02 | if beneath { 0x08 } else { 0 },
    }; // NO_SYMLINKS, NO_MAGICLINKS, BENEATH
    let fd = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            dir,
            path.as_ptr(),
            &how,
            std::mem::size_of::<OpenHow>(),
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd as RawFd) })
}
fn owned_directory(file: &File) -> io::Result<()> {
    let m = file.metadata()?;
    if !m.is_dir() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o022 != 0 {
        return Err(denied(
            "Transfer directory has an unsafe owner or shared write access",
        ));
    }
    Ok(())
}
fn same_entry(parent: &File, name: &CStr, file: &File) -> bool {
    let Ok(meta) = file.metadata() else {
        return false;
    };
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
        return false;
    }
    let stat = unsafe { stat.assume_init() };
    stat.st_dev == meta.dev() && stat.st_ino == meta.ino()
}
fn private_directory(file: &File) -> io::Result<()> {
    let m = file.metadata()?;
    if !m.is_dir() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o077 != 0 {
        return Err(denied(
            "Transfer directory must be private and owned by this user",
        ));
    }
    Ok(())
}
fn selected_directory(file: &File) -> io::Result<()> {
    let m = file.metadata()?;
    if !m.is_dir()
        || (m.uid() != unsafe { libc::geteuid() } && m.uid() != 0)
        || m.mode() & 0o022 != 0
    {
        return Err(denied(
            "Selected directory has unsafe ownership or permissions",
        ));
    }
    Ok(())
}
fn selected_regular(file: &File) -> io::Result<std::fs::Metadata> {
    let m = file.metadata()?;
    if !m.is_file()
        || (m.uid() != unsafe { libc::geteuid() } && m.uid() != 0)
        || m.nlink() == 0
        || m.mode() & 0o022 != 0
    {
        return Err(denied("Selected source is not an owned regular file"));
    }
    Ok(m)
}
fn regular(file: &File) -> io::Result<std::fs::Metadata> {
    let m = file.metadata()?;
    if !m.is_file()
        || m.uid() != unsafe { libc::geteuid() }
        || m.nlink() != 1
        || m.mode() & 0o022 != 0
    {
        return Err(denied(
            "Transfer file must be an owned regular file without hard links or shared write access",
        ));
    }
    Ok(m)
}

#[derive(Debug)]
pub struct Root {
    directory: Arc<File>,
    selected_read: bool,
}
impl Root {
    /// Opening a root never creates it or changes permissions on existing data.
    pub fn open(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() {
            return Err(invalid("Transfer root must be absolute"));
        }
        let path = path
            .to_str()
            .ok_or_else(|| invalid("Transfer root is not UTF-8"))?;
        let directory = open_at(
            libc::AT_FDCWD,
            path,
            libc::O_RDONLY | libc::O_DIRECTORY,
            false,
        )?;
        private_directory(&directory)?;
        Ok(Self {
            directory: Arc::new(directory),
            selected_read: false,
        })
    }
    /// Explicit configuration action: create a single private leaf in an existing,
    /// owned parent. Existing directories are validated, never chmod'ed.
    pub fn provision(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() {
            return Err(invalid("Transfer root must be absolute"));
        }
        if path.exists() {
            return Self::open(path);
        }
        let parent = path
            .parent()
            .ok_or_else(|| invalid("Missing receive root parent"))?;
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or_else(|| invalid("Invalid receive root name"))?;
        validate_relative(name, false)?;
        let directory = open_at(
            libc::AT_FDCWD,
            parent
                .to_str()
                .ok_or_else(|| invalid("Root parent is not UTF-8"))?,
            libc::O_RDONLY | libc::O_DIRECTORY,
            false,
        )?;
        owned_directory(&directory)?;
        let name = cstr(name)?;
        if unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) } != 0
            && io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST)
        {
            return Err(io::Error::last_os_error());
        }
        let child = open_at(
            directory.as_raw_fd(),
            name.to_str().unwrap(),
            libc::O_RDONLY | libc::O_DIRECTORY,
            true,
        )?;
        private_directory(&child)?;
        directory.sync_all()?;
        Ok(Self {
            directory: Arc::new(child),
            selected_read: false,
        })
    }
    fn check(&self) -> io::Result<()> {
        if self.selected_read {
            selected_directory(&self.directory)
        } else {
            private_directory(&self.directory)
        }
    }
    fn authority(&self) -> Authority {
        Authority {
            directory: self.directory.clone(),
            selected: self.selected_read,
        }
    }
    pub fn directory(&self, relative: &str) -> io::Result<File> {
        self.check()?;
        validate_relative(relative, true)?;
        let file = open_at(
            self.directory.as_raw_fd(),
            if relative.is_empty() { "." } else { relative },
            libc::O_RDONLY | libc::O_DIRECTORY,
            true,
        )?;
        if self.selected_read {
            selected_directory(&file)?;
        } else {
            owned_directory(&file)?;
        }
        Ok(file)
    }
    /// Creates only missing components under the pinned root, never chmods a peer's existing directory.
    pub fn create_directories(&self, relative: &str) -> io::Result<()> {
        if self.selected_read {
            return Err(denied("A selected upload source is read only"));
        }
        validate_relative(relative, true)?;
        if relative.is_empty() {
            return Ok(());
        }
        let mut directory = self.directory("")?;
        for part in relative.split('/') {
            let name = cstr(part)?;
            if unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) } != 0
                && io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST)
            {
                return Err(io::Error::last_os_error());
            }
            directory = open_at(
                directory.as_raw_fd(),
                part,
                libc::O_RDONLY | libc::O_DIRECTORY,
                true,
            )?;
            owned_directory(&directory)?;
        }
        Ok(())
    }
    fn parent(&self, path: &str, create: bool) -> io::Result<(File, CString)> {
        validate_relative(path, false)?;
        let (parent, name) = path.rsplit_once('/').unwrap_or(("", path));
        if create {
            self.create_directories(parent)?;
        }
        Ok((self.directory(parent)?, cstr(name)?))
    }
    pub fn read(&self, relative: &str) -> io::Result<Reader> {
        self.check()?;
        validate_relative(relative, false)?;
        let file = open_at(self.directory.as_raw_fd(), relative, libc::O_RDONLY, true)?;
        Reader::new(file, self.selected_read, Some(self.authority()))
    }
    pub fn list(&self, relative: &str, hidden: bool) -> io::Result<Directory> {
        let directory = self.directory(relative)?;
        let fd = unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 3) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let dir = unsafe { libc::fdopendir(fd) };
        if dir.is_null() {
            let error = io::Error::last_os_error();
            unsafe { libc::close(fd) };
            return Err(error);
        }
        Ok(Directory {
            authority: self.authority(),
            dir,
            hidden,
            ended: false,
            skipped: 0,
            pending: None,
            selected_read: self.selected_read,
        })
    }
    pub fn receive(&self, relative: &str, size: u64, overwrite: bool) -> io::Result<Writer> {
        if self.selected_read {
            return Err(denied("A selected upload source is read only"));
        }
        let (parent, name) = self.parent(relative, true)?;
        match open_at(
            parent.as_raw_fd(),
            name.to_str().unwrap(),
            libc::O_RDONLY,
            true,
        ) {
            Ok(file) => {
                regular(&file)?;
                if !overwrite {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        "Destination already exists",
                    ));
                }
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let mut random = [0u8; 16];
        if unsafe { libc::getrandom(random.as_mut_ptr().cast(), random.len(), 0) }
            != random.len() as isize
        {
            return Err(io::Error::last_os_error());
        }
        let temporary = cstr(&format!(
            "{STAGING}{}",
            random
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        ))?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Writer {
            authority: self.authority(),
            file: unsafe { File::from_raw_fd(fd) },
            parent,
            name,
            temporary,
            size,
            written: 0,
            overwrite,
            committed: false,
        })
    }
}

/// A local user's explicit upload-directory selection; no write API is exposed.
pub struct Source {
    root: Root,
}
impl Source {
    pub fn selected(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() {
            return Err(invalid("Selected upload directory must be absolute"));
        }
        let directory = open_at(
            libc::AT_FDCWD,
            path.to_str()
                .ok_or_else(|| invalid("Source is not UTF-8"))?,
            libc::O_RDONLY | libc::O_DIRECTORY,
            false,
        )?;
        selected_directory(&directory)?;
        Ok(Self {
            root: Root {
                directory: Arc::new(directory),
                selected_read: true,
            },
        })
    }
    pub fn read(&self, relative: &str) -> io::Result<Reader> {
        self.root.read(relative)
    }
    pub fn list(&self, relative: &str, hidden: bool) -> io::Result<Directory> {
        self.root.list(relative, hidden)
    }
}

struct Authority {
    directory: Arc<File>,
    selected: bool,
}
impl Authority {
    fn check(&self) -> io::Result<()> {
        if self.selected {
            selected_directory(&self.directory)
        } else {
            private_directory(&self.directory)
        }
    }
}
pub struct Reader {
    authority: Option<Authority>,
    file: File,
    size: u64,
    read: u64,
    identity: (u64, u64, i64, i64),
    selected: bool,
}
impl Reader {
    fn new(file: File, selected: bool, authority: Option<Authority>) -> io::Result<Self> {
        let m = if selected {
            selected_regular(&file)?
        } else {
            regular(&file)?
        };
        Ok(Self {
            authority,
            file,
            size: m.len(),
            read: 0,
            identity: (m.dev(), m.ino(), m.mtime(), m.mtime_nsec()),
            selected,
        })
    }
    /// Explicit local upload selection. This is never called with a remote path.
    pub fn selected(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() {
            return Err(invalid("Selected upload must be absolute"));
        }
        Self::new(
            open_at(
                libc::AT_FDCWD,
                path.to_str()
                    .ok_or_else(|| invalid("Upload path is not UTF-8"))?,
                libc::O_RDONLY,
                false,
            )?,
            true,
            None,
        )
    }
    pub fn size(&self) -> u64 {
        self.size
    }
    pub fn modified(&self) -> u64 {
        self.identity.2.max(0) as u64
    }
    pub fn read_block(&mut self) -> io::Result<Vec<u8>> {
        if let Some(authority) = &self.authority {
            authority.check()?;
        }
        let m = if self.selected {
            selected_regular(&self.file)?
        } else {
            regular(&self.file)?
        };
        if m.len() != self.size || (m.dev(), m.ino(), m.mtime(), m.mtime_nsec()) != self.identity {
            return Err(invalid("Upload source changed during transfer"));
        }
        let n = (self.size - self.read).min(BLOCK_BYTES as u64) as usize;
        let mut block = vec![0; n];
        self.file.read_exact(&mut block)?;
        self.read += n as u64;
        Ok(block)
    }
}

pub struct Writer {
    authority: Authority,
    file: File,
    parent: File,
    name: CString,
    temporary: CString,
    size: u64,
    written: u64,
    overwrite: bool,
    committed: bool,
}
impl Writer {
    pub fn write_block(&mut self, data: &[u8]) -> io::Result<()> {
        self.authority.check()?;
        owned_directory(&self.parent)?;
        if data.is_empty()
            || data.len() > BLOCK_BYTES
            || data.len() as u64 > self.size - self.written
        {
            return Err(invalid("File block exceeds declared size or block limit"));
        }
        self.file.write_all(data)?;
        self.written += data.len() as u64;
        Ok(())
    }
    pub fn written(&self) -> u64 {
        self.written
    }
    pub fn finish(mut self) -> io::Result<()> {
        self.authority.check()?;
        if self.written != self.size {
            return Err(invalid("Transfer ended before declared file size"));
        }
        self.file.sync_all()?;
        self.authority.check()?;
        owned_directory(&self.parent)?;
        if !same_entry(&self.parent, &self.temporary, &self.file) {
            return Err(denied("Temporary transfer file was replaced"));
        }
        if self.overwrite {
            match open_at(
                self.parent.as_raw_fd(),
                self.name.to_str().unwrap(),
                libc::O_RDONLY,
                true,
            ) {
                Ok(file) => {
                    regular(&file)?;
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
        }
        let flags = if self.overwrite {
            0
        } else {
            libc::RENAME_NOREPLACE
        };
        if unsafe {
            libc::renameat2(
                self.parent.as_raw_fd(),
                self.temporary.as_ptr(),
                self.parent.as_raw_fd(),
                self.name.as_ptr(),
                flags,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        self.committed = true;
        self.parent.sync_all()?;
        Ok(())
    }
}
impl Drop for Writer {
    fn drop(&mut self) {
        if !self.committed && same_entry(&self.parent, &self.temporary, &self.file) {
            unsafe { libc::unlinkat(self.parent.as_raw_fd(), self.temporary.as_ptr(), 0) };
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub directory: bool,
    pub size: u64,
    pub modified: u64,
}
pub struct Directory {
    authority: Authority,
    dir: *mut libc::DIR,
    hidden: bool,
    ended: bool,
    pub skipped: u64,
    pending: Option<Entry>,
    selected_read: bool,
}
impl Directory {
    pub fn page(&mut self) -> io::Result<(Vec<Entry>, bool)> {
        let mut entries = Vec::new();
        let mut bytes = 0;
        let mut budget = 4096;
        loop {
            let entry = if let Some(value) = self.pending.take() {
                Some(value)
            } else {
                self.next(&mut budget)?
            };
            let Some(entry) = entry else {
                return Ok((entries, !self.ended));
            };
            let size = entry.name.len() + 64;
            if entries.len() == PAGE_ENTRIES || bytes + size > PAGE_BYTES {
                self.pending = Some(entry);
                return Ok((entries, true));
            }
            bytes += size;
            entries.push(entry);
        }
    }
    fn next(&mut self, budget: &mut usize) -> io::Result<Option<Entry>> {
        self.authority.check()?;
        let mut directory = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe { libc::fstat(libc::dirfd(self.dir), directory.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let directory = unsafe { directory.assume_init() };
        if directory.st_mode & 0o022 != 0
            || (directory.st_uid != unsafe { libc::geteuid() }
                && !(self.selected_read && directory.st_uid == 0))
        {
            return Err(denied("Listed directory permissions changed"));
        }
        if self.ended {
            return Ok(None);
        }
        loop {
            if *budget == 0 {
                return Ok(None);
            }
            *budget -= 1;
            unsafe {
                *libc::__errno_location() = 0;
            }
            let item = unsafe { libc::readdir(self.dir) };
            if item.is_null() {
                self.ended = true;
                let error = io::Error::last_os_error();
                return if error.raw_os_error() == Some(0) {
                    Ok(None)
                } else {
                    Err(error)
                };
            }
            let raw = unsafe { CStr::from_ptr((*item).d_name.as_ptr()) };
            let Ok(name) = raw.to_str() else {
                self.skipped += 1;
                continue;
            };
            if name == "."
                || name == ".."
                || name.starts_with(STAGING)
                || (!self.hidden && name.starts_with('.'))
            {
                continue;
            }
            if validate_relative(name, false).is_err() {
                self.skipped += 1;
                continue;
            }
            let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
            if unsafe {
                libc::fstatat(
                    libc::dirfd(self.dir),
                    raw.as_ptr(),
                    stat.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } != 0
            {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::NotFound {
                    continue;
                }
                return Err(error);
            }
            let stat = unsafe { stat.assume_init() };
            let mode = stat.st_mode & libc::S_IFMT;
            if (stat.st_uid != unsafe { libc::geteuid() }
                && !(self.selected_read && stat.st_uid == 0))
                || stat.st_mode & 0o022 != 0
                || (mode != libc::S_IFREG && mode != libc::S_IFDIR)
                || (mode == libc::S_IFREG
                    && (stat.st_nlink == 0 || (!self.selected_read && stat.st_nlink != 1)))
            {
                self.skipped += 1;
                continue;
            }
            return Ok(Some(Entry {
                name: name.into(),
                directory: mode == libc::S_IFDIR,
                size: if mode == libc::S_IFREG {
                    stat.st_size.max(0) as u64
                } else {
                    0
                },
                modified: stat.st_mtime.max(0) as u64,
            }));
        }
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        unsafe { libc::closedir(self.dir) };
    }
}

pub mod batch;
pub mod outgoing;
pub mod owner;

#[cfg(test)]
mod tests;
