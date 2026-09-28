#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostFileMutation<'a> {
    CreateDirectory { path: &'a str },
    RemoveFile { path: &'a str },
    RemoveDirectory { path: &'a str, recursive: bool },
    Rename { path: &'a str, new_name: &'a str },
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostFileMutationOutcome {
    NotNativeHost,
    Succeeded,
    Rejected,
    Unavailable,
}

#[cfg(target_os = "macos")]
const MAX_NATIVE_HOST_WRITE_FILES: usize = 1024;
#[cfg(target_os = "macos")]
const MAX_NATIVE_HOST_WRITE_METADATA_BYTES: usize = 1024 * 1024;
#[cfg(target_os = "macos")]
const MAX_NATIVE_HOST_WRITE_PATH_BYTES: usize = 4096;
#[cfg(target_os = "macos")]
const NATIVE_HOST_WRITE_STAGING_SUFFIX: &str = ".farpane-part";
#[cfg(target_os = "macos")]
const NATIVE_HOST_RESUME_XATTR_NAME: &[u8] = b"com.farpane.host-transfer.resume-v1\0";
#[cfg(target_os = "macos")]
const NATIVE_HOST_RESUME_METADATA_MAGIC: &[u8; 8] = b"FPRSM001";
#[cfg(target_os = "macos")]
const NATIVE_HOST_RESUME_METADATA_BYTES: usize = 64;

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostWriteServiceState {
    NotNativeHost,
    Available,
    Unavailable,
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostWriteJobError {
    InvalidBatch,
    TooManyFiles,
    MetadataTooLarge,
    InvalidPath,
    DuplicateDestination,
    DuplicateJob,
    TooManyJobs,
    UnexpectedFileNumber,
    DigestMismatch,
    ExistingTargetUnsafe,
    ExistingTargetDecisionRequired,
    ExistingTargetReplacementUnsupported,
    ResumeUnsupported,
    ResumeStateInvalid,
    WirePayloadTooLarge,
    DecodedPayloadInvalidOrTooLarge,
    FileSizeExceeded,
    FileSizeMismatch,
    TotalSizeMismatch,
    Storage,
    Unavailable,
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostWriteDigestDecision {
    ConfirmedOffset(u32),
    ExistingTarget {
        file_size: u64,
        last_modified: u64,
        is_identical: bool,
    },
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostExistingTargetDecision {
    Skip,
    Replace { offset: u32 },
}

#[cfg(target_os = "macos")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NativeHostWriteEntry {
    name: String,
    expected_size: u64,
    modified_time: u64,
}

#[cfg(target_os = "macos")]
impl NativeHostWriteEntry {
    pub(crate) fn new(name: String, expected_size: u64, modified_time: u64) -> Self {
        Self {
            name,
            expected_size,
            modified_time,
        }
    }
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostReadEntryKind {
    Directory,
    File,
}

#[cfg(target_os = "macos")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NativeHostReadListEntry {
    name: String,
    kind: NativeHostReadEntryKind,
    size: u64,
    modified_time: u64,
}

#[cfg(target_os = "macos")]
impl NativeHostReadListEntry {
    pub(crate) fn name(&self) -> &str {
        &self.name
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

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostReadJobError {
    InvalidPath,
    InvalidFileNumber,
    DuplicateJob,
    TooManyJobs,
    InvalidConfirmation,
    OffsetOutOfRange,
    SnapshotChanged,
    ReadFailed,
    Unavailable,
}

#[cfg(target_os = "macos")]
pub(crate) enum NativeHostFileReadOutcome<T> {
    NotNativeHost,
    Succeeded(T),
    Rejected(NativeHostReadJobError),
    Unavailable,
}

#[cfg(target_os = "macos")]
pub(crate) enum NativeHostReadJobAdmission {
    NotNativeHost,
    Admitted(NativeHostReadJob),
    Rejected(NativeHostReadJobError),
    Unavailable,
}

#[cfg(target_os = "macos")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostReadJobStep {
    WaitingForConfirmation,
    Digest {
        file_num: i32,
        file_size: u64,
        modified_time: u64,
    },
    Block {
        file_num: i32,
        data: Vec<u8>,
        compressed: bool,
    },
    Done {
        file_num: i32,
    },
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeHostReadConfirmation {
    Skip,
    ContinueAt { offset: u32 },
}
