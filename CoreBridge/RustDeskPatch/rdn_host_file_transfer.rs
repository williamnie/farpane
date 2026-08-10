// FarPane Native Host file-transfer receive-root primitives.
//
// This module is feature-isolated by its `rdn_host_bridge` parent and compiled
// only on macOS. H6.3d1 establishes descriptor-relative create/resume behavior;
// the later Native Host file-service owner will be the only product caller.

use hbb_common::libc;
use std::{
    ffi::{CString, OsStr},
    fmt,
    fs::File,
    os::unix::{
        ffi::OsStrExt,
        io::{AsRawFd, FromRawFd},
    },
    path::Path,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeFileTransferRootError {
    InvalidRoot,
    OpenRoot,
    UnsafeRoot,
    InvalidRelativePath,
    OpenDirectory,
    CreateDirectory,
    UnsafeDirectory,
    CreateFile,
    OpenFile,
    UnsafeFile,
}

impl fmt::Display for NativeFileTransferRootError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidRoot => "invalid native file-transfer root",
            Self::OpenRoot => "unable to open native file-transfer root",
            Self::UnsafeRoot => "unsafe native file-transfer root",
            Self::InvalidRelativePath => "invalid native file-transfer relative path",
            Self::OpenDirectory => "unable to open native file-transfer directory",
            Self::CreateDirectory => "unable to create native file-transfer directory",
            Self::UnsafeDirectory => "unsafe native file-transfer directory",
            Self::CreateFile => "unable to create native file-transfer file",
            Self::OpenFile => "unable to open native file-transfer file",
            Self::UnsafeFile => "unsafe native file-transfer file",
        })
    }
}

impl std::error::Error for NativeFileTransferRootError {}

type RootResult<T> = Result<T, NativeFileTransferRootError>;

#[allow(dead_code)]
#[derive(Debug)]
pub(crate) struct NativeFileTransferRoot {
    directory: File,
}

#[allow(dead_code)]
impl NativeFileTransferRoot {
    pub(crate) fn open_existing(path: &Path) -> RootResult<Self> {
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

    pub(crate) fn create_new_file(&self, relative_path: &Path) -> RootResult<File> {
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

    pub(crate) fn open_existing_file_for_resume(&self, relative_path: &Path) -> RootResult<File> {
        let (parent, file_name) = self.open_relative_parent(relative_path, false)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                file_name.as_ptr(),
                libc::O_RDWR | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(NativeFileTransferRootError::OpenFile);
        }
        let file = unsafe { File::from_raw_fd(fd) };
        validate_private_regular_file(&file)?;
        Ok(file)
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
    let mut created = false;
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
        created = true;
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
    if created && unsafe { libc::fchmod(directory.as_raw_fd(), 0o700 as libc::mode_t) } != 0 {
        return Err(NativeFileTransferRootError::CreateDirectory);
    }
    validate_private_directory(&directory, NativeFileTransferRootError::UnsafeDirectory)?;
    Ok(directory)
}

fn validate_private_regular_file(file: &File) -> RootResult<()> {
    let stat = checked_stat(file)?;
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_mode & 0o777 != 0o600
        || stat.st_nlink != 1
    {
        return Err(NativeFileTransferRootError::UnsafeFile);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        io::{Read, Seek, SeekFrom, Write},
        os::unix::fs::{symlink, PermissionsExt},
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
}
