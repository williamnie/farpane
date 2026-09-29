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
