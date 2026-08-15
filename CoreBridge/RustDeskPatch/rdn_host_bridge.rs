// RustDesk Native Host bridge (Host Control ABI, H1a scope).
//
// This file is compiled inside RustDesk 1.4.9 at commit
// 6c578292e8ebbbec708b76986ba8c4bc7c509747. The surrounding RustDesk-derived
// build is AGPL-3.0; see CoreBridge/README.md and the repository root LICENSE.
//
// Contract (host-mode-design.md §8.1–§8.5, §9, §18; host-mode-h0.md §2.3):
// - independent `rdn-native-host` feature and namespace; no behavior change
//   without the feature, coexists with the viewer ABI (`rdn-native-core`);
// - low-frequency semantic control only: versioned JSON envelopes for
//   commands, events and snapshots; no raw frames, no encoded packets here;
// - opaque handle with create/start/stop/destroy lifecycle; at most one host
//   instance per process (process-global RustDesk state, §18 rule 1);
// - `rdn_host_set_config_root` must run before any hbb_common Config access
//   in the process; it switches APP_NAME/ORG so the config directory, toml
//   names, log directory and IPC socket are isolated;
// - temporary passwords never appear in logs; snapshot presentation is
//   redacted unless explicitly revealed for one copy.

#[cfg(target_os = "macos")]
#[path = "rdn_host_file_transfer.rs"]
mod rdn_host_file_transfer;

use hbb_common::{
    config,
    message_proto::{message, Clipboard, ClipboardFormat, Message, MultiClipboards},
    password_security, tokio, toml,
};
#[cfg(target_os = "macos")]
use hbb_common::{
    libc,
    sha2::{Digest, Sha256},
};
use serde_json::{json, Map, Value};
use std::{
    collections::{HashMap, HashSet},
    ffi::{c_char, c_void, CStr},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{sync_channel, Receiver, SyncSender, TrySendError},
        Arc, Mutex,
    },
    thread::JoinHandle,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
#[cfg(target_os = "macos")]
use std::{
    fs::File,
    io::{Read, Seek},
    os::unix::{ffi::OsStrExt, io::AsRawFd},
    path::{Component, Path, PathBuf},
};

const HOST_ABI_VERSION: u32 = 19;
const AUDIO_INPUT_DEVICE_MAX_UTF8_BYTES: usize = 512;
const HOST_MEDIA_ABI_VERSION: u32 = 1;
const EVENT_SCHEMA_VERSION: u32 = 1;
const SNAPSHOT_SCHEMA_VERSION: u32 = 8;
const UPSTREAM_COMMIT: &[u8] = b"6c578292e8ebbbec708b76986ba8c4bc7c509747\0";
const MAX_ENVELOPE_BYTES: usize = 64 * 1024;
const MAX_CLIPBOARD_TEXT_UTF8_BYTES: usize = 64 * 1024;
const MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES: usize = 1024 * 1024;
const MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES: usize = 1024 * 1024;
const MAX_CLIPBOARD_IMAGE_WIRE_BYTES: usize = 128 * 1024 * 1024;
const MAX_CLIPBOARD_IMAGE_DECODED_BYTES: usize = 128 * 1024 * 1024;
const MAX_CLIPBOARD_SVG_WIRE_BYTES: usize = 4 * 1024 * 1024;
const MAX_CLIPBOARD_SVG_UTF8_BYTES: usize = 4 * 1024 * 1024;
const MAX_CLIPBOARD_IMAGE_DIMENSION: i32 = 8192;
const MAX_CLIPBOARD_IMAGE_PIXELS: usize = 7680 * 4320;
const MAX_NAME_BYTES: usize = 64;
const MAX_SERVER_BYTES: usize = 512;
const MAX_SERVER_PUBLIC_KEY_BYTES: usize = 1024;
const MAX_ENCODER_ID_BYTES: usize = 128;
const PERMANENT_PASSWORD_POLICY_VERSION: u32 = 1;
const PERMANENT_PASSWORD_MIN_CHARACTERS: usize = 6;
const PERMANENT_PASSWORD_MAX_CHARACTERS: usize = 128;
const PERMANENT_PASSWORD_MAX_UTF8_BYTES: usize = 512;
const NATIVE_APPROVAL_TIMEOUT_MS: u64 = 30_000;
const MAX_REMOTE_METADATA_BYTES: usize = 256;
const MAX_MEDIA_ACCESS_UNIT_BYTES: usize = 8 * 1024 * 1024;
const MEDIA_QUEUE_CAPACITY: usize = 3;
const MEDIA_FLAG_KEYFRAME: u32 = 1 << 0;
const MEDIA_FLAG_PARAMETER_SETS: u32 = 1 << 1;
const MEDIA_KNOWN_FLAGS: u32 = MEDIA_FLAG_KEYFRAME | MEDIA_FLAG_PARAMETER_SETS;
pub(crate) const MEDIA_CODEC_H264: u32 = 1;
pub(crate) const MEDIA_CODEC_H265: u32 = 2;
const MEDIA_FRAMING_ANNEX_B: u32 = 1;
const MEDIA_FRAMING_AVCC: u32 = 2;
const MAX_HOST_CONFIG_BYTES: usize = 1024 * 1024;

// Stable error codes (design §17): negative values are contract failures.
const RDN_HOST_OK: i32 = 0;
const RDN_HOST_ERR_INVALID_ARG: i32 = -1;
const RDN_HOST_ERR_ABI_MISMATCH: i32 = -2;
const RDN_HOST_ERR_BAD_STATE: i32 = -3;
// Reserved for H1b/H3 command growth; kept in the stable code surface now.
#[allow(dead_code)]
const RDN_HOST_ERR_NOT_SUPPORTED: i32 = -4;
const RDN_HOST_ERR_VALIDATION: i32 = -5;
const RDN_HOST_ERR_INTERNAL: i32 = -6;
const RDN_HOST_ERR_STALE_EPOCH: i32 = -7;
const RDN_HOST_ERR_BACKPRESSURE: i32 = -8;
const RDN_HOST_ERR_PACKET_TOO_LARGE: i32 = -9;
const RDN_HOST_ERR_NON_MONOTONIC_PTS: i32 = -10;
const RDN_HOST_ERR_MISSING_PARAMETER_SETS: i32 = -11;
const RDN_HOST_ERR_CODEC_MISMATCH: i32 = -12;
const RDN_HOST_ERR_SECRET_INVALID_UTF8: i32 = -13;
const RDN_HOST_ERR_SECRET_EMPTY: i32 = -14;
const RDN_HOST_ERR_SECRET_TOO_SHORT: i32 = -15;
const RDN_HOST_ERR_SECRET_TOO_LONG: i32 = -16;
const RDN_HOST_ERR_SECRET_FORBIDDEN_CHARACTER: i32 = -17;
const RDN_HOST_ERR_SECRET_OUTER_WHITESPACE: i32 = -18;
const RDN_HOST_ERR_CHANGE_DISABLED: i32 = -19;
const RDN_HOST_ERR_STORAGE: i32 = -20;
const RDN_HOST_ERR_APPROVAL_NOT_FOUND: i32 = -21;
const RDN_HOST_ERR_APPROVAL_FINALIZED: i32 = -22;
const RDN_HOST_ERR_APPROVAL_EXPIRED: i32 = -23;
const RDN_HOST_ERR_SESSION_NOT_FOUND: i32 = -24;
const RDN_HOST_ERR_SESSION_STALE: i32 = -25;
const RDN_HOST_ERR_SESSION_COMMAND_UNAVAILABLE: i32 = -26;
const RDN_HOST_ERR_STALE_GENERATION: i32 = -27;

#[repr(C)]
#[derive(Clone, Copy)]
pub enum RdnHostState {
    Created = 0,
    Starting = 1,
    Ready = 2,
    Stopping = 3,
    Stopped = 4,
    Error = 5,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HostRecoveryState {
    Running,
    Suspending,
    Suspended,
    Resuming,
    Failed,
}

impl HostRecoveryState {
    fn name(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Suspending => "suspending",
            Self::Suspended => "suspended",
            Self::Resuming => "resuming",
            Self::Failed => "failed",
        }
    }
}

fn state_name(state: RdnHostState) -> &'static str {
    match state {
        RdnHostState::Created => "created",
        RdnHostState::Starting => "starting",
        RdnHostState::Ready => "ready",
        RdnHostState::Stopping => "stopping",
        RdnHostState::Stopped => "stopped",
        RdnHostState::Error => "error",
    }
}

/// Single product authority for whether the current process owns an active
/// Aqua console session. macOS fails closed through the pinned CGSession
/// policy; non-macOS builds retain their existing behavior.
pub(crate) fn native_host_session_is_available() -> bool {
    #[cfg(target_os = "macos")]
    {
        crate::platform::macos::is_active_aqua_session()
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

/// Returns the exact frame-rate ceiling proven by the native hardware probe.
/// The video service uses this stable route contract while RustDesk QoS changes
/// only writer pacing in place.
pub(crate) fn native_media_max_fps() -> Option<u32> {
    let broker = MEDIA_BROKER.lock().unwrap();
    (broker.binding.is_some() && broker.capabilities.max_fps > 0)
        .then_some(broker.capabilities.max_fps)
}

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

#[cfg(target_os = "macos")]
#[derive(Debug)]
struct NativeHostPreparedWriteEntry {
    destination_path: PathBuf,
    staging_path: PathBuf,
    expected_size: u64,
    modified_time: u64,
}

#[cfg(target_os = "macos")]
#[derive(Debug)]
struct NativeHostResumeMetadata {
    expected_size: u64,
    modified_time: u64,
    committed_size: u64,
    prefix_digest: [u8; 32],
}

#[cfg(target_os = "macos")]
impl NativeHostResumeMetadata {
    fn encode(&self) -> [u8; NATIVE_HOST_RESUME_METADATA_BYTES] {
        let mut encoded = [0_u8; NATIVE_HOST_RESUME_METADATA_BYTES];
        encoded[0..8].copy_from_slice(NATIVE_HOST_RESUME_METADATA_MAGIC);
        encoded[8..16].copy_from_slice(&self.expected_size.to_be_bytes());
        encoded[16..24].copy_from_slice(&self.modified_time.to_be_bytes());
        encoded[24..32].copy_from_slice(&self.committed_size.to_be_bytes());
        encoded[32..64].copy_from_slice(&self.prefix_digest);
        encoded
    }

    fn decode(encoded: &[u8]) -> Result<Self, NativeHostWriteJobError> {
        if encoded.len() != NATIVE_HOST_RESUME_METADATA_BYTES
            || &encoded[0..8] != NATIVE_HOST_RESUME_METADATA_MAGIC
        {
            return Err(NativeHostWriteJobError::ResumeStateInvalid);
        }
        let read_u64 = |range: std::ops::Range<usize>| {
            let mut bytes = [0_u8; 8];
            bytes.copy_from_slice(&encoded[range]);
            u64::from_be_bytes(bytes)
        };
        let mut prefix_digest = [0_u8; 32];
        prefix_digest.copy_from_slice(&encoded[32..64]);
        Ok(Self {
            expected_size: read_u64(8..16),
            modified_time: read_u64(16..24),
            committed_size: read_u64(24..32),
            prefix_digest,
        })
    }
}

#[cfg(target_os = "macos")]
#[derive(Debug)]
struct NativeHostWriteFile {
    owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
    staging_path: PathBuf,
    destination_path: PathBuf,
    file: Option<File>,
    expected_size: u64,
    written_size: u64,
    modified_time: u64,
    prefix_hasher: Sha256,
    preserve_for_resume: bool,
    committed: bool,
}

#[cfg(target_os = "macos")]
impl NativeHostWriteFile {
    fn create(
        owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
        entry: &NativeHostPreparedWriteEntry,
    ) -> Result<Self, NativeHostWriteJobError> {
        let file = owner
            .create_new_file(&entry.staging_path)
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        let prefix_hasher = Sha256::new();
        let created = Self {
            owner,
            staging_path: entry.staging_path.clone(),
            destination_path: entry.destination_path.clone(),
            file: Some(file),
            expected_size: entry.expected_size,
            written_size: 0,
            modified_time: entry.modified_time,
            prefix_hasher,
            preserve_for_resume: false,
            committed: false,
        };
        native_host_set_resume_metadata(
            created
                .file
                .as_ref()
                .ok_or(NativeHostWriteJobError::Storage)?,
            &native_host_write_resume_metadata(entry, 0, &created.prefix_hasher),
        )?;
        created
            .file
            .as_ref()
            .ok_or(NativeHostWriteJobError::Storage)?
            .sync_all()
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        Ok(created)
    }

    fn resume(
        owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
        entry: &NativeHostPreparedWriteEntry,
    ) -> Result<Option<Self>, NativeHostWriteJobError> {
        let Some(mut file) = owner
            .try_open_existing_file_for_resume(&entry.staging_path)
            .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?
        else {
            return Ok(None);
        };
        let metadata = native_host_get_resume_metadata(&file)?;
        if metadata.expected_size != entry.expected_size
            || metadata.modified_time != entry.modified_time
            || metadata.committed_size == 0
            || metadata.committed_size > entry.expected_size
            || metadata.committed_size > u32::MAX as u64
        {
            return Err(NativeHostWriteJobError::ResumeStateInvalid);
        }
        let stored_size = file
            .metadata()
            .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?
            .len();
        if stored_size < metadata.committed_size || stored_size > entry.expected_size {
            return Err(NativeHostWriteJobError::ResumeStateInvalid);
        }
        if stored_size != metadata.committed_size {
            file.set_len(metadata.committed_size)
                .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
        }
        let prefix_hasher = native_host_read_and_verify_resume_prefix(
            &mut file,
            metadata.committed_size,
            &metadata.prefix_digest,
        )?;
        Ok(Some(Self {
            owner,
            staging_path: entry.staging_path.clone(),
            destination_path: entry.destination_path.clone(),
            file: Some(file),
            expected_size: entry.expected_size,
            written_size: metadata.committed_size,
            modified_time: entry.modified_time,
            prefix_hasher,
            preserve_for_resume: true,
            committed: false,
        }))
    }

    fn write_payload(&mut self, payload: &[u8]) -> Result<(), NativeHostWriteJobError> {
        let next_size = self
            .written_size
            .checked_add(payload.len() as u64)
            .ok_or(NativeHostWriteJobError::FileSizeExceeded)?;
        if next_size > self.expected_size {
            return Err(NativeHostWriteJobError::FileSizeExceeded);
        }
        let file = self.file.as_mut().ok_or(NativeHostWriteJobError::Storage)?;
        std::io::Write::write_all(file, payload).map_err(|_| NativeHostWriteJobError::Storage)?;
        self.prefix_hasher.update(payload);
        native_host_set_resume_metadata(
            file,
            &NativeHostResumeMetadata {
                expected_size: self.expected_size,
                modified_time: self.modified_time,
                committed_size: next_size,
                prefix_digest: native_host_prefix_digest(&self.prefix_hasher),
            },
        )?;
        file.sync_all()
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        self.written_size = next_size;
        self.preserve_for_resume = next_size > 0;
        Ok(())
    }

    fn commit(mut self) -> Result<(), NativeHostWriteJobError> {
        if self.written_size != self.expected_size {
            return Err(NativeHostWriteJobError::FileSizeMismatch);
        }
        self.preserve_for_resume = false;
        let file = self.file.take().ok_or(NativeHostWriteJobError::Storage)?;
        native_host_set_file_modified_time(&file, self.modified_time)?;
        native_host_remove_resume_metadata(&file)?;
        file.sync_all()
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        let stored_size = file
            .metadata()
            .map_err(|_| NativeHostWriteJobError::Storage)?
            .len();
        if stored_size != self.expected_size {
            return Err(NativeHostWriteJobError::FileSizeMismatch);
        }
        drop(file);
        self.owner
            .rename_entry(&self.staging_path, &self.destination_path)
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        self.committed = true;
        Ok(())
    }
}

#[cfg(target_os = "macos")]
impl Drop for NativeHostWriteFile {
    fn drop(&mut self) {
        self.file.take();
        if !self.committed && !self.preserve_for_resume {
            let _ = self.owner.remove_file(&self.staging_path);
        }
    }
}

#[cfg(target_os = "macos")]
fn native_host_write_resume_metadata(
    entry: &NativeHostPreparedWriteEntry,
    committed_size: u64,
    prefix_hasher: &Sha256,
) -> NativeHostResumeMetadata {
    NativeHostResumeMetadata {
        expected_size: entry.expected_size,
        modified_time: entry.modified_time,
        committed_size,
        prefix_digest: native_host_prefix_digest(prefix_hasher),
    }
}

#[cfg(target_os = "macos")]
fn native_host_prefix_digest(hasher: &Sha256) -> [u8; 32] {
    let digest = hasher.clone().finalize();
    let mut bytes = [0_u8; 32];
    bytes.copy_from_slice(&digest);
    bytes
}

#[cfg(target_os = "macos")]
fn native_host_set_resume_metadata(
    file: &File,
    metadata: &NativeHostResumeMetadata,
) -> Result<(), NativeHostWriteJobError> {
    let encoded = metadata.encode();
    let result = unsafe {
        libc::fsetxattr(
            file.as_raw_fd(),
            NATIVE_HOST_RESUME_XATTR_NAME.as_ptr().cast(),
            encoded.as_ptr().cast(),
            encoded.len(),
            0,
            0,
        )
    };
    if result != 0 {
        return Err(NativeHostWriteJobError::Storage);
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn native_host_get_resume_metadata(
    file: &File,
) -> Result<NativeHostResumeMetadata, NativeHostWriteJobError> {
    let mut encoded = [0_u8; NATIVE_HOST_RESUME_METADATA_BYTES];
    let size = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            NATIVE_HOST_RESUME_XATTR_NAME.as_ptr().cast(),
            encoded.as_mut_ptr().cast(),
            encoded.len(),
            0,
            0,
        )
    };
    if size != encoded.len() as isize {
        return Err(NativeHostWriteJobError::ResumeStateInvalid);
    }
    NativeHostResumeMetadata::decode(&encoded)
}

#[cfg(target_os = "macos")]
fn native_host_remove_resume_metadata(file: &File) -> Result<(), NativeHostWriteJobError> {
    if unsafe {
        libc::fremovexattr(
            file.as_raw_fd(),
            NATIVE_HOST_RESUME_XATTR_NAME.as_ptr().cast(),
            0,
        )
    } != 0
    {
        return Err(NativeHostWriteJobError::Storage);
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn native_host_read_and_verify_resume_prefix(
    file: &mut File,
    committed_size: u64,
    expected_digest: &[u8; 32],
) -> Result<Sha256, NativeHostWriteJobError> {
    file.seek(std::io::SeekFrom::Start(0))
        .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
    let mut remaining = committed_size;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    while remaining > 0 {
        let requested = usize::try_from(remaining.min(buffer.len() as u64))
            .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
        file.read_exact(&mut buffer[..requested])
            .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
        hasher.update(&buffer[..requested]);
        remaining -= requested as u64;
    }
    if native_host_prefix_digest(&hasher) != *expected_digest {
        return Err(NativeHostWriteJobError::ResumeStateInvalid);
    }
    file.seek(std::io::SeekFrom::Start(committed_size))
        .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
    Ok(hasher)
}

#[cfg(target_os = "macos")]
#[derive(Debug)]
pub(crate) struct NativeHostWriteJob {
    id: i32,
    owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
    _reservations: rdn_host_file_transfer::NativeHostWriteReservations,
    entries: Vec<NativeHostPreparedWriteEntry>,
    current: Option<(usize, NativeHostWriteFile)>,
    next_file_num: usize,
    expected_total_size: u64,
    written_total_size: u64,
    skipped_total_size: u64,
    overwrite_detection: bool,
    awaiting_existing_target: Option<usize>,
}

#[cfg(target_os = "macos")]
impl NativeHostWriteJob {
    pub(crate) fn id(&self) -> i32 {
        self.id
    }

    pub(crate) fn is_current(&self) -> bool {
        let broker = MEDIA_BROKER.lock().unwrap();
        broker.binding.is_some()
            && broker
                .file_service_owner
                .as_ref()
                .is_some_and(|owner| Arc::ptr_eq(owner, &self.owner))
    }

    pub(crate) fn confirm_file_digest(
        &mut self,
        file_num: i32,
        file_size: u64,
        last_modified: u64,
        is_resume: bool,
    ) -> Result<NativeHostWriteDigestDecision, NativeHostWriteJobError> {
        if !self.is_current() {
            return Err(NativeHostWriteJobError::Unavailable);
        }
        if !self.overwrite_detection {
            return Err(NativeHostWriteJobError::DigestMismatch);
        }
        let file_num =
            usize::try_from(file_num).map_err(|_| NativeHostWriteJobError::UnexpectedFileNumber)?;
        if file_num != self.next_file_num || file_num >= self.entries.len() {
            return Err(NativeHostWriteJobError::UnexpectedFileNumber);
        }
        if self.awaiting_existing_target.is_some() {
            return Err(NativeHostWriteJobError::ExistingTargetDecisionRequired);
        }
        if let Some((current_num, current)) = self.current.as_ref() {
            if *current_num + 1 != file_num || current.written_size != current.expected_size {
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
        }
        let entry = &self.entries[file_num];
        if entry.expected_size != file_size || entry.modified_time != last_modified {
            return Err(NativeHostWriteJobError::DigestMismatch);
        }
        let existing = self
            .owner
            .try_open_existing_file_for_digest(&entry.destination_path)
            .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?;
        if let Some(existing) = existing {
            let metadata = existing
                .metadata()
                .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?;
            let existing_modified = metadata
                .modified()
                .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?
                .duration_since(UNIX_EPOCH)
                .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?
                .as_secs();
            let existing_size = metadata.len();
            self.awaiting_existing_target = Some(file_num);
            return Ok(NativeHostWriteDigestDecision::ExistingTarget {
                file_size: existing_size,
                last_modified: existing_modified,
                is_identical: existing_size == file_size && existing_modified == last_modified,
            });
        }
        if !is_resume && entry.expected_size == 0 {
            if let Some((current_num, current)) = self.current.take() {
                if current_num + 1 != file_num || current.written_size != current.expected_size {
                    self.current = Some((current_num, current));
                    return Err(NativeHostWriteJobError::UnexpectedFileNumber);
                }
                current.commit()?;
            }
            NativeHostWriteFile::create(self.owner.clone(), entry)?.commit()?;
            self.next_file_num = file_num
                .checked_add(1)
                .ok_or(NativeHostWriteJobError::UnexpectedFileNumber)?;
            return Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0));
        }
        if !is_resume {
            return Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0));
        }
        if self.entries.len() != 1 || entry.expected_size > u32::MAX as u64 {
            return Err(NativeHostWriteJobError::ResumeUnsupported);
        }
        let resumed = match NativeHostWriteFile::resume(self.owner.clone(), entry) {
            Ok(resumed) => resumed,
            Err(error) => {
                let _ = self.owner.remove_file(&entry.staging_path);
                return Err(error);
            }
        };
        let Some(resumed) = resumed else {
            return Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0));
        };
        let offset = u32::try_from(resumed.written_size)
            .map_err(|_| NativeHostWriteJobError::ResumeUnsupported)?;
        self.written_total_size = resumed.written_size;
        self.current = Some((file_num, resumed));
        self.next_file_num = file_num + 1;
        Ok(NativeHostWriteDigestDecision::ConfirmedOffset(offset))
    }

    pub(crate) fn confirm_existing_target_decision(
        &mut self,
        file_num: i32,
        decision: NativeHostExistingTargetDecision,
    ) -> Result<(), NativeHostWriteJobError> {
        if !self.is_current() {
            return Err(NativeHostWriteJobError::Unavailable);
        }
        let file_num =
            usize::try_from(file_num).map_err(|_| NativeHostWriteJobError::UnexpectedFileNumber)?;
        if self.awaiting_existing_target != Some(file_num)
            || file_num != self.next_file_num
            || file_num >= self.entries.len()
        {
            return Err(NativeHostWriteJobError::UnexpectedFileNumber);
        }
        match decision {
            NativeHostExistingTargetDecision::Skip => {}
            NativeHostExistingTargetDecision::Replace { offset } => {
                let _ = offset;
                return Err(NativeHostWriteJobError::ExistingTargetReplacementUnsupported);
            }
        }
        if let Some((current_num, current)) = self.current.take() {
            if current_num + 1 != file_num || current.written_size != current.expected_size {
                self.current = Some((current_num, current));
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
            current.commit()?;
        }
        self.owner
            .remove_file_if_exists(&self.entries[file_num].staging_path)
            .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?;
        self.skipped_total_size = self
            .skipped_total_size
            .checked_add(self.entries[file_num].expected_size)
            .ok_or(NativeHostWriteJobError::TotalSizeMismatch)?;
        self.next_file_num = file_num
            .checked_add(1)
            .ok_or(NativeHostWriteJobError::UnexpectedFileNumber)?;
        self.awaiting_existing_target = None;
        Ok(())
    }

    pub(crate) fn write_block(
        &mut self,
        file_num: i32,
        data: &[u8],
        compressed: bool,
    ) -> Result<(), NativeHostWriteJobError> {
        if !self.is_current() {
            return Err(NativeHostWriteJobError::Unavailable);
        }
        if data.len() > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES {
            return Err(NativeHostWriteJobError::WirePayloadTooLarge);
        }
        let payload = if compressed {
            hbb_common::compress::decompress_with_limit(
                data,
                hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES,
            )
            .map_err(|_| NativeHostWriteJobError::DecodedPayloadInvalidOrTooLarge)?
        } else {
            data.to_vec()
        };
        let file_num =
            usize::try_from(file_num).map_err(|_| NativeHostWriteJobError::UnexpectedFileNumber)?;
        if self.awaiting_existing_target.is_some() {
            return Err(NativeHostWriteJobError::ExistingTargetDecisionRequired);
        }
        if file_num >= self.entries.len() {
            return Err(NativeHostWriteJobError::UnexpectedFileNumber);
        }

        let needs_new_file = self
            .current
            .as_ref()
            .map_or(true, |(current_num, _)| *current_num != file_num);
        if needs_new_file {
            if file_num != self.next_file_num {
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
            if let Some((current_num, current)) = self.current.take() {
                current.commit()?;
                self.next_file_num = current_num
                    .checked_add(1)
                    .ok_or(NativeHostWriteJobError::UnexpectedFileNumber)?;
            }
            if file_num != self.next_file_num {
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
            let current = NativeHostWriteFile::create(self.owner.clone(), &self.entries[file_num])?;
            self.current = Some((file_num, current));
            self.next_file_num = file_num
                .checked_add(1)
                .ok_or(NativeHostWriteJobError::UnexpectedFileNumber)?;
        }

        let next_total = self
            .written_total_size
            .checked_add(payload.len() as u64)
            .ok_or(NativeHostWriteJobError::TotalSizeMismatch)?;
        self.current
            .as_mut()
            .ok_or(NativeHostWriteJobError::Storage)?
            .1
            .write_payload(&payload)?;
        if next_total > self.expected_total_size {
            return Err(NativeHostWriteJobError::TotalSizeMismatch);
        }
        self.written_total_size = next_total;
        Ok(())
    }

    pub(crate) fn finish(mut self, file_num: i32) -> Result<(), NativeHostWriteJobError> {
        let result = self.finish_inner(file_num);
        if result.is_err() {
            self.abort_in_place();
        }
        result
    }

    fn finish_inner(&mut self, file_num: i32) -> Result<(), NativeHostWriteJobError> {
        if !self.is_current() {
            return Err(NativeHostWriteJobError::Unavailable);
        }
        let done_file_num =
            usize::try_from(file_num).map_err(|_| NativeHostWriteJobError::UnexpectedFileNumber)?;
        if done_file_num != self.entries.len()
            || self.awaiting_existing_target.is_some()
            || self
                .written_total_size
                .checked_add(self.skipped_total_size)
                .ok_or(NativeHostWriteJobError::TotalSizeMismatch)?
                != self.expected_total_size
        {
            return Err(NativeHostWriteJobError::TotalSizeMismatch);
        }
        if let Some((current_num, current)) = self.current.take() {
            if current_num + 1 != self.entries.len() {
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
            current.commit()?;
        } else if self.next_file_num != self.entries.len() {
            return Err(NativeHostWriteJobError::FileSizeMismatch);
        }
        self.next_file_num = self.entries.len();
        Ok(())
    }

    pub(crate) fn abort(mut self) {
        self.abort_in_place();
    }

    fn abort_in_place(&mut self) {
        if let Some((_, mut current)) = self.current.take() {
            current.preserve_for_resume = false;
        }
    }
}

#[cfg(target_os = "macos")]
#[derive(Debug)]
pub(crate) struct NativeHostReadJob {
    id: i32,
    owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
    wire_path: String,
    entries: Vec<rdn_host_file_transfer::NativeHostReadEntry>,
    next_file_num: usize,
    current_file: Option<File>,
    current_offset: u64,
    awaiting_confirmation: Option<usize>,
    overwrite_detection: bool,
}

#[cfg(target_os = "macos")]
impl NativeHostReadJob {
    pub(crate) fn id(&self) -> i32 {
        self.id
    }

    pub(crate) fn wire_path(&self) -> &str {
        &self.wire_path
    }

    pub(crate) fn entries(&self) -> Vec<NativeHostReadListEntry> {
        self.entries
            .iter()
            .map(native_host_read_list_entry)
            .collect()
    }

    pub(crate) fn is_waiting_for_confirmation(&self) -> bool {
        self.awaiting_confirmation.is_some()
    }

    pub(crate) fn is_current(&self) -> bool {
        let broker = MEDIA_BROKER.lock().unwrap();
        broker.binding.is_some()
            && broker
                .file_service_owner
                .as_ref()
                .is_some_and(|owner| Arc::ptr_eq(owner, &self.owner))
    }

    pub(crate) fn confirm(
        &mut self,
        file_num: i32,
        confirmation: NativeHostReadConfirmation,
    ) -> Result<(), NativeHostReadJobError> {
        if !self.is_current() {
            return Err(NativeHostReadJobError::Unavailable);
        }
        let file_num =
            usize::try_from(file_num).map_err(|_| NativeHostReadJobError::InvalidFileNumber)?;
        if self.awaiting_confirmation != Some(file_num)
            || file_num != self.next_file_num
            || file_num >= self.entries.len()
        {
            return Err(NativeHostReadJobError::InvalidConfirmation);
        }
        self.owner
            .verify_read_file(
                self.current_file
                    .as_ref()
                    .ok_or(NativeHostReadJobError::InvalidConfirmation)?,
                &self.entries[file_num],
            )
            .map_err(native_host_read_job_error)?;
        match confirmation {
            NativeHostReadConfirmation::Skip => {
                self.current_file.take();
                self.current_offset = 0;
                self.next_file_num = file_num
                    .checked_add(1)
                    .ok_or(NativeHostReadJobError::InvalidFileNumber)?;
            }
            NativeHostReadConfirmation::ContinueAt { offset } => {
                let offset = u64::from(offset);
                if offset > self.entries[file_num].size() {
                    return Err(NativeHostReadJobError::OffsetOutOfRange);
                }
                self.current_file
                    .as_mut()
                    .ok_or(NativeHostReadJobError::InvalidConfirmation)?
                    .seek(std::io::SeekFrom::Start(offset))
                    .map_err(|_| NativeHostReadJobError::ReadFailed)?;
                self.current_offset = offset;
            }
        }
        self.awaiting_confirmation = None;
        Ok(())
    }

    pub(crate) fn poll(&mut self) -> Result<NativeHostReadJobStep, NativeHostReadJobError> {
        if !self.is_current() {
            return Err(NativeHostReadJobError::Unavailable);
        }
        if self.awaiting_confirmation.is_some() {
            return Ok(NativeHostReadJobStep::WaitingForConfirmation);
        }
        loop {
            if self.next_file_num >= self.entries.len() {
                return Ok(NativeHostReadJobStep::Done {
                    file_num: i32::try_from(self.next_file_num)
                        .map_err(|_| NativeHostReadJobError::InvalidFileNumber)?,
                });
            }
            if self.current_file.is_none() {
                let file = self
                    .owner
                    .open_read_file(&self.entries[self.next_file_num])
                    .map_err(native_host_read_job_error)?;
                self.current_file = Some(file);
                self.current_offset = 0;
                if self.overwrite_detection {
                    self.awaiting_confirmation = Some(self.next_file_num);
                    return Ok(NativeHostReadJobStep::Digest {
                        file_num: i32::try_from(self.next_file_num)
                            .map_err(|_| NativeHostReadJobError::InvalidFileNumber)?,
                        file_size: self.entries[self.next_file_num].size(),
                        modified_time: self.entries[self.next_file_num].modified_time(),
                    });
                }
            }

            let mut data = vec![0_u8; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES];
            let mut read_bytes = 0_usize;
            while read_bytes < data.len() {
                let count = self
                    .current_file
                    .as_mut()
                    .ok_or(NativeHostReadJobError::ReadFailed)?
                    .read(&mut data[read_bytes..])
                    .map_err(|_| NativeHostReadJobError::ReadFailed)?;
                if count == 0 {
                    break;
                }
                read_bytes = read_bytes
                    .checked_add(count)
                    .ok_or(NativeHostReadJobError::ReadFailed)?;
            }
            data.truncate(read_bytes);
            if data.is_empty() {
                let file = self
                    .current_file
                    .take()
                    .ok_or(NativeHostReadJobError::ReadFailed)?;
                if self.current_offset != self.entries[self.next_file_num].size() {
                    return Err(NativeHostReadJobError::SnapshotChanged);
                }
                self.owner
                    .verify_read_file(&file, &self.entries[self.next_file_num])
                    .map_err(native_host_read_job_error)?;
                self.current_offset = 0;
                self.next_file_num = self
                    .next_file_num
                    .checked_add(1)
                    .ok_or(NativeHostReadJobError::InvalidFileNumber)?;
                continue;
            }
            let next_offset = self
                .current_offset
                .checked_add(data.len() as u64)
                .ok_or(NativeHostReadJobError::SnapshotChanged)?;
            if next_offset > self.entries[self.next_file_num].size() {
                return Err(NativeHostReadJobError::SnapshotChanged);
            }
            self.current_offset = next_offset;
            let compressed = hbb_common::compress::compress(&data);
            let (data, compressed) = if compressed.len() < data.len() {
                (compressed, true)
            } else {
                (data, false)
            };
            return Ok(NativeHostReadJobStep::Block {
                file_num: i32::try_from(self.next_file_num)
                    .map_err(|_| NativeHostReadJobError::InvalidFileNumber)?,
                data,
                compressed,
            });
        }
    }
}

#[cfg(target_os = "macos")]
pub(crate) enum NativeHostWriteJobAdmission {
    NotNativeHost,
    Admitted(NativeHostWriteJob),
    Rejected(NativeHostWriteJobError),
    Unavailable,
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_write_service_state() -> NativeHostWriteServiceState {
    let broker = MEDIA_BROKER.lock().unwrap();
    if broker.binding.is_none() {
        return if HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
            NativeHostWriteServiceState::Unavailable
        } else {
            NativeHostWriteServiceState::NotNativeHost
        };
    }
    if broker.file_service_owner.is_some() {
        NativeHostWriteServiceState::Available
    } else {
        NativeHostWriteServiceState::Unavailable
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_begin_new_file_write_job(
    id: i32,
    base_path: &str,
    start_file_num: i32,
    entries: Vec<NativeHostWriteEntry>,
    total_size: u64,
    overwrite_detection: bool,
) -> NativeHostWriteJobAdmission {
    let owner = {
        let broker = MEDIA_BROKER.lock().unwrap();
        if broker.binding.is_none() {
            return if HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
                NativeHostWriteJobAdmission::Unavailable
            } else {
                NativeHostWriteJobAdmission::NotNativeHost
            };
        }
        let Some(owner) = broker.file_service_owner.as_ref() else {
            return NativeHostWriteJobAdmission::Unavailable;
        };
        owner.clone()
    };
    match prepare_native_host_write_job(
        id,
        owner,
        base_path,
        start_file_num,
        entries,
        total_size,
        overwrite_detection,
    ) {
        Ok(job) => NativeHostWriteJobAdmission::Admitted(job),
        Err(error) => NativeHostWriteJobAdmission::Rejected(error),
    }
}

#[cfg(target_os = "macos")]
enum NativeHostReadOwnerState {
    NotNativeHost,
    Available(Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>),
    Unavailable,
}

#[cfg(target_os = "macos")]
fn native_host_read_owner() -> NativeHostReadOwnerState {
    let broker = MEDIA_BROKER.lock().unwrap();
    if broker.binding.is_none() {
        return if HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
            NativeHostReadOwnerState::Unavailable
        } else {
            NativeHostReadOwnerState::NotNativeHost
        };
    }
    match broker.file_service_owner.as_ref() {
        Some(owner) => NativeHostReadOwnerState::Available(owner.clone()),
        None => NativeHostReadOwnerState::Unavailable,
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_list_directory(
    path: &str,
    include_hidden: bool,
) -> NativeHostFileReadOutcome<(String, Vec<NativeHostReadListEntry>)> {
    let owner = match native_host_read_owner() {
        NativeHostReadOwnerState::NotNativeHost => {
            return NativeHostFileReadOutcome::NotNativeHost;
        }
        NativeHostReadOwnerState::Unavailable => {
            return NativeHostFileReadOutcome::Unavailable;
        }
        NativeHostReadOwnerState::Available(owner) => owner,
    };
    let (relative_path, wire_path) = match native_host_read_wire_path(path) {
        Ok(value) => value,
        Err(error) => return NativeHostFileReadOutcome::Rejected(error),
    };
    match owner.list_directory(&relative_path, include_hidden) {
        Ok(entries) => NativeHostFileReadOutcome::Succeeded((
            wire_path,
            entries.iter().map(native_host_read_list_entry).collect(),
        )),
        Err(error) => NativeHostFileReadOutcome::Rejected(native_host_read_job_error(error)),
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_list_files_recursive(
    path: &str,
    include_hidden: bool,
) -> NativeHostFileReadOutcome<(String, Vec<NativeHostReadListEntry>)> {
    let owner = match native_host_read_owner() {
        NativeHostReadOwnerState::NotNativeHost => {
            return NativeHostFileReadOutcome::NotNativeHost;
        }
        NativeHostReadOwnerState::Unavailable => {
            return NativeHostFileReadOutcome::Unavailable;
        }
        NativeHostReadOwnerState::Available(owner) => owner,
    };
    let (relative_path, wire_path) = match native_host_read_wire_path(path) {
        Ok(value) => value,
        Err(error) => return NativeHostFileReadOutcome::Rejected(error),
    };
    match owner.snapshot_files_recursive(&relative_path, include_hidden) {
        Ok(entries) => NativeHostFileReadOutcome::Succeeded((
            wire_path,
            entries.iter().map(native_host_read_list_entry).collect(),
        )),
        Err(error) => NativeHostFileReadOutcome::Rejected(native_host_read_job_error(error)),
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_list_empty_directories(
    path: &str,
    include_hidden: bool,
) -> NativeHostFileReadOutcome<(String, Vec<String>)> {
    let owner = match native_host_read_owner() {
        NativeHostReadOwnerState::NotNativeHost => {
            return NativeHostFileReadOutcome::NotNativeHost;
        }
        NativeHostReadOwnerState::Unavailable => {
            return NativeHostFileReadOutcome::Unavailable;
        }
        NativeHostReadOwnerState::Available(owner) => owner,
    };
    let (relative_path, wire_path) = match native_host_read_wire_path(path) {
        Ok(value) => value,
        Err(error) => return NativeHostFileReadOutcome::Rejected(error),
    };
    match owner.snapshot_empty_directories(&relative_path, include_hidden) {
        Ok(paths) => {
            let mut wire_paths = Vec::with_capacity(paths.len());
            for path in paths {
                match native_host_relative_to_wire_path(&path) {
                    Ok(path) => wire_paths.push(path),
                    Err(error) => return NativeHostFileReadOutcome::Rejected(error),
                }
            }
            NativeHostFileReadOutcome::Succeeded((wire_path, wire_paths))
        }
        Err(error) => NativeHostFileReadOutcome::Rejected(native_host_read_job_error(error)),
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn native_host_begin_read_job(
    id: i32,
    path: &str,
    start_file_num: i32,
    include_hidden: bool,
    overwrite_detection: bool,
) -> NativeHostReadJobAdmission {
    let owner = match native_host_read_owner() {
        NativeHostReadOwnerState::NotNativeHost => {
            return NativeHostReadJobAdmission::NotNativeHost;
        }
        NativeHostReadOwnerState::Unavailable => {
            return NativeHostReadJobAdmission::Unavailable;
        }
        NativeHostReadOwnerState::Available(owner) => owner,
    };
    let (relative_path, wire_path) = match native_host_read_wire_path(path) {
        Ok(value) => value,
        Err(error) => return NativeHostReadJobAdmission::Rejected(error),
    };
    let entries = match owner.snapshot_files_recursive(&relative_path, include_hidden) {
        Ok(entries) => entries,
        Err(error) => {
            return NativeHostReadJobAdmission::Rejected(native_host_read_job_error(error));
        }
    };
    let start_file_num = match usize::try_from(start_file_num) {
        Ok(value) => value,
        Err(_) => {
            return NativeHostReadJobAdmission::Rejected(NativeHostReadJobError::InvalidFileNumber);
        }
    };
    if (entries.is_empty() && start_file_num != 0)
        || (!entries.is_empty() && start_file_num >= entries.len())
    {
        return NativeHostReadJobAdmission::Rejected(NativeHostReadJobError::InvalidFileNumber);
    }
    NativeHostReadJobAdmission::Admitted(NativeHostReadJob {
        id,
        owner,
        wire_path,
        entries,
        next_file_num: start_file_num,
        current_file: None,
        current_offset: 0,
        awaiting_confirmation: None,
        overwrite_detection,
    })
}

#[cfg(target_os = "macos")]
fn native_host_read_wire_path(path: &str) -> Result<(PathBuf, String), NativeHostReadJobError> {
    if path.is_empty() || path == "/" {
        return Ok((PathBuf::new(), "/".to_owned()));
    }
    let relative = path.strip_prefix('/').unwrap_or(path);
    if relative.is_empty()
        || relative.starts_with('/')
        || relative.ends_with('/')
        || relative.as_bytes().contains(&0)
    {
        return Err(NativeHostReadJobError::InvalidPath);
    }
    let relative_path = PathBuf::from(relative);
    if relative_path.components().any(|component| {
        !matches!(component, Component::Normal(value) if value.as_bytes() != b"." && value.as_bytes() != b"..")
    }) {
        return Err(NativeHostReadJobError::InvalidPath);
    }
    Ok((relative_path, format!("/{relative}")))
}

#[cfg(target_os = "macos")]
fn native_host_relative_to_wire_path(path: &Path) -> Result<String, NativeHostReadJobError> {
    if path.as_os_str().is_empty() {
        return Ok("/".to_owned());
    }
    let path = path.to_str().ok_or(NativeHostReadJobError::InvalidPath)?;
    Ok(format!("/{path}"))
}

#[cfg(target_os = "macos")]
fn native_host_read_list_entry(
    entry: &rdn_host_file_transfer::NativeHostReadEntry,
) -> NativeHostReadListEntry {
    NativeHostReadListEntry {
        name: entry.wire_name().to_owned(),
        kind: match entry.kind() {
            rdn_host_file_transfer::NativeHostReadEntryKind::Directory => {
                NativeHostReadEntryKind::Directory
            }
            rdn_host_file_transfer::NativeHostReadEntryKind::File => NativeHostReadEntryKind::File,
        },
        size: entry.size(),
        modified_time: entry.modified_time(),
    }
}

#[cfg(target_os = "macos")]
fn native_host_read_job_error(
    error: rdn_host_file_transfer::NativeFileTransferRootError,
) -> NativeHostReadJobError {
    match error {
        rdn_host_file_transfer::NativeFileTransferRootError::InvalidRelativePath => {
            NativeHostReadJobError::InvalidPath
        }
        rdn_host_file_transfer::NativeFileTransferRootError::ReadSnapshotChanged => {
            NativeHostReadJobError::SnapshotChanged
        }
        _ => NativeHostReadJobError::ReadFailed,
    }
}

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

#[repr(C)]
#[derive(Clone, Copy)]
#[allow(dead_code)] // constructed by C callers through the ABI boundary
pub enum RdnHostStopReason {
    UserRequest = 0,
    AppExit = 1,
    Error = 2,
}

/// Owned byte buffer returned by `rdn_host_copy_snapshot`; freed with
/// `rdn_host_free_bytes`. `length` is the valid UTF-8 byte count, `capacity`
/// is the allocation size and must be used for deallocation.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostOwnedBytes {
    data: *mut u8,
    length: usize,
    capacity: usize,
}

type RdnHostEventCallback = unsafe extern "C" fn(*mut c_void, *const c_char, usize);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostCallbacks {
    abi_version: u32,
    /// Versioned JSON event envelope (§8.5). Called outside Rust locks; the
    /// UTF-8 payload is only valid for the duration of the call.
    on_event: Option<RdnHostEventCallback>,
    /// Opaque pointer passed back as the first argument of every callback.
    context: *mut c_void,
}

/// Canonical server configuration is copied during create and installed in
/// the isolated config root before any identity or rendezvous access (§18).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostCreateOptions {
    abi_version: u32,
    rendezvous_server: *const c_char,
    relay_server: *const c_char,
    server_public_key: *const c_char,
    enable_clipboard_read: bool,
    enable_clipboard_write: bool,
    enable_clipboard_rich_text_read: bool,
    enable_clipboard_rich_text_write: bool,
    enable_clipboard_image_read: bool,
    enable_clipboard_image_write: bool,
    enable_audio: bool,
    audio_input_device: *const c_char,
    enable_file_transfer: bool,
    file_transfer_receive_root: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostEncoderCapabilities {
    abi_version: u32,
    host_instance_id: *const c_char,
    h264_hardware: u32,
    h265_hardware: u32,
    max_width: u32,
    max_height: u32,
    max_fps: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostEncodedAccessUnit {
    abi_version: u32,
    host_instance_id: *const c_char,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    codec: u32,
    framing: u32,
    flags: u32,
    pts_us: u64,
    data: *const u8,
    length: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RdnHostEncoderState {
    abi_version: u32,
    host_instance_id: *const c_char,
    connection_epoch: u64,
    codec_epoch: u64,
    codec: u32,
    hardware_accelerated: u32,
    software_fallback: u32,
    encoder_id: *const c_char,
}

// Process-global guards. `CONFIG_ROOT_SET` enforces the one-time early entry;
// `HOST_INSTANCE_LIVE` enforces the single-instance/exclusion contract and
// will also gate viewer-core coexistence checks (§18 rule 1).
static CONFIG_ROOT_SET: AtomicBool = AtomicBool::new(false);
static HOST_INSTANCE_LIVE: AtomicBool = AtomicBool::new(false);

pub struct RdnHost {
    instance_id: String,
    state: RdnHostState,
    local_id: String,
    registration_status: &'static str,
    recovery_epoch: u64,
    recovery_state: HostRecoveryState,
    network_path_generation: u64,
    reveal_temporary_password: bool,
    last_error: Option<String>,
    event_id: Arc<AtomicU64>,
    callbacks: RdnHostCallbacks,
    rendezvous_server: String,
    relay_server: String,
    server_public_key: String,
    clipboard_transfer_policy: NativeClipboardTransferPolicy,
    audio_enabled: bool,
    audio_input_device: String,
    file_transfer_enabled: bool,
    #[cfg(target_os = "macos")]
    file_service_owner: Option<Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>>,
    runtime: Option<HostRuntime>,
}

struct HostRuntime {
    stop_requested: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

struct RuntimeFinished(Arc<AtomicBool>);

const HOST_RUNTIME_RECONNECT_BASE_DELAY_MS: u64 = 250;
const HOST_RUNTIME_RECONNECT_MAX_DELAY_MS: u64 = 5_000;
const HOST_RUNTIME_RECONNECT_STABLE_CONNECTION_MS: u64 = 30_000;
const HOST_RUNTIME_RECONNECT_STOP_POLL_MS: u64 = 50;
const HOST_RUNTIME_REGISTRATION_STALL_TIMEOUT_MS: u64 = 15_000;

#[derive(Default)]
struct HostRuntimeReconnectBackoff {
    consecutive_failures: u32,
}

#[derive(Default)]
struct HostRuntimeRegistrationWatchdog {
    unhealthy_since: Option<Instant>,
}

impl HostRuntimeRegistrationWatchdog {
    fn should_restart(&mut self, now: Instant, registration_healthy: bool) -> bool {
        if registration_healthy {
            self.unhealthy_since = None;
            return false;
        }
        let unhealthy_since = self.unhealthy_since.get_or_insert(now);
        now.saturating_duration_since(*unhealthy_since)
            >= Duration::from_millis(HOST_RUNTIME_REGISTRATION_STALL_TIMEOUT_MS)
    }
}

#[derive(Debug, PartialEq, Eq)]
enum HostRuntimeRegistrationWatchdogOutcome {
    RegistrationStalled,
    StopRequested,
}

impl HostRuntimeReconnectBackoff {
    fn delay_after_exit(&mut self, connection_lifetime: Duration, jitter_sample: u64) -> Duration {
        if connection_lifetime >= Duration::from_millis(HOST_RUNTIME_RECONNECT_STABLE_CONNECTION_MS)
        {
            self.consecutive_failures = 0;
        }
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        let doublings = self.consecutive_failures.saturating_sub(1).min(5);
        let nominal = HOST_RUNTIME_RECONNECT_BASE_DELAY_MS
            .saturating_mul(1_u64 << doublings)
            .min(HOST_RUNTIME_RECONNECT_MAX_DELAY_MS);
        let jitter_upper_bound = nominal / 4;
        let jitter = if jitter_upper_bound == 0 {
            0
        } else {
            jitter_sample % (jitter_upper_bound + 1)
        };
        Duration::from_millis(
            nominal
                .saturating_add(jitter)
                .min(HOST_RUNTIME_RECONNECT_MAX_DELAY_MS),
        )
    }
}

/// Caller-owned secret bytes borrowed across the C ABI. Every return path
/// after a valid pointer/length pair reaches this guard and wipes the complete
/// caller buffer with libsodium before Rust releases the borrow.
struct SecretBuffer<'a> {
    bytes: &'a mut [u8],
}

impl SecretBuffer<'_> {
    unsafe fn from_raw_parts(pointer: *mut u8, length: usize) -> Self {
        Self {
            bytes: std::slice::from_raw_parts_mut(pointer, length),
        }
    }

    fn bytes(&self) -> &[u8] {
        self.bytes
    }
}

impl Drop for SecretBuffer<'_> {
    fn drop(&mut self) {
        password_security::memzero_secret(self.bytes);
    }
}

#[derive(Clone, Copy)]
struct PasswordPolicyRejection {
    code: i32,
    detail: &'static str,
}

fn validate_permanent_password(bytes: &[u8]) -> Result<&str, PasswordPolicyRejection> {
    if bytes.is_empty() {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_EMPTY,
            detail: "permanent-password-empty",
        });
    }
    if bytes.len() > PERMANENT_PASSWORD_MAX_UTF8_BYTES {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_TOO_LONG,
            detail: "permanent-password-too-long",
        });
    }
    let password = std::str::from_utf8(bytes).map_err(|_| PasswordPolicyRejection {
        code: RDN_HOST_ERR_SECRET_INVALID_UTF8,
        detail: "permanent-password-invalid-utf8",
    })?;
    let character_count = password.chars().count();
    if character_count < PERMANENT_PASSWORD_MIN_CHARACTERS {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_TOO_SHORT,
            detail: "permanent-password-too-short",
        });
    }
    if character_count > PERMANENT_PASSWORD_MAX_CHARACTERS {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_TOO_LONG,
            detail: "permanent-password-too-long",
        });
    }
    if password.chars().any(char::is_control) {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_FORBIDDEN_CHARACTER,
            detail: "permanent-password-forbidden-character",
        });
    }
    if password
        .chars()
        .next()
        .map(char::is_whitespace)
        .unwrap_or(false)
        || password
            .chars()
            .next_back()
            .map(char::is_whitespace)
            .unwrap_or(false)
    {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_OUTER_WHITESPACE,
            detail: "permanent-password-outer-whitespace",
        });
    }
    Ok(password)
}

#[derive(Clone)]
struct MediaHostBinding {
    instance_id: String,
    callback: Option<RdnHostEventCallback>,
    context: usize,
    event_id: Arc<AtomicU64>,
}

#[derive(Clone, Copy, Default)]
struct MediaCapabilities {
    h264_hardware: bool,
    h265_hardware: bool,
    max_width: u32,
    max_height: u32,
    max_fps: u32,
}

struct MediaRoute {
    connection_epoch: u64,
    codec_epoch: u64,
    display_revision: u64,
    codec: u32,
    sender: SyncSender<NativeMediaAccessUnit>,
    queue_telemetry: Arc<NativeMediaQueueTelemetry>,
    writer_telemetry: Arc<NativeMediaWriterTelemetry>,
    network_telemetry: Arc<NativeMediaNetworkTelemetry>,
    transport_telemetry: Arc<NativeMediaTransportTelemetry>,
    last_pts_us: Option<u64>,
    needs_parameter_sets: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct NativeDisplayReconfigureProvenance {
    generation: u64,
    previous_display_revision: u64,
    previous_connection_epoch: u64,
    previous_codec_epoch: u64,
}

impl NativeDisplayReconfigureProvenance {
    fn payload(self) -> Value {
        json!({
            "displayReconfigureGeneration": self.generation,
            "previousDisplayRevision": self.previous_display_revision,
            "previousConnectionEpoch": self.previous_connection_epoch,
            "previousCodecEpoch": self.previous_codec_epoch,
        })
    }
}

#[derive(Default)]
struct MediaBroker {
    binding: Option<MediaHostBinding>,
    capabilities: MediaCapabilities,
    clipboard_transfer_policy: NativeClipboardTransferPolicy,
    #[cfg(target_os = "macos")]
    file_service_owner: Option<Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>>,
    routes: HashMap<u64, MediaRoute>,
    display_revisions: HashMap<u64, u64>,
    pending_display_reconfigures: HashMap<u64, NativeDisplayReconfigureProvenance>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeApprovalRequest {
    connection_id: String,
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    requested_at_ms: u64,
    expires_at_ms: u64,
    requested_capabilities: Vec<String>,
}

impl NativeApprovalRequest {
    fn event_payload(&self) -> Value {
        json!({
            "connectionId": self.connection_id,
            "remoteId": self.remote_id,
            "remoteName": self.remote_name,
            "remotePlatform": self.remote_platform,
            "remoteMetadataTrust": "untrusted",
            "requestedAt": self.requested_at_ms,
            "expiresAt": self.expires_at_ms,
            "requestedCapabilities": self.requested_capabilities,
            "transport": "unknown",
            "authenticationMethod": "localApproval",
            "riskAlerts": [],
        })
    }
}

struct PendingNativeApproval {
    request: NativeApprovalRequest,
    deadline: Instant,
    decision_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeApprovalFinalStatus {
    Approved,
    Rejected,
    Expired,
    Cancelled,
}

impl NativeApprovalFinalStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Approved => "approved",
            Self::Rejected => "rejected",
            Self::Expired => "expired",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeApprovalStartResult {
    Accepted,
    Existing,
    Busy,
    Finalized,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeApprovalDecision {
    Approve,
    Reject,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeApprovalResolveResult {
    Approved,
    Rejected,
    Expired,
    AlreadyFinal,
    NotFound,
}

struct NativeApprovalCompletion {
    pending: PendingNativeApproval,
    status: NativeApprovalFinalStatus,
}

#[derive(Default)]
struct NativeApprovalBroker {
    pending: Option<PendingNativeApproval>,
    last_finalized: Option<(String, NativeApprovalFinalStatus)>,
}

impl NativeApprovalBroker {
    fn begin(&mut self, pending: PendingNativeApproval) -> NativeApprovalStartResult {
        if self
            .last_finalized
            .as_ref()
            .map(|(connection_id, _)| connection_id == &pending.request.connection_id)
            .unwrap_or(false)
        {
            return NativeApprovalStartResult::Finalized;
        }
        if let Some(current) = self.pending.as_ref() {
            return if current.request.connection_id == pending.request.connection_id {
                NativeApprovalStartResult::Existing
            } else {
                NativeApprovalStartResult::Busy
            };
        }
        self.pending = Some(pending);
        NativeApprovalStartResult::Accepted
    }

    fn resolve(
        &mut self,
        connection_id: &str,
        decision: NativeApprovalDecision,
        now: Instant,
    ) -> (
        NativeApprovalResolveResult,
        Option<NativeApprovalCompletion>,
    ) {
        let Some(pending) = self.pending.as_ref() else {
            let already_final = self
                .last_finalized
                .as_ref()
                .map(|(finalized_id, _)| finalized_id == connection_id)
                .unwrap_or(false);
            return (
                if already_final {
                    NativeApprovalResolveResult::AlreadyFinal
                } else {
                    NativeApprovalResolveResult::NotFound
                },
                None,
            );
        };
        if pending.request.connection_id != connection_id {
            return (NativeApprovalResolveResult::NotFound, None);
        }

        let (status, result) = if now >= pending.deadline {
            (
                NativeApprovalFinalStatus::Expired,
                NativeApprovalResolveResult::Expired,
            )
        } else {
            match decision {
                NativeApprovalDecision::Approve => (
                    NativeApprovalFinalStatus::Approved,
                    NativeApprovalResolveResult::Approved,
                ),
                NativeApprovalDecision::Reject => (
                    NativeApprovalFinalStatus::Rejected,
                    NativeApprovalResolveResult::Rejected,
                ),
            }
        };
        let Some(pending) = self.pending.take() else {
            return (NativeApprovalResolveResult::NotFound, None);
        };
        self.last_finalized = Some((pending.request.connection_id.clone(), status));
        (result, Some(NativeApprovalCompletion { pending, status }))
    }

    fn expire(&mut self, connection_id: &str, now: Instant) -> Option<NativeApprovalCompletion> {
        let should_expire = self
            .pending
            .as_ref()
            .map(|pending| {
                pending.request.connection_id == connection_id && now >= pending.deadline
            })
            .unwrap_or(false);
        if !should_expire {
            return None;
        }
        let pending = self.pending.take()?;
        self.last_finalized = Some((
            pending.request.connection_id.clone(),
            NativeApprovalFinalStatus::Expired,
        ));
        Some(NativeApprovalCompletion {
            pending,
            status: NativeApprovalFinalStatus::Expired,
        })
    }

    fn cancel(&mut self, core_connection_id: i32) -> Option<NativeApprovalCompletion> {
        let matches = self
            .pending
            .as_ref()
            .map(|pending| pending.request.core_connection_id == core_connection_id)
            .unwrap_or(false);
        if !matches {
            return None;
        }
        let pending = self.pending.take()?;
        self.last_finalized = Some((
            pending.request.connection_id.clone(),
            NativeApprovalFinalStatus::Cancelled,
        ));
        Some(NativeApprovalCompletion {
            pending,
            status: NativeApprovalFinalStatus::Cancelled,
        })
    }

    fn reset(&mut self) -> Option<PendingNativeApproval> {
        self.last_finalized = None;
        self.pending.take()
    }

    fn snapshot(
        &mut self,
        now: Instant,
    ) -> (
        Option<NativeApprovalRequest>,
        Option<NativeApprovalCompletion>,
    ) {
        let expired_connection_id = self
            .pending
            .as_ref()
            .filter(|pending| now >= pending.deadline)
            .map(|pending| pending.request.connection_id.clone());
        let completion = expired_connection_id
            .as_deref()
            .and_then(|connection_id| self.expire(connection_id, now));
        let request = self.pending.as_ref().map(|pending| pending.request.clone());
        (request, completion)
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct NativeClipboardPolicy {
    remote_read: bool,
    remote_write: bool,
}

impl NativeClipboardPolicy {
    pub(crate) fn new(remote_read: bool, remote_write: bool) -> Self {
        Self {
            remote_read,
            remote_write,
        }
    }

    pub(crate) fn bidirectional(enabled: bool) -> Self {
        Self::new(enabled, enabled)
    }

    pub(crate) fn allows_remote_read(self) -> bool {
        self.remote_read
    }

    pub(crate) fn allows_remote_write(self) -> bool {
        self.remote_write
    }

    pub(crate) fn restricted_to(self, enabled: bool) -> Self {
        if enabled {
            self
        } else {
            Self::default()
        }
    }

    fn any_enabled(self) -> bool {
        self.remote_read || self.remote_write
    }

    fn is_subset_of(self, other: Self) -> bool {
        (!self.remote_read || other.remote_read) && (!self.remote_write || other.remote_write)
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct NativeClipboardTransferPolicy {
    small_text: NativeClipboardPolicy,
    rich_text: NativeClipboardPolicy,
    image: NativeClipboardPolicy,
}

impl NativeClipboardTransferPolicy {
    pub(crate) fn new(small_text: NativeClipboardPolicy, rich_text: NativeClipboardPolicy) -> Self {
        Self::with_image_policy(small_text, rich_text, NativeClipboardPolicy::default())
    }

    pub(crate) fn with_image_policy(
        small_text: NativeClipboardPolicy,
        rich_text: NativeClipboardPolicy,
        image: NativeClipboardPolicy,
    ) -> Self {
        Self {
            small_text,
            rich_text,
            image,
        }
    }

    pub(crate) fn small_text(self) -> NativeClipboardPolicy {
        self.small_text
    }

    pub(crate) fn rich_text(self) -> NativeClipboardPolicy {
        self.rich_text
    }

    pub(crate) fn image(self) -> NativeClipboardPolicy {
        self.image
    }

    pub(crate) fn directions(self) -> NativeClipboardPolicy {
        NativeClipboardPolicy::new(
            self.small_text.allows_remote_read()
                || self.rich_text.allows_remote_read()
                || self.image.allows_remote_read(),
            self.small_text.allows_remote_write()
                || self.rich_text.allows_remote_write()
                || self.image.allows_remote_write(),
        )
    }

    fn any_enabled(self) -> bool {
        self.small_text.any_enabled() || self.rich_text.any_enabled() || self.image.any_enabled()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeClipboardDirection {
    RemoteRead,
    RemoteWrite,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeClipboardPayloadDisposition {
    InlineSmallText,
    // This remains a routing requirement rather than admission: a separate
    // format-specific direction policy must authorize the bounded canonical payload.
    IndependentTransferRequired,
    Reject,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeRichTextFormat {
    Rtf,
    Html,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeRichTextTransferEnvelope {
    format: NativeRichTextFormat,
    payload: String,
}

impl NativeRichTextTransferEnvelope {
    fn from_clipboard(clipboard: &Clipboard) -> Option<Self> {
        let format = match clipboard.format.enum_value().ok()? {
            ClipboardFormat::Rtf => NativeRichTextFormat::Rtf,
            ClipboardFormat::Html => NativeRichTextFormat::Html,
            _ => return None,
        };
        if !clipboard.special_name.is_empty()
            || clipboard.width != 0
            || clipboard.height != 0
            || clipboard.content.is_empty()
            || clipboard.content.len() > MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES
        {
            return None;
        }
        let decoded = if clipboard.compress {
            hbb_common::compress::decompress_with_limit(
                &clipboard.content,
                MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
            )
            .ok()?
        } else {
            clipboard.content.to_vec()
        };
        if decoded.is_empty() || decoded.len() > MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES {
            return None;
        }
        let payload = String::from_utf8(decoded).ok()?;
        if payload.contains('\0') {
            return None;
        }
        Some(Self { format, payload })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeImageFormat {
    Rgba { width: i32, height: i32 },
    Png { width: i32, height: i32 },
    Svg,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeImageTransferEnvelope {
    format: NativeImageFormat,
    payload: Vec<u8>,
}

impl NativeImageTransferEnvelope {
    fn from_clipboard(clipboard: &Clipboard) -> Option<Self> {
        if !clipboard.special_name.is_empty() {
            return None;
        }
        match clipboard.format.enum_value().ok()? {
            ClipboardFormat::ImageRgba => {
                let pixel_count = native_image_pixel_count(clipboard.width, clipboard.height)?;
                let expected_bytes = pixel_count.checked_mul(4)?;
                let payload = native_image_payload_bytes(
                    clipboard,
                    MAX_CLIPBOARD_IMAGE_WIRE_BYTES,
                    MAX_CLIPBOARD_IMAGE_DECODED_BYTES,
                    true,
                )?;
                if payload.len() != expected_bytes {
                    return None;
                }
                Some(Self {
                    format: NativeImageFormat::Rgba {
                        width: clipboard.width,
                        height: clipboard.height,
                    },
                    payload,
                })
            }
            ClipboardFormat::ImagePng => {
                if clipboard.width != 0 || clipboard.height != 0 {
                    return None;
                }
                // Pinned upstream already emits PNG as its compressed image
                // representation, so a second zstd layer is non-canonical.
                let payload = native_image_payload_bytes(
                    clipboard,
                    MAX_CLIPBOARD_IMAGE_WIRE_BYTES,
                    MAX_CLIPBOARD_IMAGE_WIRE_BYTES,
                    false,
                )?;
                let (width, height) = native_png_dimensions(&payload)?;
                Some(Self {
                    format: NativeImageFormat::Png { width, height },
                    payload,
                })
            }
            ClipboardFormat::ImageSvg => {
                if clipboard.width != 0 || clipboard.height != 0 {
                    return None;
                }
                let payload = native_image_payload_bytes(
                    clipboard,
                    MAX_CLIPBOARD_SVG_WIRE_BYTES,
                    MAX_CLIPBOARD_SVG_UTF8_BYTES,
                    true,
                )?;
                let svg = std::str::from_utf8(&payload).ok()?;
                if svg.contains('\0') || !native_svg_has_canonical_root(svg) {
                    return None;
                }
                Some(Self {
                    format: NativeImageFormat::Svg,
                    payload,
                })
            }
            _ => None,
        }
    }

    fn into_canonical_clipboard(self) -> Clipboard {
        let (format, width, height) = match self.format {
            NativeImageFormat::Rgba { width, height } => {
                (ClipboardFormat::ImageRgba, width, height)
            }
            NativeImageFormat::Png { .. } => (ClipboardFormat::ImagePng, 0, 0),
            NativeImageFormat::Svg => (ClipboardFormat::ImageSvg, 0, 0),
        };
        Clipboard {
            content: self.payload.into(),
            format: format.into(),
            width,
            height,
            ..Default::default()
        }
    }
}

fn native_image_payload_bytes(
    clipboard: &Clipboard,
    wire_limit: usize,
    decoded_limit: usize,
    allow_compressed: bool,
) -> Option<Vec<u8>> {
    if clipboard.content.is_empty() || clipboard.content.len() > wire_limit {
        return None;
    }
    let payload = if clipboard.compress {
        if !allow_compressed {
            return None;
        }
        hbb_common::compress::decompress_with_limit(&clipboard.content, decoded_limit).ok()?
    } else {
        clipboard.content.to_vec()
    };
    (!payload.is_empty() && payload.len() <= decoded_limit).then_some(payload)
}

fn native_image_pixel_count(width: i32, height: i32) -> Option<usize> {
    if width <= 0
        || height <= 0
        || width > MAX_CLIPBOARD_IMAGE_DIMENSION
        || height > MAX_CLIPBOARD_IMAGE_DIMENSION
    {
        return None;
    }
    let pixels = usize::try_from(width)
        .ok()?
        .checked_mul(usize::try_from(height).ok()?)?;
    (pixels <= MAX_CLIPBOARD_IMAGE_PIXELS).then_some(pixels)
}

fn native_png_dimensions(payload: &[u8]) -> Option<(i32, i32)> {
    const SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
    if payload.len() < 33 || payload.get(..8)? != SIGNATURE {
        return None;
    }

    let mut offset = 8usize;
    let mut dimensions = None;
    let mut has_image_data = false;
    loop {
        let header_end = offset.checked_add(8)?;
        if header_end > payload.len() {
            return None;
        }
        let length = u32::from_be_bytes(payload[offset..offset + 4].try_into().ok()?) as usize;
        let chunk_type = &payload[offset + 4..header_end];
        let chunk_end = header_end.checked_add(length)?.checked_add(4)?;
        if chunk_end > payload.len() {
            return None;
        }
        let data = &payload[header_end..header_end + length];
        match chunk_type {
            b"IHDR" if offset == 8 && length == 13 && dimensions.is_none() => {
                let width = u32::from_be_bytes(data[0..4].try_into().ok()?);
                let height = u32::from_be_bytes(data[4..8].try_into().ok()?);
                let width = i32::try_from(width).ok()?;
                let height = i32::try_from(height).ok()?;
                native_image_pixel_count(width, height)?;
                let bit_depth = data[8];
                let color_type = data[9];
                let valid_depth = match color_type {
                    0 => matches!(bit_depth, 1 | 2 | 4 | 8 | 16),
                    2 | 4 | 6 => matches!(bit_depth, 8 | 16),
                    3 => matches!(bit_depth, 1 | 2 | 4 | 8),
                    _ => false,
                };
                if !valid_depth || data[10] != 0 || data[11] != 0 || data[12] > 1 {
                    return None;
                }
                dimensions = Some((width, height));
            }
            b"IHDR" => return None,
            b"IDAT" if dimensions.is_some() && length > 0 => has_image_data = true,
            b"IEND" if length == 0 => {
                return (chunk_end == payload.len() && has_image_data).then_some(dimensions?)
            }
            _ if dimensions.is_none() => return None,
            _ => {}
        }
        offset = chunk_end;
    }
}

fn native_svg_has_canonical_root(svg: &str) -> bool {
    let mut remainder = svg.trim_start_matches(['\u{feff}', ' ', '\t', '\r', '\n']);
    if remainder.starts_with("<?xml") {
        let Some(end) = remainder
            .get(..1024.min(remainder.len()))
            .and_then(|prefix| prefix.find("?>"))
        else {
            return false;
        };
        remainder = remainder[end + 2..].trim_start();
    }
    if remainder
        .as_bytes()
        .windows(9)
        .any(|window| window.eq_ignore_ascii_case(b"<!doctype"))
    {
        return false;
    }
    let Some(after_root) = remainder.strip_prefix("<svg") else {
        return false;
    };
    after_root
        .as_bytes()
        .first()
        .is_some_and(|byte| byte.is_ascii_whitespace() || *byte == b'>')
        && after_root.contains('>')
}

pub(crate) fn native_host_configured_clipboard_transfer_policy() -> NativeClipboardTransferPolicy {
    let broker = MEDIA_BROKER.lock().unwrap();
    if broker.binding.is_some() {
        broker.clipboard_transfer_policy
    } else {
        NativeClipboardTransferPolicy::default()
    }
}

fn native_host_small_text_payload(clipboard: &Clipboard) -> Option<String> {
    if clipboard.format.enum_value().ok()? != ClipboardFormat::Text
        || !clipboard.special_name.is_empty()
        || clipboard.width != 0
        || clipboard.height != 0
        || clipboard.content.is_empty()
        || clipboard.content.len() > MAX_CLIPBOARD_TEXT_UTF8_BYTES
    {
        return None;
    }
    let decoded = if clipboard.compress {
        hbb_common::compress::decompress_with_limit(
            &clipboard.content,
            MAX_CLIPBOARD_TEXT_UTF8_BYTES,
        )
        .ok()?
    } else {
        clipboard.content.to_vec()
    };
    if decoded.is_empty() || decoded.len() > MAX_CLIPBOARD_TEXT_UTF8_BYTES {
        return None;
    }
    let text = String::from_utf8(decoded).ok()?;
    (!text.contains('\0')).then_some(text)
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct NativeRichTextTransferBundle {
    plain_text: Option<String>,
    rtf: Option<String>,
    html: Option<String>,
}

impl NativeRichTextTransferBundle {
    fn from_clipboards(clipboards: &[Clipboard]) -> Option<Self> {
        if clipboards.is_empty() || clipboards.len() > 3 {
            return None;
        }
        let mut bundle = Self::default();
        for clipboard in clipboards {
            match clipboard.format.enum_value().ok()? {
                ClipboardFormat::Text => {
                    if bundle.plain_text.is_some() {
                        return None;
                    }
                    bundle.plain_text = Some(native_host_small_text_payload(clipboard)?);
                }
                ClipboardFormat::Rtf | ClipboardFormat::Html => {
                    let envelope = NativeRichTextTransferEnvelope::from_clipboard(clipboard)?;
                    match envelope.format {
                        NativeRichTextFormat::Rtf => {
                            if bundle.rtf.is_some() {
                                return None;
                            }
                            bundle.rtf = Some(envelope.payload);
                        }
                        NativeRichTextFormat::Html => {
                            if bundle.html.is_some() {
                                return None;
                            }
                            bundle.html = Some(envelope.payload);
                        }
                    }
                }
                _ => return None,
            }
        }
        (bundle.rtf.is_some() || bundle.html.is_some()).then_some(bundle)
    }

    fn into_canonical_clipboards(self) -> Vec<Clipboard> {
        let mut clipboards = Vec::with_capacity(3);
        for (format, payload) in [
            (ClipboardFormat::Text, self.plain_text),
            (ClipboardFormat::Rtf, self.rtf),
            (ClipboardFormat::Html, self.html),
        ] {
            if let Some(payload) = payload {
                clipboards.push(native_host_canonical_clipboard(format, payload));
            }
        }
        clipboards
    }
}

fn native_host_canonical_clipboard(format: ClipboardFormat, payload: String) -> Clipboard {
    Clipboard {
        content: payload.into_bytes().into(),
        format: format.into(),
        ..Default::default()
    }
}

fn native_host_clipboard_payload_disposition(
    clipboard: &Clipboard,
) -> NativeClipboardPayloadDisposition {
    let Ok(format) = clipboard.format.enum_value() else {
        return NativeClipboardPayloadDisposition::Reject;
    };
    match format {
        ClipboardFormat::Text => {
            if native_host_small_text_payload(clipboard).is_some() {
                NativeClipboardPayloadDisposition::InlineSmallText
            } else {
                NativeClipboardPayloadDisposition::Reject
            }
        }
        ClipboardFormat::Rtf | ClipboardFormat::Html => {
            NativeRichTextTransferEnvelope::from_clipboard(clipboard)
                .map_or(NativeClipboardPayloadDisposition::Reject, |_| {
                    NativeClipboardPayloadDisposition::IndependentTransferRequired
                })
        }
        ClipboardFormat::ImageRgba | ClipboardFormat::ImagePng | ClipboardFormat::ImageSvg => {
            NativeImageTransferEnvelope::from_clipboard(clipboard)
                .map_or(NativeClipboardPayloadDisposition::Reject, |_| {
                    NativeClipboardPayloadDisposition::IndependentTransferRequired
                })
        }
        // Special names are remote-controlled UTI/format identifiers. They
        // stay rejected until an explicit allowlist and bounded transfer
        // envelope own both the identifier and payload.
        ClipboardFormat::Special => NativeClipboardPayloadDisposition::Reject,
    }
}

fn native_host_small_text_clipboard(clipboard: &Clipboard) -> bool {
    native_host_clipboard_payload_disposition(clipboard)
        == NativeClipboardPayloadDisposition::InlineSmallText
}

fn native_host_clipboard_policy_allows(
    policy: NativeClipboardPolicy,
    direction: NativeClipboardDirection,
) -> bool {
    match direction {
        NativeClipboardDirection::RemoteRead => policy.allows_remote_read(),
        NativeClipboardDirection::RemoteWrite => policy.allows_remote_write(),
    }
}

fn native_host_clipboard_entries_disposition(
    clipboards: &[Clipboard],
) -> NativeClipboardPayloadDisposition {
    if clipboards.len() == 1
        && clipboards
            .first()
            .is_some_and(native_host_small_text_clipboard)
    {
        NativeClipboardPayloadDisposition::InlineSmallText
    } else if NativeRichTextTransferBundle::from_clipboards(clipboards).is_some()
        || (clipboards.len() == 1
            && clipboards
                .first()
                .and_then(NativeImageTransferEnvelope::from_clipboard)
                .is_some())
    {
        NativeClipboardPayloadDisposition::IndependentTransferRequired
    } else {
        NativeClipboardPayloadDisposition::Reject
    }
}

fn native_host_prepare_clipboard_entries(
    transfer_policy: NativeClipboardTransferPolicy,
    active_directions: NativeClipboardPolicy,
    direction: NativeClipboardDirection,
    clipboards: &[Clipboard],
) -> Option<Vec<Clipboard>> {
    if !native_host_clipboard_policy_allows(active_directions, direction) {
        return None;
    }
    if let [clipboard] = clipboards {
        if let Some(image) = NativeImageTransferEnvelope::from_clipboard(clipboard) {
            return native_host_clipboard_policy_allows(transfer_policy.image(), direction)
                .then(|| vec![image.into_canonical_clipboard()]);
        }
    }
    match native_host_clipboard_entries_disposition(clipboards) {
        NativeClipboardPayloadDisposition::InlineSmallText
            if native_host_clipboard_policy_allows(transfer_policy.small_text(), direction) =>
        {
            let text = native_host_small_text_payload(clipboards.first()?)?;
            Some(vec![native_host_canonical_clipboard(
                ClipboardFormat::Text,
                text,
            )])
        }
        NativeClipboardPayloadDisposition::IndependentTransferRequired
            if native_host_clipboard_policy_allows(transfer_policy.rich_text(), direction) =>
        {
            Some(
                NativeRichTextTransferBundle::from_clipboards(clipboards)?
                    .into_canonical_clipboards(),
            )
        }
        _ => None,
    }
}

#[derive(Debug)]
pub(crate) enum NativeHostOutgoingClipboardDecision {
    NotClipboard,
    Send(Message),
    Reject,
}

pub(crate) fn native_host_prepare_outgoing_clipboard_message(
    message: &Message,
    transfer_policy: NativeClipboardTransferPolicy,
    active_directions: NativeClipboardPolicy,
) -> NativeHostOutgoingClipboardDecision {
    let entries = match message.union.as_ref() {
        Some(message::Union::Clipboard(clipboard)) => std::slice::from_ref(clipboard),
        Some(message::Union::MultiClipboards(clipboards)) => clipboards.clipboards.as_slice(),
        _ => return NativeHostOutgoingClipboardDecision::NotClipboard,
    };
    let Some(mut clipboards) = native_host_prepare_clipboard_entries(
        transfer_policy,
        active_directions,
        NativeClipboardDirection::RemoteRead,
        entries,
    ) else {
        return NativeHostOutgoingClipboardDecision::Reject;
    };
    let mut canonical = Message::new();
    if clipboards.len() == 1 {
        canonical.set_clipboard(clipboards.remove(0));
    } else {
        canonical.set_multi_clipboards(MultiClipboards {
            clipboards,
            ..Default::default()
        });
    }
    NativeHostOutgoingClipboardDecision::Send(canonical)
}

pub(crate) fn native_host_prepare_incoming_clipboard_entries(
    clipboards: &[Clipboard],
    transfer_policy: NativeClipboardTransferPolicy,
    active_directions: NativeClipboardPolicy,
) -> Option<Vec<Clipboard>> {
    native_host_prepare_clipboard_entries(
        transfer_policy,
        active_directions,
        NativeClipboardDirection::RemoteWrite,
        clipboards,
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NativeSessionCapabilities {
    control_keyboard_mouse: bool,
    clipboard: NativeClipboardPolicy,
    system_audio: bool,
}

impl NativeSessionCapabilities {
    pub(crate) fn new(control_keyboard_mouse: bool, clipboard: bool, system_audio: bool) -> Self {
        Self::with_clipboard_policy(
            control_keyboard_mouse,
            NativeClipboardPolicy::bidirectional(clipboard),
            system_audio,
        )
    }

    pub(crate) fn with_clipboard_policy(
        control_keyboard_mouse: bool,
        clipboard: NativeClipboardPolicy,
        system_audio: bool,
    ) -> Self {
        Self {
            control_keyboard_mouse,
            clipboard,
            system_audio,
        }
    }

    fn names(self) -> Vec<&'static str> {
        let mut names = vec!["viewDisplay"];
        if self.control_keyboard_mouse {
            names.push("controlKeyboardMouse");
        }
        if self.clipboard.remote_read {
            names.push("readClipboard");
        }
        if self.clipboard.remote_write {
            names.push("writeClipboard");
        }
        if self.system_audio {
            names.push("hearSystemAudio");
        }
        names
    }

    fn is_subset_of(self, other: Self) -> bool {
        (!self.control_keyboard_mouse || other.control_keyboard_mouse)
            && self.clipboard.is_subset_of(other.clipboard)
            && (!self.system_audio || other.system_audio)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeSessionInputUnavailableReason {
    LocalPolicyDisabled,
    RemoteDisabled,
    AccessibilityDenied,
    SessionUnavailable,
}

impl NativeSessionInputUnavailableReason {
    fn name(self) -> &'static str {
        match self {
            Self::LocalPolicyDisabled => "localPolicyDisabled",
            Self::RemoteDisabled => "remoteDisabled",
            Self::AccessibilityDenied => "accessibilityDenied",
            Self::SessionUnavailable => "sessionUnavailable",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeSessionInputAvailability {
    Available,
    Disabled(NativeSessionInputUnavailableReason),
    Limited(NativeSessionInputUnavailableReason),
}

impl NativeSessionInputAvailability {
    pub(crate) fn available() -> Self {
        Self::Available
    }

    pub(crate) fn disabled(reason: NativeSessionInputUnavailableReason) -> Self {
        debug_assert!(matches!(
            reason,
            NativeSessionInputUnavailableReason::LocalPolicyDisabled
                | NativeSessionInputUnavailableReason::RemoteDisabled
        ));
        Self::Disabled(reason)
    }

    pub(crate) fn limited(reason: NativeSessionInputUnavailableReason) -> Self {
        debug_assert!(matches!(
            reason,
            NativeSessionInputUnavailableReason::AccessibilityDenied
                | NativeSessionInputUnavailableReason::SessionUnavailable
        ));
        Self::Limited(reason)
    }

    fn name(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::Disabled(_) => "disabled",
            Self::Limited(_) => "limited",
        }
    }

    fn reason(self) -> Option<&'static str> {
        match self {
            Self::Available => None,
            Self::Disabled(reason) | Self::Limited(reason) => Some(reason.name()),
        }
    }

    fn is_valid(self, control_keyboard_mouse: bool) -> bool {
        match self {
            Self::Available => control_keyboard_mouse,
            Self::Disabled(
                NativeSessionInputUnavailableReason::LocalPolicyDisabled
                | NativeSessionInputUnavailableReason::RemoteDisabled,
            ) => !control_keyboard_mouse,
            Self::Limited(
                NativeSessionInputUnavailableReason::AccessibilityDenied
                | NativeSessionInputUnavailableReason::SessionUnavailable,
            ) => !control_keyboard_mouse,
            Self::Disabled(_) | Self::Limited(_) => false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeSessionSnapshot {
    connection_id: String,
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    started_at_ms: u64,
    initial_capabilities: NativeSessionCapabilities,
    active_capabilities: NativeSessionCapabilities,
    input_availability: NativeSessionInputAvailability,
}

impl NativeSessionSnapshot {
    fn event_payload(&self) -> Value {
        json!({
            "connectionId": self.connection_id,
            "remoteId": self.remote_id,
            "remoteName": self.remote_name,
            "remotePlatform": self.remote_platform,
            "remoteMetadataTrust": "untrusted",
            "startedAt": self.started_at_ms,
            "initialCapabilities": self.initial_capabilities.names(),
            "activeCapabilities": self.active_capabilities.names(),
            "inputAvailability": self.input_availability.name(),
            "inputUnavailableReason": self.input_availability.reason(),
        })
    }
}

struct NativeActiveSession {
    snapshot: NativeSessionSnapshot,
    command_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
    disconnect_requested: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionStartResult {
    Accepted,
    Existing,
    Busy,
    Invalid,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionCommand {
    DisableInput,
    DisableClipboardRead,
    DisableClipboardWrite,
    DisableClipboard,
    DisableAudio,
    Disconnect,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionCommandResult {
    Queued,
    NoChange,
    NotFound,
    Stale,
    Unavailable,
}

#[derive(Default)]
struct NativeSessionBroker {
    active: Option<NativeActiveSession>,
}

impl NativeSessionBroker {
    fn begin(&mut self, session: NativeActiveSession) -> NativeSessionStartResult {
        if !session
            .snapshot
            .active_capabilities
            .is_subset_of(session.snapshot.initial_capabilities)
            || !session
                .snapshot
                .input_availability
                .is_valid(session.snapshot.active_capabilities.control_keyboard_mouse)
        {
            return NativeSessionStartResult::Invalid;
        }
        if let Some(active) = self.active.as_ref() {
            return if active.snapshot.connection_id == session.snapshot.connection_id {
                if active.snapshot == session.snapshot {
                    NativeSessionStartResult::Existing
                } else {
                    NativeSessionStartResult::Invalid
                }
            } else {
                NativeSessionStartResult::Busy
            };
        }
        self.active = Some(session);
        NativeSessionStartResult::Accepted
    }

    fn update_capabilities(
        &mut self,
        core_connection_id: i32,
        active_capabilities: NativeSessionCapabilities,
        input_availability: NativeSessionInputAvailability,
    ) -> Option<NativeSessionSnapshot> {
        let active = self.active.as_mut()?;
        if active.snapshot.core_connection_id != core_connection_id
            || !active_capabilities.is_subset_of(active.snapshot.initial_capabilities)
            || !input_availability.is_valid(active_capabilities.control_keyboard_mouse)
        {
            return None;
        }
        if active.snapshot.active_capabilities == active_capabilities
            && active.snapshot.input_availability == input_availability
        {
            return None;
        }
        active.snapshot.active_capabilities = active_capabilities;
        active.snapshot.input_availability = input_availability;
        Some(active.snapshot.clone())
    }

    fn command(
        &mut self,
        connection_id: &str,
        command: NativeSessionCommand,
    ) -> NativeSessionCommandResult {
        let Some(active) = self.active.as_mut() else {
            return NativeSessionCommandResult::NotFound;
        };
        if active.snapshot.connection_id != connection_id {
            return NativeSessionCommandResult::Stale;
        }

        let data = match command {
            NativeSessionCommand::DisableInput => {
                if !active.snapshot.active_capabilities.control_keyboard_mouse {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "keyboard".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableClipboard => {
                if !active.snapshot.active_capabilities.clipboard.any_enabled() {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableClipboardRead => {
                if !active
                    .snapshot
                    .active_capabilities
                    .clipboard
                    .allows_remote_read()
                {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-read".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableClipboardWrite => {
                if !active
                    .snapshot
                    .active_capabilities
                    .clipboard
                    .allows_remote_write()
                {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-write".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableAudio => {
                if !active.snapshot.active_capabilities.system_audio {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "audio".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::Disconnect => {
                if active.disconnect_requested {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::Close
            }
        };
        if active.command_sender.send(data).is_err() {
            return NativeSessionCommandResult::Unavailable;
        }
        if command == NativeSessionCommand::Disconnect {
            active.disconnect_requested = true;
        }
        NativeSessionCommandResult::Queued
    }

    fn end(&mut self, core_connection_id: i32) -> Option<NativeActiveSession> {
        let matches = self
            .active
            .as_ref()
            .map(|active| active.snapshot.core_connection_id == core_connection_id)
            .unwrap_or(false);
        matches.then(|| self.active.take()).flatten()
    }

    fn reset(&mut self) -> Option<NativeActiveSession> {
        self.active.take()
    }

    fn snapshot(&self) -> Option<NativeSessionSnapshot> {
        self.active.as_ref().map(|active| active.snapshot.clone())
    }
}

pub(crate) struct NativeMediaAccessUnit {
    pub(crate) codec: u32,
    pub(crate) framing: u32,
    pub(crate) pts_us: u64,
    pub(crate) keyframe: bool,
    pub(crate) has_parameter_sets: bool,
    pub(crate) data: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeMediaQueueDropReason {
    NetworkBackpressure,
    Shutdown,
}

#[derive(Default)]
struct NativeMediaQueueState {
    depth: usize,
    maximum_depth: usize,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaQueueSnapshot {
    current_depth: usize,
    maximum_depth: usize,
}

#[derive(Default)]
struct NativeMediaQueueTelemetry {
    state: Mutex<NativeMediaQueueState>,
}

impl NativeMediaQueueTelemetry {
    fn try_enqueue(
        &self,
        sender: &SyncSender<NativeMediaAccessUnit>,
        packet: NativeMediaAccessUnit,
    ) -> Result<(), (NativeMediaQueueDropReason, NativeMediaAccessUnit)> {
        // Hold the small counter lock across try_send so the receiver cannot
        // decrement before a successful enqueue has published its depth.
        let mut state = self.state.lock().unwrap();
        match sender.try_send(packet) {
            Ok(()) => {
                state.depth += 1;
                state.maximum_depth = state.maximum_depth.max(state.depth);
                Ok(())
            }
            Err(TrySendError::Full(packet)) => {
                Err((NativeMediaQueueDropReason::NetworkBackpressure, packet))
            }
            Err(TrySendError::Disconnected(packet)) => {
                Err((NativeMediaQueueDropReason::Shutdown, packet))
            }
        }
    }

    fn record_dequeued(&self) {
        let mut state = self.state.lock().unwrap();
        state.depth = state.depth.saturating_sub(1);
    }

    fn snapshot(&self) -> NativeMediaQueueSnapshot {
        let state = self.state.lock().unwrap();
        NativeMediaQueueSnapshot {
            current_depth: state.depth,
            maximum_depth: state.maximum_depth,
        }
    }
}

#[derive(Default)]
struct NativeMediaWriterState {
    cycles: u64,
    subscriber_dispatches: u64,
    dispatch_wall_total_us: u64,
    maximum_dispatch_wall_us: u64,
    confirmation_wait_total_us: u64,
    maximum_confirmation_wait_us: u64,
    completed_confirmations: u64,
    timed_out_confirmations: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaWriterSnapshot {
    cycles: u64,
    subscriber_dispatches: u64,
    dispatch_wall_total_us: u64,
    maximum_dispatch_wall_us: u64,
    confirmation_wait_total_us: u64,
    maximum_confirmation_wait_us: u64,
    completed_confirmations: u64,
    timed_out_confirmations: u64,
}

#[derive(Default)]
struct NativeMediaWriterTelemetry {
    state: Mutex<NativeMediaWriterState>,
}

impl NativeMediaWriterTelemetry {
    fn record(
        &self,
        subscriber_count: usize,
        dispatch_wall: Duration,
        confirmation_wait: Duration,
        confirmation_complete: bool,
    ) {
        if subscriber_count == 0 {
            return;
        }
        let dispatch_us = duration_microseconds(dispatch_wall);
        let confirmation_us = duration_microseconds(confirmation_wait);
        let mut state = self.state.lock().unwrap();
        state.cycles = state.cycles.saturating_add(1);
        state.subscriber_dispatches = state
            .subscriber_dispatches
            .saturating_add(subscriber_count.min(u64::MAX as usize) as u64);
        state.dispatch_wall_total_us = state.dispatch_wall_total_us.saturating_add(dispatch_us);
        state.maximum_dispatch_wall_us = state.maximum_dispatch_wall_us.max(dispatch_us);
        state.confirmation_wait_total_us = state
            .confirmation_wait_total_us
            .saturating_add(confirmation_us);
        state.maximum_confirmation_wait_us =
            state.maximum_confirmation_wait_us.max(confirmation_us);
        if confirmation_complete {
            state.completed_confirmations = state.completed_confirmations.saturating_add(1);
        } else {
            state.timed_out_confirmations = state.timed_out_confirmations.saturating_add(1);
        }
    }

    fn snapshot(&self) -> NativeMediaWriterSnapshot {
        let state = self.state.lock().unwrap();
        NativeMediaWriterSnapshot {
            cycles: state.cycles,
            subscriber_dispatches: state.subscriber_dispatches,
            dispatch_wall_total_us: state.dispatch_wall_total_us,
            maximum_dispatch_wall_us: state.maximum_dispatch_wall_us,
            confirmation_wait_total_us: state.confirmation_wait_total_us,
            maximum_confirmation_wait_us: state.maximum_confirmation_wait_us,
            completed_confirmations: state.completed_confirmations,
            timed_out_confirmations: state.timed_out_confirmations,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaNetworkSnapshot {
    subscriber_count: u64,
    qos_subscriber_count: u64,
    delay_sampled_subscribers: u64,
    rtt_sampled_subscribers: u64,
    response_delayed_subscribers: u64,
    worst_network_delay_ms: Option<u32>,
    worst_rtt_ms: Option<u32>,
}

#[derive(Default)]
struct NativeMediaNetworkTelemetry {
    latest: Mutex<NativeMediaNetworkSnapshot>,
}

impl NativeMediaNetworkTelemetry {
    fn record(
        &self,
        subscriber_count: usize,
        qos_subscriber_count: usize,
        delay_sampled_subscribers: usize,
        rtt_sampled_subscribers: usize,
        response_delayed_subscribers: usize,
        worst_network_delay_ms: Option<u32>,
        worst_rtt_ms: Option<u32>,
    ) -> bool {
        if qos_subscriber_count > subscriber_count
            || delay_sampled_subscribers > qos_subscriber_count
            || rtt_sampled_subscribers > delay_sampled_subscribers
            || response_delayed_subscribers > qos_subscriber_count
            || (delay_sampled_subscribers == 0) != worst_network_delay_ms.is_none()
            || (rtt_sampled_subscribers == 0) != worst_rtt_ms.is_none()
        {
            return false;
        }
        *self.latest.lock().unwrap() = NativeMediaNetworkSnapshot {
            subscriber_count: subscriber_count.min(u64::MAX as usize) as u64,
            qos_subscriber_count: qos_subscriber_count.min(u64::MAX as usize) as u64,
            delay_sampled_subscribers: delay_sampled_subscribers.min(u64::MAX as usize) as u64,
            rtt_sampled_subscribers: rtt_sampled_subscribers.min(u64::MAX as usize) as u64,
            response_delayed_subscribers: response_delayed_subscribers.min(u64::MAX as usize)
                as u64,
            worst_network_delay_ms,
            worst_rtt_ms,
        };
        true
    }

    fn snapshot(&self) -> NativeMediaNetworkSnapshot {
        *self.latest.lock().unwrap()
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaTransportSnapshot {
    subscriber_count: u64,
    direct_subscribers: u64,
    relay_subscribers: u64,
    unknown_subscribers: u64,
}

#[derive(Default)]
struct NativeMediaTransportTelemetry {
    latest: Mutex<NativeMediaTransportSnapshot>,
}

impl NativeMediaTransportTelemetry {
    fn record(
        &self,
        subscriber_count: usize,
        direct_subscribers: usize,
        relay_subscribers: usize,
        unknown_subscribers: usize,
    ) -> bool {
        let Some(classified_subscribers) = direct_subscribers.checked_add(relay_subscribers) else {
            return false;
        };
        let Some(all_subscribers) = classified_subscribers.checked_add(unknown_subscribers) else {
            return false;
        };
        if all_subscribers != subscriber_count {
            return false;
        }
        *self.latest.lock().unwrap() = NativeMediaTransportSnapshot {
            subscriber_count: subscriber_count.min(u64::MAX as usize) as u64,
            direct_subscribers: direct_subscribers.min(u64::MAX as usize) as u64,
            relay_subscribers: relay_subscribers.min(u64::MAX as usize) as u64,
            unknown_subscribers: unknown_subscribers.min(u64::MAX as usize) as u64,
        };
        true
    }

    fn snapshot(&self) -> NativeMediaTransportSnapshot {
        *self.latest.lock().unwrap()
    }
}

fn duration_microseconds(duration: Duration) -> u64 {
    duration.as_micros().min(u64::MAX as u128) as u64
}

fn try_enqueue_native_media(
    sender: &SyncSender<NativeMediaAccessUnit>,
    telemetry: &NativeMediaQueueTelemetry,
    packet: NativeMediaAccessUnit,
) -> Result<(), (NativeMediaQueueDropReason, NativeMediaAccessUnit)> {
    telemetry.try_enqueue(sender, packet)
}

#[derive(Clone, Copy)]
pub(crate) struct NativeMediaPacketMetadata {
    pub(crate) framing: u32,
    pub(crate) pts_us: u64,
    pub(crate) keyframe: bool,
    pub(crate) has_parameter_sets: bool,
}

impl NativeMediaAccessUnit {
    pub(crate) fn metadata(&self) -> NativeMediaPacketMetadata {
        NativeMediaPacketMetadata {
            framing: self.framing,
            pts_us: self.pts_us,
            keyframe: self.keyframe,
            has_parameter_sets: self.has_parameter_sets,
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) enum NativeMediaMilestone {
    FirstPacketDispatched,
    FirstPacketAcknowledged,
    RefreshKeyframeDispatched,
}

pub(crate) struct NativeMediaRoute {
    pub(crate) connection_epoch: u64,
    pub(crate) codec_epoch: u64,
    pub(crate) display_id: u64,
    pub(crate) display_revision: u64,
    pub(crate) codec: u32,
    pub(crate) receiver: Receiver<NativeMediaAccessUnit>,
    queue_telemetry: Arc<NativeMediaQueueTelemetry>,
    writer_telemetry: Arc<NativeMediaWriterTelemetry>,
    network_telemetry: Arc<NativeMediaNetworkTelemetry>,
    transport_telemetry: Arc<NativeMediaTransportTelemetry>,
}

static NEXT_CONNECTION_EPOCH: AtomicU64 = AtomicU64::new(1);
static NEXT_CODEC_EPOCH: AtomicU64 = AtomicU64::new(1);
static NEXT_DISPLAY_RECONFIGURE_GENERATION: AtomicU64 = AtomicU64::new(1);

lazy_static::lazy_static! {
    static ref MEDIA_BROKER: Mutex<MediaBroker> = Mutex::new(MediaBroker::default());
    static ref APPROVAL_BROKER: Mutex<NativeApprovalBroker> =
        Mutex::new(NativeApprovalBroker::default());
    static ref SESSION_BROKER: Mutex<NativeSessionBroker> =
        Mutex::new(NativeSessionBroker::default());
}

fn emit_bound_event(binding: &MediaHostBinding, event_type: &str, payload: Value) {
    let Some(callback) = binding.callback else {
        return;
    };
    let envelope = json!({
        "schemaVersion": EVENT_SCHEMA_VERSION,
        "eventId": binding.event_id.fetch_add(1, Ordering::Relaxed),
        "eventType": event_type,
        "hostInstanceId": binding.instance_id,
        "sentAt": now_unix_millis(),
        "payload": payload,
    });
    let Some(encoded) = serde_json::to_vec(&envelope).ok() else {
        return;
    };
    unsafe {
        callback(
            binding.context as *mut c_void,
            encoded.as_ptr() as *const c_char,
            encoded.len(),
        )
    };
}

fn bounded_remote_metadata(value: String) -> String {
    let mut result = String::new();
    for character in value.chars().filter(|character| !character.is_control()) {
        if result.len() + character.len_utf8() > MAX_REMOTE_METADATA_BYTES {
            break;
        }
        result.push(character);
    }
    result
}

fn emit_native_approval_completion(completion: &NativeApprovalCompletion) {
    let signal = match completion.status {
        NativeApprovalFinalStatus::Approved => Some(crate::ipc::Data::Authorize),
        NativeApprovalFinalStatus::Rejected | NativeApprovalFinalStatus::Expired => {
            Some(crate::ipc::Data::Close)
        }
        NativeApprovalFinalStatus::Cancelled => None,
    };
    if let Some(signal) = signal {
        let _ = completion.pending.decision_sender.send(signal);
    }
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "incomingConnectionResolved",
            json!({
                "connectionId": completion.pending.request.connection_id,
                "status": completion.status.as_str(),
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

fn expire_native_approval(connection_id: &str) {
    let completion = APPROVAL_BROKER
        .lock()
        .unwrap()
        .expire(connection_id, Instant::now());
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
}

pub(crate) fn native_host_begin_approval(
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    requested_capabilities: Vec<String>,
    decision_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
) -> NativeApprovalStartResult {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    let Some(binding) = binding else {
        return NativeApprovalStartResult::Unavailable;
    };
    let requested_at_ms = now_unix_millis();
    let connection_id = format!("{}:{core_connection_id}", binding.instance_id);
    let request = NativeApprovalRequest {
        connection_id: connection_id.clone(),
        core_connection_id,
        remote_id: bounded_remote_metadata(remote_id),
        remote_name: bounded_remote_metadata(remote_name),
        remote_platform: bounded_remote_metadata(remote_platform),
        requested_at_ms,
        expires_at_ms: requested_at_ms.saturating_add(NATIVE_APPROVAL_TIMEOUT_MS),
        requested_capabilities,
    };
    let result = APPROVAL_BROKER
        .lock()
        .unwrap()
        .begin(PendingNativeApproval {
            request: request.clone(),
            deadline: Instant::now() + Duration::from_millis(NATIVE_APPROVAL_TIMEOUT_MS),
            decision_sender: decision_sender.clone(),
        });
    match result {
        NativeApprovalStartResult::Accepted => {
            emit_bound_event(
                &binding,
                "incomingConnectionRequest",
                request.event_payload(),
            );
            emit_bound_event(&binding, "snapshotChanged", json!({}));
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(NATIVE_APPROVAL_TIMEOUT_MS)).await;
                expire_native_approval(&connection_id);
            });
        }
        NativeApprovalStartResult::Busy
        | NativeApprovalStartResult::Finalized
        | NativeApprovalStartResult::Unavailable => {
            let _ = decision_sender.send(crate::ipc::Data::Close);
        }
        NativeApprovalStartResult::Existing => {}
    }
    result
}

pub(crate) fn native_host_resolve_approval(
    connection_id: &str,
    decision: NativeApprovalDecision,
) -> NativeApprovalResolveResult {
    let (result, completion) =
        APPROVAL_BROKER
            .lock()
            .unwrap()
            .resolve(connection_id, decision, Instant::now());
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
    result
}

pub(crate) fn native_host_cancel_approval(core_connection_id: i32) {
    let completion = APPROVAL_BROKER.lock().unwrap().cancel(core_connection_id);
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
}

pub(crate) fn native_host_begin_session(
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    initial_capabilities: NativeSessionCapabilities,
    active_capabilities: NativeSessionCapabilities,
    input_availability: NativeSessionInputAvailability,
    command_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
) -> bool {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    let Some(binding) = binding else {
        return false;
    };
    let snapshot = NativeSessionSnapshot {
        connection_id: format!("{}:{core_connection_id}", binding.instance_id),
        core_connection_id,
        remote_id: bounded_remote_metadata(remote_id),
        remote_name: bounded_remote_metadata(remote_name),
        remote_platform: bounded_remote_metadata(remote_platform),
        started_at_ms: now_unix_millis(),
        initial_capabilities,
        active_capabilities,
        input_availability,
    };
    let result = SESSION_BROKER.lock().unwrap().begin(NativeActiveSession {
        snapshot: snapshot.clone(),
        command_sender,
        disconnect_requested: false,
    });
    match result {
        NativeSessionStartResult::Accepted => {
            emit_bound_event(&binding, "sessionStarted", snapshot.event_payload());
            emit_bound_event(&binding, "snapshotChanged", json!({}));
            true
        }
        NativeSessionStartResult::Existing => true,
        NativeSessionStartResult::Busy | NativeSessionStartResult::Invalid => false,
    }
}

pub(crate) fn native_host_update_session_capabilities(
    core_connection_id: i32,
    active_capabilities: NativeSessionCapabilities,
    input_availability: NativeSessionInputAvailability,
) {
    let snapshot = SESSION_BROKER.lock().unwrap().update_capabilities(
        core_connection_id,
        active_capabilities,
        input_availability,
    );
    let Some(snapshot) = snapshot else { return };
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionCapabilitiesChanged",
            json!({
                "connectionId": snapshot.connection_id,
                "activeCapabilities": snapshot.active_capabilities.names(),
                "inputAvailability": snapshot.input_availability.name(),
                "inputUnavailableReason": snapshot.input_availability.reason(),
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

pub(crate) fn native_host_end_session(core_connection_id: i32) {
    let ended = SESSION_BROKER.lock().unwrap().end(core_connection_id);
    let Some(ended) = ended else { return };
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionEnded",
            json!({
                "connectionId": ended.snapshot.connection_id,
                "reason": "connectionClosed",
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

fn native_host_pending_approval_snapshot(host_instance_id: &str) -> Option<Value> {
    let (request, completion) = APPROVAL_BROKER.lock().unwrap().snapshot(Instant::now());
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
    let request = request?;
    let expected_prefix = format!("{host_instance_id}:");
    request
        .connection_id
        .starts_with(&expected_prefix)
        .then(|| request.event_payload())
}

fn native_host_active_session_snapshot(host_instance_id: &str) -> Option<Value> {
    let snapshot = SESSION_BROKER.lock().unwrap().snapshot()?;
    let expected_prefix = format!("{host_instance_id}:");
    snapshot
        .connection_id
        .starts_with(&expected_prefix)
        .then(|| snapshot.event_payload())
}

fn reset_native_approval_broker() {
    let pending = APPROVAL_BROKER.lock().unwrap().reset();
    if let Some(pending) = pending {
        let _ = pending.decision_sender.send(crate::ipc::Data::Close);
    }
}

fn reset_native_session_broker(reason: &str) {
    let active = SESSION_BROKER.lock().unwrap().reset();
    let Some(active) = active else { return };
    let _ = active.command_sender.send(crate::ipc::Data::Close);
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionEnded",
            json!({
                "connectionId": active.snapshot.connection_id,
                "reason": reason,
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

fn bind_media_host(host: &RdnHost) {
    reset_native_approval_broker();
    reset_native_session_broker("hostRebound");
    // `CGDisplayPixelsWide/High` already return pixel units. The upstream
    // Retina path multiplies those values by `NSScreen.backingScaleFactor`,
    // which can turn a 3840x2160 scaled mode into a synthetic 7680x4320
    // display. That disagrees with the Swift hardware-capability envelope and
    // makes the native route fail closed after a live resolution change.
    // Native Host capture therefore pins one physical-pixel authority for the
    // display catalog, ScreenCaptureKit configuration, and encoder contract.
    #[cfg(target_os = "macos")]
    {
        *scrap::quartz::ENABLE_RETINA.lock().unwrap() = false;
    }
    let mut broker = MEDIA_BROKER.lock().unwrap();
    broker.routes.clear();
    broker.display_revisions.clear();
    broker.pending_display_reconfigures.clear();
    broker.capabilities = MediaCapabilities::default();
    broker.clipboard_transfer_policy = host.clipboard_transfer_policy;
    #[cfg(target_os = "macos")]
    {
        broker.file_service_owner = host.file_service_owner.clone();
    }
    broker.binding = Some(MediaHostBinding {
        instance_id: host.instance_id.clone(),
        callback: host.callbacks.on_event,
        context: host.callbacks.context as usize,
        event_id: host.event_id.clone(),
    });
    scrap::codec::set_native_encoding_capabilities(false, false);
}

/// The native FarPane Host owns connection status inside the main App and has
/// no separate RustDesk connection-manager process. Server connections use
/// this signal to avoid spawning the current executable with `--cm`.
pub(crate) fn native_host_is_bound() -> bool {
    MEDIA_BROKER.lock().unwrap().binding.is_some()
}

/// Process-lifetime connection-manager ownership is established by the
/// successful config-root-first Host entry and never falls back during
/// start failure, media unbind, stop-drain, destroy, or a later Host restart.
pub(crate) fn native_host_owns_connection_manager() -> bool {
    CONFIG_ROOT_SET.load(Ordering::Acquire)
}

/// Stable for the full native Host instance lifetime, including the interval
/// where stop has unbound media but server connections are still draining.
pub(crate) fn native_host_instance_is_live() -> bool {
    HOST_INSTANCE_LIVE.load(Ordering::Acquire)
}

fn unbind_media_host() {
    reset_native_approval_broker();
    reset_native_session_broker("hostStopped");
    let (binding, routes) = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let binding = broker.binding.take();
        let routes = broker
            .routes
            .drain()
            .map(|(display, route)| {
                (
                    display,
                    route.connection_epoch,
                    route.codec_epoch,
                    route.display_revision,
                    route.queue_telemetry.snapshot(),
                    route.writer_telemetry.snapshot(),
                    route.network_telemetry.snapshot(),
                    route.transport_telemetry.snapshot(),
                )
            })
            .collect::<Vec<_>>();
        broker.display_revisions.clear();
        broker.pending_display_reconfigures.clear();
        broker.capabilities = MediaCapabilities::default();
        broker.clipboard_transfer_policy = NativeClipboardTransferPolicy::default();
        #[cfg(target_os = "macos")]
        {
            broker.file_service_owner = None;
        }
        (binding, routes)
    };
    scrap::codec::set_native_encoding_capabilities(false, false);
    if let Some(binding) = binding {
        for (
            display_id,
            connection_epoch,
            codec_epoch,
            display_revision,
            queue,
            writer,
            network,
            transport,
        ) in routes
        {
            emit_bound_event(
                &binding,
                "mediaQueueDiagnostic",
                native_media_queue_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    queue,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaWriterDiagnostic",
                native_media_writer_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    writer,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaNetworkDiagnostic",
                native_media_network_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    network,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaTransportDiagnostic",
                native_media_transport_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    transport,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaControl",
                json!({
                    "command": "stopCapture",
                    "connectionEpoch": connection_epoch,
                    "codecEpoch": codec_epoch,
                    "displayId": display_id,
                }),
            );
        }
    }
    #[cfg(target_os = "macos")]
    {
        *scrap::quartz::ENABLE_RETINA.lock().unwrap() = true;
    }
}

pub(crate) fn native_media_begin_route(
    display_id: u64,
    codec: u32,
    width: u32,
    height: u32,
    fps: u32,
    bitrate: u32,
) -> Result<NativeMediaRoute, &'static str> {
    let (sender, receiver) = sync_channel(MEDIA_QUEUE_CAPACITY);
    let queue_telemetry = Arc::new(NativeMediaQueueTelemetry::default());
    let writer_telemetry = Arc::new(NativeMediaWriterTelemetry::default());
    let network_telemetry = Arc::new(NativeMediaNetworkTelemetry::default());
    let transport_telemetry = Arc::new(NativeMediaTransportTelemetry::default());
    let connection_epoch = next_native_media_epoch(&NEXT_CONNECTION_EPOCH)
        .ok_or("native media connection epoch is exhausted")?;
    let codec_epoch = next_native_media_epoch(&NEXT_CODEC_EPOCH)
        .ok_or("native media codec epoch is exhausted")?;
    let (binding, display_revision, display_reconfigure) = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let binding = broker
            .binding
            .clone()
            .ok_or("native host media is not bound")?;
        let capable = match codec {
            MEDIA_CODEC_H264 => broker.capabilities.h264_hardware,
            MEDIA_CODEC_H265 => broker.capabilities.h265_hardware,
            _ => false,
        };
        if !capable {
            return Err("negotiated codec is not available from native adapter");
        }
        if width == 0
            || height == 0
            || fps == 0
            || width > broker.capabilities.max_width
            || height > broker.capabilities.max_height
            || fps > broker.capabilities.max_fps
        {
            return Err("display requirements exceed native adapter capabilities");
        }
        let display_reconfigure = broker.pending_display_reconfigures.remove(&display_id);
        let display_revision = match display_reconfigure {
            Some(provenance) => provenance
                .previous_display_revision
                .checked_add(1)
                .ok_or("native media display revision is exhausted")?,
            None => broker
                .display_revisions
                .get(&display_id)
                .copied()
                .unwrap_or(1),
        };
        broker
            .display_revisions
            .insert(display_id, display_revision);
        broker.routes.insert(
            display_id,
            MediaRoute {
                connection_epoch,
                codec_epoch,
                display_revision,
                codec,
                sender,
                queue_telemetry: queue_telemetry.clone(),
                writer_telemetry: writer_telemetry.clone(),
                network_telemetry: network_telemetry.clone(),
                transport_telemetry: transport_telemetry.clone(),
                last_pts_us: None,
                needs_parameter_sets: true,
            },
        );
        (binding, display_revision, display_reconfigure)
    };
    let codec_name = if codec == MEDIA_CODEC_H264 {
        "h264"
    } else {
        "h265"
    };
    let mut start_payload = json!({
        "command": "startCapture",
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
    });
    let mut reconfigure_payload = json!({
        "command": "reconfigure",
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "codec": codec_name,
        "width": width,
        "height": height,
        "fps": fps,
        "bitrate": bitrate,
    });
    if let Some(provenance) = display_reconfigure {
        start_payload["displayReconfigure"] = provenance.payload();
        reconfigure_payload["displayReconfigure"] = provenance.payload();
    }
    emit_bound_event(&binding, "mediaControl", start_payload);
    emit_bound_event(&binding, "mediaControl", reconfigure_payload);
    Ok(NativeMediaRoute {
        connection_epoch,
        codec_epoch,
        display_id,
        display_revision,
        codec,
        receiver,
        queue_telemetry,
        writer_telemetry,
        network_telemetry,
        transport_telemetry,
    })
}

/// Marks only the exact active monitor route whose pinned display inventory
/// comparison observed a change. The next replacement route consumes this
/// marker; codec/subscriber/service retries never synthesize one.
pub(crate) fn native_media_mark_display_reconfigure(
    route: &NativeMediaRoute,
) -> Result<(), &'static str> {
    let (binding, provenance) = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let current = broker
            .routes
            .get(&route.display_id)
            .ok_or("native media display route is unavailable")?;
        if current.connection_epoch != route.connection_epoch
            || current.codec_epoch != route.codec_epoch
            || current.display_revision != route.display_revision
        {
            return Err("native media display route is stale");
        }
        if route.display_revision == u64::MAX
            || broker
                .pending_display_reconfigures
                .contains_key(&route.display_id)
        {
            return Err("native media display reconfigure is unavailable");
        }
        let generation = next_native_media_epoch(&NEXT_DISPLAY_RECONFIGURE_GENERATION)
            .ok_or("native display reconfigure generation is exhausted")?;
        let binding = broker
            .binding
            .clone()
            .ok_or("native host media is not bound")?;
        let provenance = NativeDisplayReconfigureProvenance {
            generation,
            previous_display_revision: route.display_revision,
            previous_connection_epoch: route.connection_epoch,
            previous_codec_epoch: route.codec_epoch,
        };
        broker
            .pending_display_reconfigures
            .insert(route.display_id, provenance);
        (binding, provenance)
    };
    emit_bound_event(
        &binding,
        "mediaDisplayReconfigureStarted",
        json!({
            "displayReconfigureGeneration": provenance.generation,
            "displayId": route.display_id,
            "previousDisplayRevision": provenance.previous_display_revision,
            "previousConnectionEpoch": provenance.previous_connection_epoch,
            "previousCodecEpoch": provenance.previous_codec_epoch,
        }),
    );
    Ok(())
}

fn next_native_media_epoch(counter: &AtomicU64) -> Option<u64> {
    counter
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
            current.checked_add(1)
        })
        .ok()
}

pub(crate) fn native_media_record_dequeued(route: &NativeMediaRoute) {
    route.queue_telemetry.record_dequeued();
}

pub(crate) fn native_media_report_queue_depth(route: &NativeMediaRoute) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaQueueDiagnostic",
            native_media_queue_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.queue_telemetry.snapshot(),
            ),
        );
    }
}

pub(crate) fn native_media_record_writer_cycle(
    route: &NativeMediaRoute,
    subscriber_count: usize,
    dispatch_wall: Duration,
    confirmation_wait: Duration,
    confirmation_complete: bool,
) {
    route.writer_telemetry.record(
        subscriber_count,
        dispatch_wall,
        confirmation_wait,
        confirmation_complete,
    );
}

pub(crate) fn native_media_report_writer_timing(route: &NativeMediaRoute) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaWriterDiagnostic",
            native_media_writer_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.writer_telemetry.snapshot(),
            ),
        );
    }
}

pub(crate) fn native_media_report_network(
    route: &NativeMediaRoute,
    subscriber_count: usize,
    qos_subscriber_count: usize,
    delay_sampled_subscribers: usize,
    rtt_sampled_subscribers: usize,
    response_delayed_subscribers: usize,
    worst_network_delay_ms: Option<u32>,
    worst_rtt_ms: Option<u32>,
) {
    if !route.network_telemetry.record(
        subscriber_count,
        qos_subscriber_count,
        delay_sampled_subscribers,
        rtt_sampled_subscribers,
        response_delayed_subscribers,
        worst_network_delay_ms,
        worst_rtt_ms,
    ) {
        return;
    }
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaNetworkDiagnostic",
            native_media_network_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.network_telemetry.snapshot(),
            ),
        );
    }
}

pub(crate) fn native_media_report_transport(
    route: &NativeMediaRoute,
    subscriber_count: usize,
    direct_subscribers: usize,
    relay_subscribers: usize,
    unknown_subscribers: usize,
) {
    if !route.transport_telemetry.record(
        subscriber_count,
        direct_subscribers,
        relay_subscribers,
        unknown_subscribers,
    ) {
        return;
    }
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaTransportDiagnostic",
            native_media_transport_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.transport_telemetry.snapshot(),
            ),
        );
    }
}

fn native_media_queue_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    queue: NativeMediaQueueSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "currentDepth": queue.current_depth,
        "maximumDepth": queue.maximum_depth,
        "capacity": MEDIA_QUEUE_CAPACITY,
    })
}

fn native_media_writer_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    writer: NativeMediaWriterSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "cycles": writer.cycles,
        "subscriberDispatches": writer.subscriber_dispatches,
        "dispatchWallTotalUs": writer.dispatch_wall_total_us,
        "maximumDispatchWallUs": writer.maximum_dispatch_wall_us,
        "confirmationWaitTotalUs": writer.confirmation_wait_total_us,
        "maximumConfirmationWaitUs": writer.maximum_confirmation_wait_us,
        "completedConfirmations": writer.completed_confirmations,
        "timedOutConfirmations": writer.timed_out_confirmations,
    })
}

fn native_media_network_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    network: NativeMediaNetworkSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "subscriberCount": network.subscriber_count,
        "qosSubscriberCount": network.qos_subscriber_count,
        "delaySampledSubscribers": network.delay_sampled_subscribers,
        "rttSampledSubscribers": network.rtt_sampled_subscribers,
        "responseDelayedSubscribers": network.response_delayed_subscribers,
        "worstNetworkDelayMs": network.worst_network_delay_ms,
        "worstRttMs": network.worst_rtt_ms,
    })
}

fn native_media_transport_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    transport: NativeMediaTransportSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "subscriberCount": transport.subscriber_count,
        "directSubscribers": transport.direct_subscribers,
        "relaySubscribers": transport.relay_subscribers,
        "unknownSubscribers": transport.unknown_subscribers,
    })
}

pub(crate) fn native_media_request_idr(route: &NativeMediaRoute, reason: &str) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaControl",
            json!({
                "command": "requestIdr",
                "connectionEpoch": route.connection_epoch,
                "codecEpoch": route.codec_epoch,
                "displayId": route.display_id,
                "displayRevision": route.display_revision,
                "reason": reason,
            }),
        );
    }
}

pub(crate) fn native_media_report_milestone(
    route: &NativeMediaRoute,
    milestone: NativeMediaMilestone,
    packet: NativeMediaPacketMetadata,
    subscriber_count: usize,
) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    let Some(binding) = binding else { return };
    let Some(payload) = native_media_milestone_payload(route, milestone, packet, subscriber_count)
    else {
        return;
    };
    emit_bound_event(&binding, "mediaDiagnostic", payload);
}

fn native_media_milestone_payload(
    route: &NativeMediaRoute,
    milestone: NativeMediaMilestone,
    packet: NativeMediaPacketMetadata,
    subscriber_count: usize,
) -> Option<Value> {
    if subscriber_count == 0 {
        return None;
    }
    let kind = match milestone {
        NativeMediaMilestone::FirstPacketDispatched => "firstPacketDispatched",
        NativeMediaMilestone::FirstPacketAcknowledged => "firstPacketAcknowledged",
        NativeMediaMilestone::RefreshKeyframeDispatched => "refreshKeyframeDispatched",
    };
    let codec = match route.codec {
        MEDIA_CODEC_H264 => "h264",
        MEDIA_CODEC_H265 => "h265",
        _ => return None,
    };
    let framing = match packet.framing {
        MEDIA_FRAMING_ANNEX_B => "annexB",
        MEDIA_FRAMING_AVCC => "avcc",
        _ => return None,
    };
    Some(json!({
        "kind": kind,
        "connectionEpoch": route.connection_epoch,
        "codecEpoch": route.codec_epoch,
        "displayId": route.display_id,
        "displayRevision": route.display_revision,
        "codec": codec,
        "framing": framing,
        "ptsUs": packet.pts_us,
        "keyframe": packet.keyframe,
        "hasParameterSets": packet.has_parameter_sets,
        "subscriberCount": subscriber_count,
    }))
}

pub(crate) fn native_media_end_route(route: &NativeMediaRoute) {
    let binding = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let matches = broker
            .routes
            .get(&route.display_id)
            .map(|current| {
                current.connection_epoch == route.connection_epoch
                    && current.codec_epoch == route.codec_epoch
            })
            .unwrap_or(false);
        if matches {
            broker.routes.remove(&route.display_id);
            broker.binding.clone()
        } else {
            None
        }
    };
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaQueueDiagnostic",
            native_media_queue_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.queue_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaWriterDiagnostic",
            native_media_writer_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.writer_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaNetworkDiagnostic",
            native_media_network_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.network_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaTransportDiagnostic",
            native_media_transport_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.transport_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaControl",
            json!({
                "command": "stopCapture",
                "connectionEpoch": route.connection_epoch,
                "codecEpoch": route.codec_epoch,
                "displayId": route.display_id,
            }),
        );
    }
}

impl Drop for RuntimeFinished {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

async fn wait_for_host_runtime_retry(stop_requested: &AtomicBool, delay: Duration) -> bool {
    let deadline = Instant::now() + delay;
    loop {
        if stop_requested.load(Ordering::Acquire) {
            return false;
        }
        let now = Instant::now();
        if now >= deadline {
            return true;
        }
        hbb_common::tokio::time::sleep(
            deadline
                .saturating_duration_since(now)
                .min(Duration::from_millis(HOST_RUNTIME_RECONNECT_STOP_POLL_MS)),
        )
        .await;
    }
}

async fn wait_for_host_runtime_registration_watchdog(
    stop_requested: &AtomicBool,
) -> HostRuntimeRegistrationWatchdogOutcome {
    let mut watchdog = HostRuntimeRegistrationWatchdog::default();
    loop {
        if stop_requested.load(Ordering::Acquire) {
            return HostRuntimeRegistrationWatchdogOutcome::StopRequested;
        }
        let registration_healthy =
            config::Config::get_key_confirmed() && config::get_online_state() > 0;
        if watchdog.should_restart(Instant::now(), registration_healthy) {
            return HostRuntimeRegistrationWatchdogOutcome::RegistrationStalled;
        }
        hbb_common::tokio::time::sleep(Duration::from_millis(HOST_RUNTIME_RECONNECT_STOP_POLL_MS))
            .await;
    }
}

impl HostRuntime {
    fn start(rendezvous_server: String) -> Result<Self, ()> {
        let stop_requested = Arc::new(AtomicBool::new(false));
        let finished = Arc::new(AtomicBool::new(false));
        let thread_stop = stop_requested.clone();
        let thread_finished = finished.clone();
        let thread = std::thread::Builder::new()
            .name("farpane-host-rendezvous".to_owned())
            .spawn(move || {
                let _finished = RuntimeFinished(thread_finished);
                let Ok(runtime) = hbb_common::tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                else {
                    return;
                };
                runtime.block_on(async move {
                    let server = crate::server::new();
                    let mut reconnect_backoff = HostRuntimeReconnectBackoff::default();
                    while !thread_stop.load(Ordering::Acquire) {
                        crate::RendezvousMediator::prepare_native_host_runtime();
                        let connection_started = Instant::now();
                        let rendezvous = crate::RendezvousMediator::start(
                            server.clone(),
                            rendezvous_server.clone(),
                        );
                        hbb_common::tokio::pin!(rendezvous);
                        let watchdog_outcome = hbb_common::tokio::select! {
                            _ = &mut rendezvous => None,
                            outcome = wait_for_host_runtime_registration_watchdog(&thread_stop) => {
                                Some(outcome)
                            }
                        };
                        if watchdog_outcome
                            == Some(HostRuntimeRegistrationWatchdogOutcome::StopRequested)
                            || thread_stop.load(Ordering::Acquire)
                        {
                            break;
                        }
                        config::Config::reset_online();
                        let retry_delay = reconnect_backoff.delay_after_exit(
                            connection_started.elapsed(),
                            u64::from(hbb_common::time_based_rand()),
                        );
                        if !wait_for_host_runtime_retry(&thread_stop, retry_delay).await {
                            break;
                        }
                    }
                });
            })
            .map_err(|_| ())?;
        Ok(Self {
            stop_requested,
            finished,
            thread: Some(thread),
        })
    }

    fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    fn request_stop(&self) {
        self.stop_requested.store(true, Ordering::Release);
        crate::RendezvousMediator::stop_native_host_runtime();
    }

    fn join(&mut self) -> bool {
        let joined = self
            .thread
            .take()
            .map(|thread| thread.join().is_ok())
            .unwrap_or(true);
        config::Config::reset_online();
        joined
    }

    fn stop(&mut self) -> bool {
        self.request_stop();
        self.join()
    }
}

impl RdnHost {
    fn refresh_registration_state(&mut self) {
        match self.recovery_state {
            HostRecoveryState::Suspending => {
                self.registration_status = "suspending";
                return;
            }
            HostRecoveryState::Suspended => {
                self.registration_status = "suspended";
                return;
            }
            HostRecoveryState::Failed => return,
            HostRecoveryState::Running | HostRecoveryState::Resuming => {}
        }
        if !matches!(self.state, RdnHostState::Starting | RdnHostState::Ready) {
            return;
        }
        if config::Config::get_key_confirmed() && config::get_online_state() > 0 {
            self.registration_status = "ready";
            self.state = RdnHostState::Ready;
            self.recovery_state = HostRecoveryState::Running;
            self.last_error = None;
        } else if self
            .runtime
            .as_ref()
            .map(HostRuntime::is_finished)
            .unwrap_or(true)
        {
            self.registration_status = "degraded";
            self.state = RdnHostState::Error;
            if self.recovery_state == HostRecoveryState::Resuming {
                self.recovery_state = HostRecoveryState::Failed;
            }
            self.last_error = Some("registration.runtimeExited".to_owned());
        } else {
            self.registration_status = "pending";
            self.state = RdnHostState::Starting;
        }
    }

    fn emit_event(&self, event_type: &str, payload: Value) {
        emit_bound_event(
            &MediaHostBinding {
                instance_id: self.instance_id.clone(),
                callback: self.callbacks.on_event,
                context: self.callbacks.context as usize,
                event_id: self.event_id.clone(),
            },
            event_type,
            payload,
        );
    }

    fn emit_snapshot_changed(&self) {
        self.emit_event("snapshotChanged", json!({}));
    }

    fn emit_command_result(&self, command_id: &str, status: &str, detail: &str) {
        self.emit_event(
            "commandResult",
            json!({
                "commandId": command_id,
                "status": status,
                "detail": detail,
            }),
        );
    }

    fn snapshot_json(&mut self) -> Value {
        self.refresh_registration_state();
        let (session_availability, session_unavailable_reason) =
            native_host_session_availability_payload(native_host_session_is_available());
        // §8.3 minimal field set; §9.2: password only leaves Rust when the UI
        // explicitly revealed it, and the reveal flag is one-shot.
        let presentation = if self.reveal_temporary_password {
            self.reveal_temporary_password = false;
            json!({ "policy": "revealed", "value": password_security::temporary_password() })
        } else {
            json!({ "policy": "redacted" })
        };
        let mut map = Map::new();
        map.insert("schemaVersion".into(), json!(SNAPSHOT_SCHEMA_VERSION));
        map.insert("hostInstanceId".into(), json!(self.instance_id));
        map.insert("hostState".into(), json!(state_name(self.state)));
        map.insert("localId".into(), json!(self.local_id));
        map.insert(
            "authenticatedConnectionCount".into(),
            json!(crate::server::native_host_authenticated_connection_count()),
        );
        map.insert("sessionAvailability".into(), json!(session_availability));
        map.insert(
            "sessionUnavailableReason".into(),
            json!(session_unavailable_reason),
        );
        map.insert(
            "pendingApproval".into(),
            native_host_pending_approval_snapshot(&self.instance_id).unwrap_or(Value::Null),
        );
        map.insert(
            "activeSession".into(),
            native_host_active_session_snapshot(&self.instance_id).unwrap_or(Value::Null),
        );
        map.insert("temporaryPasswordPresentation".into(), presentation);
        map.insert(
            "passwordPolicy".into(),
            json!({
                "localPasswordSet": config::Config::has_local_permanent_password(),
                "effectivePasswordSet": config::Config::has_permanent_password(),
                "usingPresetPassword": config::Config::is_using_preset_password(),
                "changeAllowed": !config::Config::is_disable_change_permanent_password(),
                "strengthPolicy": {
                    "version": PERMANENT_PASSWORD_POLICY_VERSION,
                    "minimumCharacters": PERMANENT_PASSWORD_MIN_CHARACTERS,
                    "maximumCharacters": PERMANENT_PASSWORD_MAX_CHARACTERS,
                    "maximumUtf8Bytes": PERMANENT_PASSWORD_MAX_UTF8_BYTES,
                    "rejectsControlCharacters": true,
                    "rejectsOuterWhitespace": true,
                },
            }),
        );
        map.insert("registrationStatus".into(), json!(self.registration_status));
        map.insert("recoveryEpoch".into(), json!(self.recovery_epoch));
        map.insert("recoveryStatus".into(), json!(self.recovery_state.name()));
        map.insert(
            "lastError".into(),
            match &self.last_error {
                Some(error) => json!(error),
                None => Value::Null,
            },
        );
        map.insert("observedAt".into(), json!(now_unix_millis()));
        Value::Object(map)
    }
}

fn now_unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}

/// CSPRNG hex token for the host instance identity (not a secret credential).
fn random_instance_id() -> String {
    let mut bytes = [0u8; 8];
    if let Ok(mut file) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        if file.read_exact(&mut bytes).is_err() {
            bytes = now_unix_millis().to_ne_bytes();
        }
    } else {
        bytes = now_unix_millis().to_ne_bytes();
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

unsafe fn required_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        return Err(RDN_HOST_ERR_INVALID_ARG);
    }
    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| RDN_HOST_ERR_VALIDATION)
}

unsafe fn optional_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        return Ok(String::new());
    }
    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| RDN_HOST_ERR_VALIDATION)
}

fn valid_server(value: &str, allow_empty: bool) -> bool {
    (allow_empty || !value.is_empty())
        && value.len() <= MAX_SERVER_BYTES
        && !value.chars().any(|character| {
            character.is_control()
                || character.is_whitespace()
                || matches!(character, '@' | '?' | '#' | '&')
        })
}

fn valid_server_public_key(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_SERVER_PUBLIC_KEY_BYTES
        && crate::decode64(value)
            .map(|decoded| decoded.len() == 32)
            .unwrap_or(false)
}

fn valid_namespace_component(value: &str) -> bool {
    // APP_NAME/ORG flow into directory names, toml names and the IPC socket
    // path; keep them conservative so isolation cannot escape the sandbox.
    !value.is_empty()
        && value.len() <= MAX_NAME_BYTES
        && !value.contains(|component| matches!(component, '/' | '\\' | ':' | '\0'))
        && value != "."
        && value != ".."
}

#[no_mangle]
pub extern "C" fn rdn_host_abi_version() -> u32 {
    HOST_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn rdn_host_upstream_commit() -> *const c_char {
    UPSTREAM_COMMIT.as_ptr() as *const c_char
}

/// Early config-root entry (host-mode-h0.md §2.3 conclusion 2): must be the
/// first host ABI call in the process, before any hbb_common Config access,
/// and runs exactly once. Switching APP_NAME/ORG moves the config directory,
/// toml file names, log directory and IPC socket (§3.5 of the H0 report).
#[no_mangle]
pub unsafe extern "C" fn rdn_host_set_config_root(
    app_name: *const c_char,
    org: *const c_char,
) -> i32 {
    if CONFIG_ROOT_SET.load(Ordering::Acquire) || HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    let app_name = match required_string(app_name) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let org = match required_string(org) {
        Ok(value) => value,
        Err(code) => return code,
    };
    if !valid_namespace_component(&app_name) || !valid_namespace_component(&org) {
        return RDN_HOST_ERR_VALIDATION;
    }
    *config::APP_NAME.write().unwrap() = app_name;
    #[cfg(target_os = "macos")]
    {
        *config::ORG.write().unwrap() = org;
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = org;
    }
    CONFIG_ROOT_SET.store(true, Ordering::Release);
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_create(
    options: *const RdnHostCreateOptions,
    callbacks: *const RdnHostCallbacks,
    out_host: *mut *mut RdnHost,
) -> i32 {
    if options.is_null() || callbacks.is_null() || out_host.is_null() {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    if (*options).abi_version != HOST_ABI_VERSION || (*callbacks).abi_version != HOST_ABI_VERSION {
        return RDN_HOST_ERR_ABI_MISMATCH;
    }
    if !CONFIG_ROOT_SET.load(Ordering::Acquire) {
        // Fail closed: creating a host before the config-root switch would
        // touch the shared RustDesk config namespace (§18 rule 6).
        return RDN_HOST_ERR_BAD_STATE;
    }
    let rendezvous_server = match required_string((*options).rendezvous_server) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let relay_server = match optional_string((*options).relay_server) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let server_public_key = match required_string((*options).server_public_key) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let audio_input_device = match optional_string((*options).audio_input_device) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let file_transfer_receive_root = match optional_string((*options).file_transfer_receive_root) {
        Ok(value) => value,
        Err(code) => return code,
    };
    if !valid_server(&rendezvous_server, false)
        || !valid_server(&relay_server, true)
        || !valid_server_public_key(&server_public_key)
        || !valid_native_host_audio_input_device(
            (*options).enable_audio,
            &audio_input_device,
        )
        || (*options).enable_file_transfer != !file_transfer_receive_root.is_empty()
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    if HOST_INSTANCE_LIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return RDN_HOST_ERR_BAD_STATE;
    }
    #[cfg(target_os = "macos")]
    let file_service_owner =
        match rdn_host_file_transfer::NativeHostFileServiceOwner::from_immutable_configuration(
            (*options).enable_file_transfer,
            (!file_transfer_receive_root.is_empty())
                .then(|| std::path::Path::new(&file_transfer_receive_root)),
        ) {
            Ok(owner) => owner.map(Arc::new),
            Err(error) => {
                HOST_INSTANCE_LIVE.store(false, Ordering::Release);
                let code = if error
                    == rdn_host_file_transfer::NativeFileTransferRootError::InvalidOwnerConfiguration
                {
                    RDN_HOST_ERR_VALIDATION
                } else {
                    RDN_HOST_ERR_STORAGE
                };
                return code;
            }
        };
    #[cfg(not(target_os = "macos"))]
    if (*options).enable_file_transfer {
        HOST_INSTANCE_LIVE.store(false, Ordering::Release);
        return RDN_HOST_ERR_NOT_SUPPORTED;
    }
    let host = Box::new(RdnHost {
        instance_id: random_instance_id(),
        state: RdnHostState::Created,
        local_id: String::new(),
        registration_status: "notStarted",
        recovery_epoch: 0,
        recovery_state: HostRecoveryState::Running,
        network_path_generation: 0,
        reveal_temporary_password: false,
        last_error: None,
        event_id: Arc::new(AtomicU64::new(0)),
        callbacks: *callbacks,
        rendezvous_server,
        relay_server,
        server_public_key,
        clipboard_transfer_policy: NativeClipboardTransferPolicy::with_image_policy(
            NativeClipboardPolicy::new(
                (*options).enable_clipboard_read,
                (*options).enable_clipboard_write,
            ),
            NativeClipboardPolicy::new(
                (*options).enable_clipboard_rich_text_read,
                (*options).enable_clipboard_rich_text_write,
            ),
            NativeClipboardPolicy::new(
                (*options).enable_clipboard_image_read,
                (*options).enable_clipboard_image_write,
            ),
        ),
        audio_enabled: (*options).enable_audio,
        audio_input_device,
        file_transfer_enabled: (*options).enable_file_transfer,
        #[cfg(target_os = "macos")]
        file_service_owner,
        runtime: None,
    });
    *out_host = Box::into_raw(host);
    RDN_HOST_OK
}

#[derive(Debug, PartialEq, Eq)]
enum HostStoragePreflightError {
    InvalidPath,
    #[cfg(not(unix))]
    UnsupportedPlatform,
    OpenDirectory,
    UnsafeDirectory,
    OpenFile,
    UnsafeFile,
    ReadFile,
    InvalidUtf8,
    InvalidToml,
    PersistenceMismatch,
}

#[derive(Clone, Copy)]
enum HostStorageDocument {
    Identity,
    Options,
}

enum HostStorageSnapshot {
    Identity {
        encrypted_id_present: bool,
        password_matches: Option<bool>,
    },
    Options(HashMap<String, String>),
}

#[derive(Default, serde_derive::Deserialize)]
#[serde(deny_unknown_fields)]
struct HostIdentityPersistenceProjection {
    #[serde(default)]
    id: String,
    #[serde(default)]
    enc_id: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    salt: String,
    #[serde(default)]
    key_pair: (Vec<u8>, Vec<u8>),
    #[serde(default)]
    key_confirmed: bool,
    #[serde(default)]
    keys_confirmed: HashMap<String, bool>,
}

impl Drop for HostIdentityPersistenceProjection {
    fn drop(&mut self) {
        wipe_host_storage_string(&mut self.id);
        wipe_host_storage_string(&mut self.enc_id);
        wipe_host_storage_string(&mut self.password);
        wipe_host_storage_string(&mut self.salt);
        password_security::memzero_secret(&mut self.key_pair.0);
        password_security::memzero_secret(&mut self.key_pair.1);
        for (mut key, _) in self.keys_confirmed.drain() {
            wipe_host_storage_string(&mut key);
        }
        self.key_confirmed = false;
    }
}

struct WipedHostStorageBytes(Vec<u8>);

impl WipedHostStorageBytes {
    fn new(capacity: usize) -> Self {
        Self(Vec::with_capacity(capacity))
    }

    fn bytes(&self) -> &[u8] {
        &self.0
    }
}

impl Drop for WipedHostStorageBytes {
    fn drop(&mut self) {
        password_security::memzero_secret(&mut self.0);
    }
}

struct WipedHostStorageString(String);

impl Drop for WipedHostStorageString {
    fn drop(&mut self) {
        wipe_host_storage_string(&mut self.0);
    }
}

fn wipe_host_storage_string(value: &mut String) {
    // String guarantees that its initialized bytes are contiguous. The value
    // is never read again after this wipe; Drop subsequently releases the
    // allocation without exposing verifier, salt or encrypted identity bytes.
    password_security::memzero_secret(unsafe { value.as_mut_vec() });
}

fn preflight_host_storage() -> Result<(), HostStoragePreflightError> {
    preflight_host_storage_paths(&config::Config::file(), &config::Config2::file())
}

fn verify_host_start_storage(host: &RdnHost) -> Result<(), HostStoragePreflightError> {
    verify_host_start_storage_paths(
        &config::Config::file(),
        &config::Config2::file(),
        &host.rendezvous_server,
        &host.relay_server,
        &host.server_public_key,
        host.clipboard_transfer_policy,
        host.audio_enabled,
        &host.audio_input_device,
        host.file_transfer_enabled,
    )
}

fn native_host_clipboard_option(policy: NativeClipboardTransferPolicy) -> &'static str {
    if policy.any_enabled() {
        "Y"
    } else {
        "N"
    }
}

fn native_host_file_transfer_option(enabled: bool) -> &'static str {
    if enabled {
        "Y"
    } else {
        "N"
    }
}

fn native_host_audio_option(enabled: bool) -> &'static str {
    if enabled {
        "Y"
    } else {
        "N"
    }
}

fn valid_native_host_audio_input_device(enabled: bool, device: &str) -> bool {
    if device.is_empty() {
        return true;
    }
    enabled
        && device.len() <= AUDIO_INPUT_DEVICE_MAX_UTF8_BYTES
        && device.trim() == device
        && !device.chars().any(char::is_control)
}

fn apply_native_host_optional_capability_policy(
    clipboard_policy: NativeClipboardTransferPolicy,
    audio_enabled: bool,
    audio_input_device: &str,
    file_transfer_enabled: bool,
) {
    config::Config::set_option(
        config::keys::OPTION_ENABLE_CLIPBOARD.to_owned(),
        native_host_clipboard_option(clipboard_policy).to_owned(),
    );
    config::Config::set_option(
        config::keys::OPTION_ENABLE_FILE_TRANSFER.to_owned(),
        native_host_file_transfer_option(file_transfer_enabled).to_owned(),
    );
    config::Config::set_option(
        config::keys::OPTION_ENABLE_AUDIO.to_owned(),
        native_host_audio_option(audio_enabled).to_owned(),
    );
    config::Config::set_option(
        "audio-input".to_owned(),
        audio_input_device.to_owned(),
    );
}

fn verify_host_password_storage() -> Result<(), HostStoragePreflightError> {
    let (storage, salt) = config::Config::get_local_permanent_password_storage_and_salt();
    let storage = WipedHostStorageString(storage);
    let salt = WipedHostStorageString(salt);
    verify_host_password_storage_paths(
        &config::Config::file(),
        &config::Config2::file(),
        &storage.0,
        &salt.0,
    )
}

#[cfg(not(unix))]
fn preflight_host_storage_paths(
    _identity_path: &std::path::Path,
    _options_path: &std::path::Path,
) -> Result<(), HostStoragePreflightError> {
    Err(HostStoragePreflightError::UnsupportedPlatform)
}

#[cfg(not(unix))]
fn verify_host_start_storage_paths(
    _identity_path: &std::path::Path,
    _options_path: &std::path::Path,
    _rendezvous_server: &str,
    _relay_server: &str,
    _server_public_key: &str,
    _clipboard_policy: NativeClipboardTransferPolicy,
    _audio_enabled: bool,
    _audio_input_device: &str,
    _file_transfer_enabled: bool,
) -> Result<(), HostStoragePreflightError> {
    Err(HostStoragePreflightError::UnsupportedPlatform)
}

#[cfg(not(unix))]
fn verify_host_password_storage_paths(
    _identity_path: &std::path::Path,
    _options_path: &std::path::Path,
    _password_storage: &str,
    _password_salt: &str,
) -> Result<(), HostStoragePreflightError> {
    Err(HostStoragePreflightError::UnsupportedPlatform)
}

#[cfg(unix)]
fn preflight_host_storage_paths(
    identity_path: &std::path::Path,
    options_path: &std::path::Path,
) -> Result<(), HostStoragePreflightError> {
    inspect_host_storage_paths(identity_path, options_path, None).map(|_| ())
}

#[cfg(unix)]
fn verify_host_start_storage_paths(
    identity_path: &std::path::Path,
    options_path: &std::path::Path,
    rendezvous_server: &str,
    relay_server: &str,
    server_public_key: &str,
    clipboard_policy: NativeClipboardTransferPolicy,
    audio_enabled: bool,
    audio_input_device: &str,
    file_transfer_enabled: bool,
) -> Result<(), HostStoragePreflightError> {
    let (identity, options) = inspect_host_storage_paths(identity_path, options_path, None)?;
    let Some(HostStorageSnapshot::Identity {
        encrypted_id_present: true,
        ..
    }) = identity
    else {
        return Err(HostStoragePreflightError::PersistenceMismatch);
    };
    let Some(HostStorageSnapshot::Options(options)) = options else {
        return Err(HostStoragePreflightError::PersistenceMismatch);
    };
    let expected = [
        ("custom-rendezvous-server", rendezvous_server),
        ("relay-server", relay_server),
        ("key", server_public_key),
        (
            config::keys::OPTION_KEEP_AWAKE_DURING_INCOMING_SESSIONS,
            "Y",
        ),
        (
            config::keys::OPTION_ENABLE_CLIPBOARD,
            native_host_clipboard_option(clipboard_policy),
        ),
        (
            config::keys::OPTION_ENABLE_FILE_TRANSFER,
            native_host_file_transfer_option(file_transfer_enabled),
        ),
        (
            config::keys::OPTION_ENABLE_AUDIO,
            native_host_audio_option(audio_enabled),
        ),
        ("audio-input", audio_input_device),
        ("stop-service", ""),
    ];
    if expected
        .iter()
        .all(|(key, value)| persisted_host_option_matches(&options, key, value))
    {
        Ok(())
    } else {
        Err(HostStoragePreflightError::PersistenceMismatch)
    }
}

#[cfg(unix)]
fn verify_host_password_storage_paths(
    identity_path: &std::path::Path,
    options_path: &std::path::Path,
    password_storage: &str,
    password_salt: &str,
) -> Result<(), HostStoragePreflightError> {
    let (identity, options) = inspect_host_storage_paths(
        identity_path,
        options_path,
        Some((password_storage, password_salt)),
    )?;
    let Some(HostStorageSnapshot::Identity {
        encrypted_id_present: true,
        password_matches: Some(true),
    }) = identity
    else {
        return Err(HostStoragePreflightError::PersistenceMismatch);
    };
    if !matches!(options, Some(HostStorageSnapshot::Options(_))) {
        return Err(HostStoragePreflightError::PersistenceMismatch);
    }
    Ok(())
}

#[cfg(unix)]
fn persisted_host_option_matches(
    options: &HashMap<String, String>,
    key: &str,
    expected: &str,
) -> bool {
    if expected.is_empty() {
        !options.contains_key(key)
    } else {
        options.get(key).map(String::as_str) == Some(expected)
    }
}

#[cfg(unix)]
fn inspect_host_storage_paths(
    identity_path: &std::path::Path,
    options_path: &std::path::Path,
    password_expectation: Option<(&str, &str)>,
) -> Result<(Option<HostStorageSnapshot>, Option<HostStorageSnapshot>), HostStoragePreflightError> {
    use hbb_common::libc;
    use std::{
        ffi::CString,
        fs::File,
        os::unix::{
            ffi::OsStrExt,
            io::{AsRawFd, FromRawFd},
        },
    };

    let directory_path = identity_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or(HostStoragePreflightError::InvalidPath)?;
    if options_path.parent() != Some(directory_path)
        || identity_path.file_name().is_none()
        || options_path.file_name().is_none()
        || identity_path.file_name() == options_path.file_name()
    {
        return Err(HostStoragePreflightError::InvalidPath);
    }
    let directory_c = CString::new(directory_path.as_os_str().as_bytes())
        .map_err(|_| HostStoragePreflightError::InvalidPath)?;
    let directory_fd = unsafe {
        libc::open(
            directory_c.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if directory_fd < 0 {
        return match std::io::Error::last_os_error().raw_os_error() {
            Some(libc::ENOENT) => Ok((None, None)),
            _ => Err(HostStoragePreflightError::OpenDirectory),
        };
    }
    let directory = unsafe { File::from_raw_fd(directory_fd) };
    let directory_stat = checked_fstat(directory.as_raw_fd())
        .map_err(|_| HostStoragePreflightError::UnsafeDirectory)?;
    if directory_stat.st_mode & libc::S_IFMT != libc::S_IFDIR
        || directory_stat.st_uid != unsafe { libc::geteuid() }
        || directory_stat.st_mode & 0o022 != 0
    {
        return Err(HostStoragePreflightError::UnsafeDirectory);
    }

    let identity = inspect_host_storage_file(
        &directory,
        identity_path,
        HostStorageDocument::Identity,
        password_expectation,
    )?;
    let options =
        inspect_host_storage_file(&directory, options_path, HostStorageDocument::Options, None)?;
    Ok((identity, options))
}

#[cfg(unix)]
fn checked_fstat(fd: std::os::fd::RawFd) -> Result<hbb_common::libc::stat, ()> {
    use hbb_common::libc;
    let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(fd, metadata.as_mut_ptr()) } != 0 {
        return Err(());
    }
    Ok(unsafe { metadata.assume_init() })
}

#[cfg(unix)]
fn inspect_host_storage_file(
    directory: &std::fs::File,
    path: &std::path::Path,
    document: HostStorageDocument,
    password_expectation: Option<(&str, &str)>,
) -> Result<Option<HostStorageSnapshot>, HostStoragePreflightError> {
    use hbb_common::libc;
    use std::{
        ffi::CString,
        fs::File,
        io::Read,
        os::unix::{
            ffi::OsStrExt,
            io::{AsRawFd, FromRawFd},
        },
    };

    let file_name = path
        .file_name()
        .ok_or(HostStoragePreflightError::InvalidPath)?;
    let file_name_c =
        CString::new(file_name.as_bytes()).map_err(|_| HostStoragePreflightError::InvalidPath)?;
    let file_fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            file_name_c.as_ptr(),
            libc::O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if file_fd < 0 {
        return match std::io::Error::last_os_error().raw_os_error() {
            Some(libc::ENOENT) => Ok(None),
            _ => Err(HostStoragePreflightError::OpenFile),
        };
    }
    let mut file = unsafe { File::from_raw_fd(file_fd) };
    let initial_stat =
        checked_fstat(file.as_raw_fd()).map_err(|_| HostStoragePreflightError::UnsafeFile)?;
    if initial_stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || initial_stat.st_uid != unsafe { libc::geteuid() }
        || initial_stat.st_mode & 0o777 != 0o600
        || initial_stat.st_nlink != 1
        || initial_stat.st_size <= 0
        || initial_stat.st_size as u64 > MAX_HOST_CONFIG_BYTES as u64
    {
        return Err(HostStoragePreflightError::UnsafeFile);
    }

    let mut bytes = WipedHostStorageBytes::new(initial_stat.st_size as usize);
    file.by_ref()
        .take(MAX_HOST_CONFIG_BYTES as u64 + 1)
        .read_to_end(&mut bytes.0)
        .map_err(|_| HostStoragePreflightError::ReadFile)?;
    let final_stat =
        checked_fstat(file.as_raw_fd()).map_err(|_| HostStoragePreflightError::UnsafeFile)?;
    if bytes.0.len() > MAX_HOST_CONFIG_BYTES
        || bytes.0.len() as i64 != initial_stat.st_size
        || final_stat.st_dev != initial_stat.st_dev
        || final_stat.st_ino != initial_stat.st_ino
        || final_stat.st_size != initial_stat.st_size
    {
        return Err(HostStoragePreflightError::UnsafeFile);
    }
    let text =
        std::str::from_utf8(bytes.bytes()).map_err(|_| HostStoragePreflightError::InvalidUtf8)?;
    match document {
        HostStorageDocument::Identity => {
            let document = toml::from_str::<HostIdentityPersistenceProjection>(text)
                .map_err(|_| HostStoragePreflightError::InvalidToml)?;
            let encrypted_id_present = !document.enc_id.is_empty();
            let password_matches = password_expectation
                .map(|(storage, salt)| document.password == storage && document.salt == salt);
            Ok(Some(HostStorageSnapshot::Identity {
                encrypted_id_present,
                password_matches,
            }))
        }
        HostStorageDocument::Options => toml::from_str::<config::Config2>(text)
            .map(|config| Some(HostStorageSnapshot::Options(config.options)))
            .map_err(|_| HostStoragePreflightError::InvalidToml),
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_start(host: *mut RdnHost) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if !matches!(host.state, RdnHostState::Created | RdnHostState::Stopped) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    // Upstream Config/Config2 loading falls back to defaults on malformed or
    // unreadable TOML. The writes below could then replace the last durable
    // identity/config with generated defaults. Inspect both fixed Host files
    // first, without creating or rewriting anything, and fail closed instead.
    if preflight_host_storage().is_err() {
        host.registration_status = "degraded";
        host.state = RdnHostState::Error;
        host.last_error = Some("configuration.storagePreflightFailed".to_owned());
        host.emit_snapshot_changed();
        return RDN_HOST_ERR_STORAGE;
    }
    host.state = RdnHostState::Starting;
    host.emit_snapshot_changed();
    // Install the canonical self-hosted configuration before identity or
    // rendezvous state is touched. The public key is persisted only in the
    // isolated RustDesk host config and never emitted in snapshots/logs.
    config::Config::set_option(
        "custom-rendezvous-server".to_owned(),
        host.rendezvous_server.clone(),
    );
    config::Config::set_option("relay-server".to_owned(), host.relay_server.clone());
    config::Config::set_option("key".to_owned(), host.server_public_key.clone());
    // Clipboard, audio and file transfer are enabled only by their independent
    // create policies. Upstream treats a missing `enable-*` option as enabled,
    // so absence is never accepted as product policy.
    apply_native_host_optional_capability_policy(
        host.clipboard_transfer_policy,
        host.audio_enabled,
        &host.audio_input_device,
        host.file_transfer_enabled,
    );
    // FarPane Host owns an active authenticated screen route as a bounded
    // user-idle sleep assertion. The connection lifecycle releases it when
    // the last remote screen session ends; native mode never forces the
    // physical display to stay lit.
    config::Config::set_option(
        config::keys::OPTION_KEEP_AWAKE_DURING_INCOMING_SESSIONS.to_owned(),
        "Y".to_owned(),
    );
    // First identity access inside the isolated root generates and persists
    // the stable ID/key pair (§9.1).
    host.local_id = config::Config::get_id();
    password_security::update_temporary_password();
    config::Config::set_option("stop-service".to_owned(), String::new());
    // Upstream setters do not propagate confy write failures. Re-open the
    // fixed private files and require the persisted identity/config projection
    // needed by this start before any media or network runtime is created.
    // This proves readback, not fsync durability; the latter remains a
    // separate storage-writer boundary.
    if verify_host_start_storage(host).is_err() {
        host.registration_status = "degraded";
        host.state = RdnHostState::Error;
        host.last_error = Some("configuration.storagePersistenceFailed".to_owned());
        host.emit_snapshot_changed();
        return RDN_HOST_ERR_STORAGE;
    }
    bind_media_host(host);
    // The process-global wakelock worker outlives an individual Host handle.
    // Reset it only after binding this native Host so its thread pins the
    // user-idle (display-off) policy and cannot inherit a prior sleep epoch.
    if !crate::server::native_host_reset_wakelock() {
        unbind_media_host();
        host.registration_status = "degraded";
        host.state = RdnHostState::Error;
        host.recovery_state = HostRecoveryState::Failed;
        host.last_error = Some("power.wakelockResetFailed".to_owned());
        host.emit_snapshot_changed();
        return RDN_HOST_ERR_INTERNAL;
    }
    host.recovery_state = HostRecoveryState::Running;
    // A terminal stop/start begins a fresh product network-observation
    // lifetime. The path trigger owner also restarts from generation zero.
    host.network_path_generation = 0;
    host.runtime = match HostRuntime::start(host.rendezvous_server.clone()) {
        Ok(runtime) => Some(runtime),
        Err(()) => {
            unbind_media_host();
            host.registration_status = "degraded";
            host.state = RdnHostState::Error;
            host.last_error = Some("registration.runtimeStartFailed".to_owned());
            host.emit_snapshot_changed();
            return RDN_HOST_ERR_INTERNAL;
        }
    };
    host.registration_status = "pending";
    host.state = RdnHostState::Starting;
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_stop(host: *mut RdnHost, reason: RdnHostStopReason) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if matches!(host.state, RdnHostState::Stopped | RdnHostState::Stopping) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    host.state = RdnHostState::Stopping;
    unbind_media_host();
    if let Some(mut runtime) = host.runtime.take() {
        if !runtime.stop() {
            host.registration_status = "degraded";
            host.state = RdnHostState::Error;
            host.last_error = Some("registration.runtimeJoinFailed".to_owned());
            host.emit_snapshot_changed();
            return RDN_HOST_ERR_INTERNAL;
        }
    }
    // Invalidate the temporary password on stop (§9.2): rotate so the old
    // value cannot survive a stop/start cycle.
    password_security::update_temporary_password();
    host.reveal_temporary_password = false;
    host.registration_status = "notStarted";
    host.recovery_state = HostRecoveryState::Running;
    if matches!(reason, RdnHostStopReason::Error) {
        host.state = RdnHostState::Error;
    } else {
        host.state = RdnHostState::Stopped;
    }
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

fn fail_host_network_recovery(host: &mut RdnHost, detail: &str) -> i32 {
    host.registration_status = "degraded";
    // Network registration recovery is independent from the exact-epoch
    // sleep/wake state machine. Preserve Running so snapshot consumers do not
    // misclassify a registration failure as a wakelock recovery failure.
    host.recovery_state = HostRecoveryState::Running;
    host.state = RdnHostState::Error;
    host.last_error = Some(detail.to_owned());
    host.emit_snapshot_changed();
    RDN_HOST_ERR_INTERNAL
}

fn is_next_network_path_generation(current: u64, requested: u64) -> bool {
    requested != 0 && current.checked_add(1) == Some(requested)
}

/// Restart only the Rust-owned Rendezvous registration runtime after an
/// authoritative product network-path change. Success means the replacement
/// runtime was started as pending; a later snapshot must prove ready.
#[no_mangle]
pub unsafe extern "C" fn rdn_host_recover_network_path(
    host: *mut RdnHost,
    path_generation: u64,
) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_state != HostRecoveryState::Running
        || !matches!(host.state, RdnHostState::Starting | RdnHostState::Ready)
        || host.runtime.is_none()
    {
        return RDN_HOST_ERR_BAD_STATE;
    }
    if !is_next_network_path_generation(host.network_path_generation, path_generation) {
        return RDN_HOST_ERR_STALE_GENERATION;
    }

    // Commit the exact generation and withdraw the old ready projection before
    // stopping registration. Host identity/configuration and media/session
    // authorities stay bound to this RdnHost lifetime.
    host.network_path_generation = path_generation;
    host.registration_status = "pending";
    host.state = RdnHostState::Starting;
    host.last_error = None;
    host.emit_snapshot_changed();

    let mut runtime = host.runtime.take().unwrap();
    if !runtime.stop() {
        return fail_host_network_recovery(
            host,
            "registration.runtimeJoinFailedDuringNetworkRecovery",
        );
    }
    host.runtime = match HostRuntime::start(host.rendezvous_server.clone()) {
        Ok(runtime) => Some(runtime),
        Err(()) => {
            return fail_host_network_recovery(
                host,
                "registration.runtimeRestartFailedDuringNetworkRecovery",
            );
        }
    };
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

fn fail_host_sleep_recovery(host: &mut RdnHost, detail: &str) -> i32 {
    host.registration_status = "degraded";
    host.recovery_state = HostRecoveryState::Failed;
    host.state = RdnHostState::Error;
    host.last_error = Some(detail.to_owned());
    host.emit_snapshot_changed();
    RDN_HOST_ERR_INTERNAL
}

fn is_next_recovery_epoch(current: u64, requested: u64) -> bool {
    requested != 0 && current.checked_add(1) == Some(requested)
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_begin_sleep(host: *mut RdnHost, epoch: u64) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_state != HostRecoveryState::Running
        || !matches!(host.state, RdnHostState::Starting | RdnHostState::Ready)
        || host.runtime.is_none()
    {
        return RDN_HOST_ERR_BAD_STATE;
    }
    if !is_next_recovery_epoch(host.recovery_epoch, epoch) {
        return RDN_HOST_ERR_STALE_EPOCH;
    }

    host.recovery_epoch = epoch;
    host.recovery_state = HostRecoveryState::Suspending;
    host.registration_status = "suspending";
    host.state = RdnHostState::Starting;
    host.runtime.as_ref().unwrap().request_stop();
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_finish_sleep(host: *mut RdnHost, epoch: u64) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_epoch != epoch {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    if host.recovery_state != HostRecoveryState::Suspending {
        return RDN_HOST_ERR_BAD_STATE;
    }
    let Some(mut runtime) = host.runtime.take() else {
        return fail_host_sleep_recovery(host, "registration.runtimeMissingDuringSleep");
    };
    if !runtime.join() {
        return fail_host_sleep_recovery(host, "registration.runtimeJoinFailedDuringSleep");
    }
    if !crate::server::native_host_suspend_wakelock(epoch) {
        return fail_host_sleep_recovery(host, "power.wakelockSuspendFailed");
    }

    host.registration_status = "suspended";
    host.recovery_state = HostRecoveryState::Suspended;
    host.state = RdnHostState::Starting;
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_resume_after_wake(host: *mut RdnHost, epoch: u64) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_epoch != epoch {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    if host.recovery_state != HostRecoveryState::Suspended || host.runtime.is_some() {
        return RDN_HOST_ERR_BAD_STATE;
    }

    host.recovery_state = HostRecoveryState::Resuming;
    host.registration_status = "pending";
    host.state = RdnHostState::Starting;
    if !crate::server::native_host_resume_wakelock(epoch) {
        return fail_host_sleep_recovery(host, "power.wakelockResumeFailed");
    }
    host.runtime = match HostRuntime::start(host.rendezvous_server.clone()) {
        Ok(runtime) => Some(runtime),
        Err(()) => {
            return fail_host_sleep_recovery(host, "registration.runtimeResumeFailed");
        }
    };
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

fn fail_host_after_password_persistence_mismatch(host: &mut RdnHost) {
    // Config::set_permanent_password cannot report confy's write error. Once
    // readback proves that the in-memory verifier/salt is not durable, stop
    // every active route before reporting the terminal storage state. This
    // prevents a running Host from authenticating against ephemeral state.
    unbind_media_host();
    if let Some(mut runtime) = host.runtime.take() {
        let _ = runtime.stop();
    }
    password_security::update_temporary_password();
    host.reveal_temporary_password = false;
    host.registration_status = "degraded";
    host.state = RdnHostState::Error;
    host.last_error = Some("configuration.passwordPersistenceFailed".to_owned());
    host.emit_snapshot_changed();
}

fn parse_envelope(bytes: &[u8]) -> Result<Value, i32> {
    if bytes.is_empty() || bytes.len() > MAX_ENVELOPE_BYTES {
        return Err(RDN_HOST_ERR_VALIDATION);
    }
    serde_json::from_slice(bytes).map_err(|_| RDN_HOST_ERR_VALIDATION)
}

fn approval_connection_id(envelope: &Value) -> Result<&str, i32> {
    let Some(object) = envelope.as_object() else {
        return Err(RDN_HOST_ERR_VALIDATION);
    };
    if object.len() != 3
        || !object.contains_key("commandId")
        || !object.contains_key("name")
        || !object.contains_key("connectionId")
    {
        return Err(RDN_HOST_ERR_VALIDATION);
    }
    match object.get("connectionId").and_then(Value::as_str) {
        Some(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            Ok(value)
        }
        _ => Err(RDN_HOST_ERR_VALIDATION),
    }
}

fn session_connection_id(envelope: &Value) -> Result<&str, i32> {
    let Some(object) = envelope.as_object() else {
        return Err(RDN_HOST_ERR_VALIDATION);
    };
    if object.len() != 3
        || !object.contains_key("commandId")
        || !object.contains_key("name")
        || !object.contains_key("connectionId")
    {
        return Err(RDN_HOST_ERR_VALIDATION);
    }
    match object.get("connectionId").and_then(Value::as_str) {
        Some(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            Ok(value)
        }
        _ => Err(RDN_HOST_ERR_VALIDATION),
    }
}

fn handle_approval_command(
    host: &mut RdnHost,
    command_id: &str,
    decision: NativeApprovalDecision,
    envelope: &Value,
) -> i32 {
    let connection_id = match approval_connection_id(envelope) {
        Ok(value) => value,
        Err(code) => {
            host.emit_command_result(command_id, "rejected", "approval-command-invalid");
            return code;
        }
    };
    let expected_prefix = format!("{}:", host.instance_id);
    if !connection_id.starts_with(&expected_prefix) {
        host.emit_command_result(command_id, "rejected", "approval-not-found");
        return RDN_HOST_ERR_APPROVAL_NOT_FOUND;
    }
    match native_host_resolve_approval(connection_id, decision) {
        NativeApprovalResolveResult::Approved => {
            host.emit_command_result(command_id, "ok", "approval-approved");
            RDN_HOST_OK
        }
        NativeApprovalResolveResult::Rejected => {
            host.emit_command_result(command_id, "ok", "approval-rejected");
            RDN_HOST_OK
        }
        NativeApprovalResolveResult::Expired => {
            host.emit_command_result(command_id, "rejected", "approval-expired");
            RDN_HOST_ERR_APPROVAL_EXPIRED
        }
        NativeApprovalResolveResult::AlreadyFinal => {
            host.emit_command_result(command_id, "rejected", "approval-already-finalized");
            RDN_HOST_ERR_APPROVAL_FINALIZED
        }
        NativeApprovalResolveResult::NotFound => {
            host.emit_command_result(command_id, "rejected", "approval-not-found");
            RDN_HOST_ERR_APPROVAL_NOT_FOUND
        }
    }
}

fn handle_session_command(
    host: &mut RdnHost,
    command_id: &str,
    command: NativeSessionCommand,
    envelope: &Value,
) -> i32 {
    let connection_id = match session_connection_id(envelope) {
        Ok(value) => value,
        Err(code) => {
            host.emit_command_result(command_id, "rejected", "session-command-invalid");
            return code;
        }
    };
    let expected_prefix = format!("{}:", host.instance_id);
    if !connection_id.starts_with(&expected_prefix) {
        host.emit_command_result(command_id, "rejected", "session-not-found");
        return RDN_HOST_ERR_SESSION_NOT_FOUND;
    }

    match SESSION_BROKER
        .lock()
        .unwrap()
        .command(connection_id, command)
    {
        NativeSessionCommandResult::Queued => {
            let detail = match command {
                NativeSessionCommand::DisableInput => "session-input-disable-queued",
                NativeSessionCommand::DisableClipboardRead => {
                    "session-clipboard-read-disable-queued"
                }
                NativeSessionCommand::DisableClipboardWrite => {
                    "session-clipboard-write-disable-queued"
                }
                NativeSessionCommand::DisableClipboard => "session-clipboard-disable-queued",
                NativeSessionCommand::DisableAudio => "session-audio-disable-queued",
                NativeSessionCommand::Disconnect => "session-disconnect-queued",
            };
            host.emit_command_result(command_id, "ok", detail);
            RDN_HOST_OK
        }
        NativeSessionCommandResult::NoChange => {
            let detail = match command {
                NativeSessionCommand::DisableInput => "session-input-already-disabled",
                NativeSessionCommand::DisableClipboardRead => {
                    "session-clipboard-read-already-disabled"
                }
                NativeSessionCommand::DisableClipboardWrite => {
                    "session-clipboard-write-already-disabled"
                }
                NativeSessionCommand::DisableClipboard => "session-clipboard-already-disabled",
                NativeSessionCommand::DisableAudio => "session-audio-already-disabled",
                NativeSessionCommand::Disconnect => "session-disconnect-already-requested",
            };
            host.emit_command_result(command_id, "ok", detail);
            RDN_HOST_OK
        }
        NativeSessionCommandResult::NotFound => {
            host.emit_command_result(command_id, "rejected", "session-not-found");
            RDN_HOST_ERR_SESSION_NOT_FOUND
        }
        NativeSessionCommandResult::Stale => {
            host.emit_command_result(command_id, "rejected", "session-stale");
            RDN_HOST_ERR_SESSION_STALE
        }
        NativeSessionCommandResult::Unavailable => {
            host.emit_command_result(command_id, "error", "session-command-unavailable");
            RDN_HOST_ERR_SESSION_COMMAND_UNAVAILABLE
        }
    }
}

fn handle_command(host: &mut RdnHost, command_id: &str, name: &str, envelope: &Value) -> i32 {
    match name {
        "enableHost" => {
            // Host already runs in-process for the H1a spike; accept as no-op.
            host.emit_command_result(command_id, "ok", "host-enabled");
            RDN_HOST_OK
        }
        "disableHost" => {
            host.emit_command_result(command_id, "ok", "host-disabled");
            RDN_HOST_OK
        }
        "regenerateTemporaryPassword" => {
            password_security::update_temporary_password();
            host.emit_command_result(command_id, "ok", "temporary-password-regenerated");
            host.emit_snapshot_changed();
            RDN_HOST_OK
        }
        "revealTemporaryPassword" => {
            host.reveal_temporary_password = true;
            host.emit_command_result(command_id, "ok", "temporary-password-revealed");
            RDN_HOST_OK
        }
        "clearPermanentPassword" => {
            if config::Config::is_disable_change_permanent_password() {
                host.emit_command_result(
                    command_id,
                    "rejected",
                    "permanent-password-change-disabled",
                );
                RDN_HOST_ERR_CHANGE_DISABLED
            } else if config::Config::set_permanent_password("") {
                if verify_host_password_storage().is_err() {
                    host.emit_command_result(
                        command_id,
                        "error",
                        "permanent-password-storage-failed",
                    );
                    fail_host_after_password_persistence_mismatch(host);
                    return RDN_HOST_ERR_STORAGE;
                }
                let detail = if config::Config::has_permanent_password() {
                    "permanent-password-local-cleared-preset-still-effective"
                } else {
                    "permanent-password-local-cleared"
                };
                host.emit_command_result(command_id, "ok", detail);
                host.emit_snapshot_changed();
                RDN_HOST_OK
            } else {
                host.emit_command_result(command_id, "error", "permanent-password-storage-failed");
                RDN_HOST_ERR_STORAGE
            }
        }
        "approveConnection" => {
            handle_approval_command(host, command_id, NativeApprovalDecision::Approve, envelope)
        }
        "rejectConnection" => {
            handle_approval_command(host, command_id, NativeApprovalDecision::Reject, envelope)
        }
        "disableInputForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableInput,
            envelope,
        ),
        "disableClipboardForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableClipboard,
            envelope,
        ),
        "disableClipboardReadForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableClipboardRead,
            envelope,
        ),
        "disableClipboardWriteForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableClipboardWrite,
            envelope,
        ),
        "disableAudioForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableAudio,
            envelope,
        ),
        "disconnectSession" => {
            handle_session_command(host, command_id, NativeSessionCommand::Disconnect, envelope)
        }
        _ => {
            host.emit_command_result(command_id, "unknownCommand", name);
            RDN_HOST_OK
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_command(
    host: *mut RdnHost,
    command_json: *const u8,
    length: usize,
) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if command_json.is_null() {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    let bytes = std::slice::from_raw_parts(command_json, length);
    let envelope = match parse_envelope(bytes) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let command_id = match envelope.get("commandId").and_then(Value::as_str) {
        Some(value) if !value.is_empty() && value.len() <= 128 => value.to_owned(),
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    let name = match envelope.get("name").and_then(Value::as_str) {
        Some(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            value.to_owned()
        }
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    handle_command(host, &command_id, &name, &envelope)
}

/// Dedicated permanent-password ingress (§9.3). Password bytes never enter
/// JSON, logging, command-line arguments or persistent Swift storage. Rust
/// borrows the caller-owned mutable buffer and SecretBuffer wipes it on every
/// path after pointer validation; the Swift wrapper performs a second wipe.
#[no_mangle]
pub unsafe extern "C" fn rdn_host_set_permanent_password(
    host: *mut RdnHost,
    command_id: *const c_char,
    password_utf8: *mut u8,
    password_length: usize,
) -> i32 {
    if password_utf8.is_null() && password_length != 0 {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    let secret = if password_utf8.is_null() {
        None
    } else {
        Some(SecretBuffer::from_raw_parts(password_utf8, password_length))
    };
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    let command_id = match required_string(command_id) {
        Ok(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            value
        }
        Ok(_) => return RDN_HOST_ERR_VALIDATION,
        Err(code) => return code,
    };
    let bytes = secret.as_ref().map(SecretBuffer::bytes).unwrap_or_default();
    let password = match validate_permanent_password(bytes) {
        Ok(password) => password,
        Err(rejection) => {
            host.emit_command_result(&command_id, "rejected", rejection.detail);
            return rejection.code;
        }
    };
    if config::Config::is_disable_change_permanent_password() {
        host.emit_command_result(
            &command_id,
            "rejected",
            "permanent-password-change-disabled",
        );
        return RDN_HOST_ERR_CHANGE_DISABLED;
    }
    if !config::Config::set_permanent_password(password) {
        host.emit_command_result(&command_id, "error", "permanent-password-storage-failed");
        return RDN_HOST_ERR_STORAGE;
    }
    if verify_host_password_storage().is_err() {
        host.emit_command_result(&command_id, "error", "permanent-password-storage-failed");
        fail_host_after_password_persistence_mismatch(host);
        return RDN_HOST_ERR_STORAGE;
    }
    host.emit_command_result(&command_id, "ok", "permanent-password-set");
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_copy_snapshot(
    host: *mut RdnHost,
    out_snapshot: *mut RdnHostOwnedBytes,
) -> i32 {
    let (Some(host), Some(out_snapshot)) = (host.as_mut(), out_snapshot.as_mut()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    let encoded = match serde_json::to_vec(&host.snapshot_json()) {
        Ok(value) => value,
        Err(_) => return RDN_HOST_ERR_INTERNAL,
    };
    let mut boxed = encoded.into_boxed_slice();
    out_snapshot.data = boxed.as_mut_ptr();
    out_snapshot.length = boxed.len();
    out_snapshot.capacity = boxed.len();
    std::mem::forget(boxed);
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_free_bytes(bytes: RdnHostOwnedBytes) {
    if bytes.data.is_null() || bytes.capacity == 0 {
        return;
    }
    drop(Box::from_raw(std::slice::from_raw_parts_mut(
        bytes.data,
        bytes.capacity,
    )));
}

#[no_mangle]
pub extern "C" fn rdn_host_media_abi_version() -> u32 {
    HOST_MEDIA_ABI_VERSION
}

unsafe fn validate_media_instance(
    host: &RdnHost,
    abi_version: u32,
    instance_pointer: *const c_char,
) -> Result<(), i32> {
    if abi_version != HOST_MEDIA_ABI_VERSION {
        return Err(RDN_HOST_ERR_ABI_MISMATCH);
    }
    let instance_id = required_string(instance_pointer)?;
    if instance_id != host.instance_id {
        return Err(RDN_HOST_ERR_STALE_EPOCH);
    }
    if !matches!(host.state, RdnHostState::Starting | RdnHostState::Ready) {
        return Err(RDN_HOST_ERR_BAD_STATE);
    }
    Ok(())
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_media_set_capabilities(
    host: *mut RdnHost,
    capabilities: *const RdnHostEncoderCapabilities,
) -> i32 {
    let (Some(host), Some(capabilities)) = (host.as_ref(), capabilities.as_ref()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if let Err(code) = validate_media_instance(
        host,
        capabilities.abi_version,
        capabilities.host_instance_id,
    ) {
        return code;
    }
    if capabilities.h264_hardware > 1
        || capabilities.h265_hardware > 1
        || capabilities.h264_hardware + capabilities.h265_hardware == 0
        || !(16..=16_384).contains(&capabilities.max_width)
        || !(16..=16_384).contains(&capabilities.max_height)
        || !(1..=240).contains(&capabilities.max_fps)
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    let mut broker = MEDIA_BROKER.lock().unwrap();
    let Some(binding) = broker.binding.as_ref() else {
        return RDN_HOST_ERR_BAD_STATE;
    };
    if binding.instance_id != host.instance_id {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    broker.capabilities = MediaCapabilities {
        h264_hardware: capabilities.h264_hardware == 1,
        h265_hardware: capabilities.h265_hardware == 1,
        max_width: capabilities.max_width,
        max_height: capabilities.max_height,
        max_fps: capabilities.max_fps,
    };
    scrap::codec::set_native_encoding_capabilities(
        broker.capabilities.h264_hardware,
        broker.capabilities.h265_hardware,
    );
    drop(broker);
    scrap::codec::Encoder::update(scrap::codec::EncodingUpdate::Check);
    host.emit_event(
        "mediaCapabilitiesChanged",
        json!({
            "h264Hardware": capabilities.h264_hardware == 1,
            "h265Hardware": capabilities.h265_hardware == 1,
            "maxWidth": capabilities.max_width,
            "maxHeight": capabilities.max_height,
            "maxFps": capabilities.max_fps,
        }),
    );
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_media_submit_access_unit(
    host: *mut RdnHost,
    access_unit: *const RdnHostEncodedAccessUnit,
) -> i32 {
    let (Some(host), Some(access_unit)) = (host.as_ref(), access_unit.as_ref()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if let Err(code) =
        validate_media_instance(host, access_unit.abi_version, access_unit.host_instance_id)
    {
        return code;
    }
    // Recheck the same Rust Aqua authority at the final encoded admission
    // boundary. This prevents a route-loop acknowledgement wait from allowing
    // post-transition payload copies or queue insertion.
    if !native_host_session_is_available() {
        return RDN_HOST_ERR_BAD_STATE;
    }
    if access_unit.data.is_null() || access_unit.length == 0 {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    if access_unit.length > MAX_MEDIA_ACCESS_UNIT_BYTES {
        return RDN_HOST_ERR_PACKET_TOO_LARGE;
    }
    if !matches!(access_unit.codec, MEDIA_CODEC_H264 | MEDIA_CODEC_H265)
        || !matches!(
            access_unit.framing,
            MEDIA_FRAMING_ANNEX_B | MEDIA_FRAMING_AVCC
        )
        || access_unit.flags & !MEDIA_KNOWN_FLAGS != 0
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    let keyframe = access_unit.flags & MEDIA_FLAG_KEYFRAME != 0;
    let has_parameter_sets = access_unit.flags & MEDIA_FLAG_PARAMETER_SETS != 0;
    if keyframe && !has_parameter_sets {
        return RDN_HOST_ERR_MISSING_PARAMETER_SETS;
    }
    // Copy before touching the queue so Swift may release its callback-scoped
    // VideoToolbox buffer as soon as this function returns.
    let data = std::slice::from_raw_parts(access_unit.data, access_unit.length).to_vec();
    let mut broker = MEDIA_BROKER.lock().unwrap();
    let Some(route) = broker.routes.get_mut(&access_unit.display_id) else {
        return RDN_HOST_ERR_BAD_STATE;
    };
    if route.connection_epoch != access_unit.connection_epoch
        || route.codec_epoch != access_unit.codec_epoch
        || route.display_revision != access_unit.display_revision
    {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    if route.codec != access_unit.codec {
        return RDN_HOST_ERR_CODEC_MISMATCH;
    }
    if route.needs_parameter_sets && !(keyframe && has_parameter_sets) {
        return RDN_HOST_ERR_MISSING_PARAMETER_SETS;
    }
    if route
        .last_pts_us
        .map(|last| access_unit.pts_us <= last)
        .unwrap_or(false)
    {
        return RDN_HOST_ERR_NON_MONOTONIC_PTS;
    }
    let packet = NativeMediaAccessUnit {
        codec: access_unit.codec,
        framing: access_unit.framing,
        pts_us: access_unit.pts_us,
        keyframe,
        has_parameter_sets,
        data,
    };
    match try_enqueue_native_media(&route.sender, &route.queue_telemetry, packet) {
        Ok(()) => {
            route.last_pts_us = Some(access_unit.pts_us);
            route.needs_parameter_sets = false;
            RDN_HOST_OK
        }
        Err((NativeMediaQueueDropReason::NetworkBackpressure, _)) => RDN_HOST_ERR_BACKPRESSURE,
        Err((NativeMediaQueueDropReason::Shutdown, _)) => RDN_HOST_ERR_BAD_STATE,
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_media_report_encoder_state(
    host: *mut RdnHost,
    state: *const RdnHostEncoderState,
) -> i32 {
    let (Some(host), Some(state)) = (host.as_ref(), state.as_ref()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if let Err(code) = validate_media_instance(host, state.abi_version, state.host_instance_id) {
        return code;
    }
    if !matches!(state.codec, MEDIA_CODEC_H264 | MEDIA_CODEC_H265)
        || state.hardware_accelerated > 1
        || state.software_fallback > 1
        || state.hardware_accelerated + state.software_fallback != 1
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    let encoder_id = match required_string(state.encoder_id) {
        Ok(value) if !value.is_empty() && value.len() <= MAX_ENCODER_ID_BYTES => value,
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    let broker = MEDIA_BROKER.lock().unwrap();
    let route_matches = broker.routes.values().any(|route| {
        route.connection_epoch == state.connection_epoch
            && route.codec_epoch == state.codec_epoch
            && route.codec == state.codec
    });
    drop(broker);
    if !route_matches {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    host.emit_event(
        "encoderStateChanged",
        json!({
            "connectionEpoch": state.connection_epoch,
            "codecEpoch": state.codec_epoch,
            "codec": if state.codec == MEDIA_CODEC_H264 { "h264" } else { "h265" },
            "hardwareAccelerated": state.hardware_accelerated == 1,
            "softwareFallback": state.software_fallback == 1,
            "encoderId": encoder_id,
        }),
    );
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_destroy(host: *mut RdnHost) {
    if host.is_null() {
        return;
    }
    let mut host = Box::from_raw(host);
    unbind_media_host();
    if let Some(mut runtime) = host.runtime.take() {
        let _ = runtime.stop();
    }
    if !matches!(host.state, RdnHostState::Stopped | RdnHostState::Error) {
        password_security::update_temporary_password();
    }
    HOST_INSTANCE_LIVE.store(false, Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        ffi::CString,
        fs,
        io::Write,
        path::{Path, PathBuf},
        sync::atomic::AtomicU64,
    };

    #[cfg(unix)]
    use std::os::unix::fs::{symlink, PermissionsExt};

    static MEDIA_BROKER_TEST_LOCK: Mutex<()> = Mutex::new(());
    static PASSWORD_COMMAND_TEST_LOCK: Mutex<()> = Mutex::new(());
    static HOST_STORAGE_FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    #[cfg(unix)]
    struct HostStorageFixture {
        root: PathBuf,
        identity: PathBuf,
        options: PathBuf,
    }

    #[cfg(unix)]
    impl HostStorageFixture {
        fn new() -> Self {
            let sequence = HOST_STORAGE_FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "farpane-host-storage-preflight-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&root).expect("create storage fixture");
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
                .expect("secure storage fixture");
            Self {
                identity: root.join("FarPaneHost.toml"),
                options: root.join("FarPaneHost2.toml"),
                root,
            }
        }

        fn write_private(path: &Path, bytes: &[u8]) {
            fs::write(path, bytes).expect("write storage fixture document");
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))
                .expect("secure storage fixture document");
        }

        fn write_valid_documents(&self) -> (Vec<u8>, Vec<u8>) {
            let identity = toml::to_string(&config::Config::default())
                .expect("serialize identity fixture")
                .into_bytes();
            let options = toml::to_string(&config::Config2::default())
                .expect("serialize options fixture")
                .into_bytes();
            Self::write_private(&self.identity, &identity);
            Self::write_private(&self.options, &options);
            (identity, options)
        }

        fn write_startup_documents(
            &self,
            rendezvous_server: &str,
            relay_server: &str,
            server_public_key: &str,
            audio_enabled: bool,
            file_transfer_enabled: bool,
        ) -> (Vec<u8>, Vec<u8>) {
            let identity = b"enc_id = \"opaque-encrypted-id\"\n".to_vec();
            let mut config = config::Config2::default();
            config.options.insert(
                "custom-rendezvous-server".to_owned(),
                rendezvous_server.to_owned(),
            );
            if !relay_server.is_empty() {
                config
                    .options
                    .insert("relay-server".to_owned(), relay_server.to_owned());
            }
            config
                .options
                .insert("key".to_owned(), server_public_key.to_owned());
            config.options.insert(
                config::keys::OPTION_KEEP_AWAKE_DURING_INCOMING_SESSIONS.to_owned(),
                "Y".to_owned(),
            );
            config.options.insert(
                config::keys::OPTION_ENABLE_CLIPBOARD.to_owned(),
                "N".to_owned(),
            );
            config.options.insert(
                config::keys::OPTION_ENABLE_FILE_TRANSFER.to_owned(),
                native_host_file_transfer_option(file_transfer_enabled).to_owned(),
            );
            config.options.insert(
                config::keys::OPTION_ENABLE_AUDIO.to_owned(),
                native_host_audio_option(audio_enabled).to_owned(),
            );
            let options = toml::to_string(&config)
                .expect("serialize startup options fixture")
                .into_bytes();
            Self::write_private(&self.identity, &identity);
            Self::write_private(&self.options, &options);
            (identity, options)
        }

        fn write_password_documents(
            &self,
            password_storage: &str,
            password_salt: &str,
        ) -> (Vec<u8>, Vec<u8>) {
            let identity = format!(
                "enc_id = \"opaque-encrypted-id\"\npassword = {password_storage:?}\nsalt = {password_salt:?}\n"
            )
            .into_bytes();
            let options = toml::to_string(&config::Config2::default())
                .expect("serialize password options fixture")
                .into_bytes();
            Self::write_private(&self.identity, &identity);
            Self::write_private(&self.options, &options);
            (identity, options)
        }
    }

    #[cfg(unix)]
    impl Drop for HostStorageFixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn host_runtime_reconnect_backoff_grows_caps_and_resets_after_stability() {
        let mut backoff = HostRuntimeReconnectBackoff::default();
        let short_connection = Duration::from_millis(1);
        let maximum_jitter_samples = [62, 125, 250, 500, 1_000, 1_250, 1_250, 1_250];
        let delays: Vec<u64> = maximum_jitter_samples
            .into_iter()
            .map(|jitter| {
                backoff
                    .delay_after_exit(short_connection, jitter)
                    .as_millis() as u64
            })
            .collect();
        assert_eq!(delays, [312, 625, 1_250, 2_500, 5_000, 5_000, 5_000, 5_000]);
        assert!(delays
            .iter()
            .all(|delay| *delay <= HOST_RUNTIME_RECONNECT_MAX_DELAY_MS));

        assert_eq!(
            backoff.delay_after_exit(
                Duration::from_millis(HOST_RUNTIME_RECONNECT_STABLE_CONNECTION_MS),
                0,
            ),
            Duration::from_millis(HOST_RUNTIME_RECONNECT_BASE_DELAY_MS)
        );
        assert_eq!(
            backoff.delay_after_exit(short_connection, 0),
            Duration::from_millis(HOST_RUNTIME_RECONNECT_BASE_DELAY_MS * 2)
        );
    }

    #[test]
    fn host_runtime_reconnect_wait_is_bounded_and_stop_interruptible() {
        let runtime = hbb_common::tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .expect("build reconnect wait runtime");
        runtime.block_on(async {
            let stop_requested = Arc::new(AtomicBool::new(false));
            let setter = stop_requested.clone();
            hbb_common::tokio::spawn(async move {
                hbb_common::tokio::time::sleep(Duration::from_millis(5)).await;
                setter.store(true, Ordering::Release);
            });
            let started = Instant::now();
            assert!(!wait_for_host_runtime_retry(&stop_requested, Duration::from_secs(5)).await);
            assert!(started.elapsed() < Duration::from_secs(1));

            stop_requested.store(false, Ordering::Release);
            assert!(wait_for_host_runtime_retry(&stop_requested, Duration::ZERO).await);
        });
    }

    #[test]
    fn host_runtime_registration_watchdog_restarts_only_after_a_bounded_stall() {
        let started = Instant::now();
        let timeout = Duration::from_millis(HOST_RUNTIME_REGISTRATION_STALL_TIMEOUT_MS);
        let mut watchdog = HostRuntimeRegistrationWatchdog::default();

        assert!(!watchdog.should_restart(started, false));
        assert!(!watchdog.should_restart(started + timeout - Duration::from_millis(1), false));
        assert!(watchdog.should_restart(started + timeout, false));

        assert!(!watchdog.should_restart(started + timeout, true));
        assert!(!watchdog.should_restart(started + timeout + Duration::from_secs(30), true));
        assert!(!watchdog.should_restart(started + timeout + Duration::from_secs(31), false));
    }

    #[test]
    fn host_recovery_epoch_is_strictly_sequential_and_exhaustion_safe() {
        assert!(is_next_recovery_epoch(0, 1));
        assert!(is_next_recovery_epoch(41, 42));
        assert!(!is_next_recovery_epoch(0, 0));
        assert!(!is_next_recovery_epoch(1, 1));
        assert!(!is_next_recovery_epoch(1, 3));
        assert!(!is_next_recovery_epoch(u64::MAX, 0));
        assert!(!is_next_recovery_epoch(u64::MAX, u64::MAX));
    }

    #[test]
    fn native_media_epoch_is_monotonic_and_exhaustion_safe() {
        let counter = AtomicU64::new(1);
        assert_eq!(next_native_media_epoch(&counter), Some(1));
        assert_eq!(next_native_media_epoch(&counter), Some(2));

        let last = AtomicU64::new(u64::MAX - 1);
        assert_eq!(next_native_media_epoch(&last), Some(u64::MAX - 1));
        assert_eq!(next_native_media_epoch(&last), None);
        assert_eq!(next_native_media_epoch(&last), None);

        let exhausted = AtomicU64::new(u64::MAX);
        assert_eq!(next_native_media_epoch(&exhausted), None);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_allows_first_start_without_writing() {
        let missing_root = std::env::temp_dir().join(format!(
            "farpane-host-storage-missing-{}-{}",
            std::process::id(),
            HOST_STORAGE_FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let identity = missing_root.join("FarPaneHost.toml");
        let options = missing_root.join("FarPaneHost2.toml");
        assert_eq!(preflight_host_storage_paths(&identity, &options), Ok(()));
        assert!(!missing_root.exists());

        let fixture = HostStorageFixture::new();
        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Ok(())
        );
        assert_eq!(fs::read_dir(&fixture.root).unwrap().count(), 0);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_accepts_valid_private_toml_without_mutation() {
        let fixture = HostStorageFixture::new();
        let (identity, options) = fixture.write_valid_documents();

        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_accepts_exact_start_projection_without_mutation() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "127.0.0.1:21117";
        let server_public_key = "synthetic-public-key";
        let (identity, options) = fixture.write_startup_documents(
            rendezvous_server,
            relay_server,
            server_public_key,
            false,
            false,
        );

        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                false,
                "",
                false,
            ),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);

        let mut explicit_config: config::Config2 =
            toml::from_str(std::str::from_utf8(&options).unwrap()).unwrap();
        explicit_config.options.insert(
            "audio-input".to_owned(),
            "BlackHole 2ch".to_owned(),
        );
        explicit_config.options.insert(
            config::keys::OPTION_ENABLE_AUDIO.to_owned(),
            "Y".to_owned(),
        );
        let explicit_options = toml::to_string(&explicit_config).unwrap().into_bytes();
        HostStorageFixture::write_private(&fixture.options, &explicit_options);
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                true,
                "BlackHole 2ch",
                false,
            ),
            Ok(())
        );
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                true,
                "",
                false,
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.options).unwrap(), explicit_options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_accepts_explicit_clipboard_opt_in_only() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "";
        let server_public_key = "synthetic-public-key";
        let (identity, options) = fixture.write_startup_documents(
            rendezvous_server,
            relay_server,
            server_public_key,
            false,
            false,
        );
        let mut config: config::Config2 =
            toml::from_str(std::str::from_utf8(&options).unwrap()).unwrap();
        config.options.insert(
            config::keys::OPTION_ENABLE_CLIPBOARD.to_owned(),
            "Y".to_owned(),
        );
        let enabled_options = toml::to_string(&config).unwrap().into_bytes();
        HostStorageFixture::write_private(&fixture.options, &enabled_options);

        for policy in [
            NativeClipboardTransferPolicy::new(
                NativeClipboardPolicy::new(true, false),
                NativeClipboardPolicy::default(),
            ),
            NativeClipboardTransferPolicy::new(
                NativeClipboardPolicy::default(),
                NativeClipboardPolicy::new(false, true),
            ),
            NativeClipboardTransferPolicy::new(
                NativeClipboardPolicy::new(true, true),
                NativeClipboardPolicy::new(true, true),
            ),
        ] {
            assert_eq!(
                verify_host_start_storage_paths(
                    &fixture.identity,
                    &fixture.options,
                    rendezvous_server,
                    relay_server,
                    server_public_key,
                    policy,
                    false,
                    "",
                    false,
                ),
                Ok(())
            );
        }
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                false,
                "",
                false,
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), enabled_options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_rejects_missing_or_stale_start_projection() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "";
        let server_public_key = "synthetic-public-key";
        let (identity, options) = fixture.write_startup_documents(
            rendezvous_server,
            relay_server,
            server_public_key,
            false,
            false,
        );

        fs::remove_file(&fixture.identity).unwrap();
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                false,
                "",
                false,
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert!(!fixture.identity.exists());
        HostStorageFixture::write_private(&fixture.identity, &identity);

        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                "127.0.0.1:21118",
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                false,
                "",
                false,
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);

        let mut config: config::Config2 =
            toml::from_str(std::str::from_utf8(&options).unwrap()).unwrap();
        config.options.remove(config::keys::OPTION_ENABLE_CLIPBOARD);
        HostStorageFixture::write_private(
            &fixture.options,
            toml::to_string(&config).unwrap().as_bytes(),
        );
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                false,
                "",
                false,
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
    }

    #[test]
    fn native_host_optional_data_capabilities_require_explicit_policy() {
        assert_eq!(
            native_host_clipboard_option(NativeClipboardTransferPolicy::default()),
            "N"
        );
        assert_eq!(
            native_host_clipboard_option(NativeClipboardTransferPolicy::new(
                NativeClipboardPolicy::new(true, false),
                NativeClipboardPolicy::default(),
            )),
            "Y"
        );
        assert_eq!(
            native_host_clipboard_option(NativeClipboardTransferPolicy::new(
                NativeClipboardPolicy::default(),
                NativeClipboardPolicy::new(false, true),
            )),
            "Y"
        );
        assert_eq!(
            native_host_clipboard_option(NativeClipboardTransferPolicy::new(
                NativeClipboardPolicy::new(true, true),
                NativeClipboardPolicy::new(true, true),
            )),
            "Y"
        );
        assert_eq!(native_host_audio_option(false), "N");
        assert_eq!(native_host_audio_option(true), "Y");
        assert_eq!(native_host_file_transfer_option(false), "N");
        assert_eq!(native_host_file_transfer_option(true), "Y");
    }

    #[test]
    fn native_host_audio_input_device_is_bounded_explicit_and_default_safe() {
        assert!(valid_native_host_audio_input_device(false, ""));
        assert!(valid_native_host_audio_input_device(true, ""));
        assert!(valid_native_host_audio_input_device(true, "BlackHole 2ch"));
        assert!(!valid_native_host_audio_input_device(false, "BlackHole 2ch"));
        assert!(!valid_native_host_audio_input_device(true, " BlackHole 2ch"));
        assert!(!valid_native_host_audio_input_device(true, "BlackHole\n2ch"));
        assert!(!valid_native_host_audio_input_device(
            true,
            &"x".repeat(AUDIO_INPUT_DEVICE_MAX_UTF8_BYTES + 1),
        ));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_new_file_write_job_commits_exact_files() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-write-commit-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            41,
            "incoming",
            0,
            vec![
                NativeHostWriteEntry::new("a.txt".to_string(), 3, 1),
                NativeHostWriteEntry::new("nested/b.txt".to_string(), 4, 2),
            ],
            7,
            true,
        ) else {
            panic!("native write job must be admitted");
        };
        assert_eq!(job.id(), 41);
        assert_eq!(
            job.confirm_file_digest(0, 3, 1, false),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(job.write_block(0, b"abc", false), Ok(()));
        assert_eq!(
            job.confirm_file_digest(1, 4, 2, false),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        let compressed = hbb_common::compress::compress(b"defg");
        assert_eq!(job.write_block(1, &compressed, true), Ok(()));
        assert_eq!(job.finish(2), Ok(()));

        assert_eq!(
            fs::read(fixture.root.join("incoming/a.txt")).unwrap(),
            b"abc"
        );
        assert_eq!(
            fs::read(fixture.root.join("incoming/nested/b.txt")).unwrap(),
            b"defg"
        );
        assert!(!fixture.root.join("incoming/a.txt.farpane-part").exists());
        assert!(!fixture
            .root
            .join("incoming/nested/b.txt.farpane-part")
            .exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_receive_root_commits_zero_length_before_following_file() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-write-root-zero-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            45,
            "",
            0,
            vec![
                NativeHostWriteEntry::new("zero.txt".to_string(), 0, 11),
                NativeHostWriteEntry::new("data.txt".to_string(), 3, 12),
            ],
            3,
            true,
        ) else {
            panic!("receive-root write job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 0, 11, false),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(fs::read(fixture.root.join("zero.txt")).unwrap(), b"");
        assert_eq!(
            job.confirm_file_digest(1, 3, 12, false),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(job.write_block(1, b"abc", false), Ok(()));
        assert_eq!(job.finish(2), Ok(()));
        assert_eq!(fs::read(fixture.root.join("data.txt")).unwrap(), b"abc");
        assert!(!fixture.root.join("zero.txt.farpane-part").exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_new_file_write_job_rejects_bounds_order_and_resume() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-write-bounds-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            42,
            "bounded",
            0,
            vec![NativeHostWriteEntry::new("file.txt".to_string(), 3, 3)],
            3,
            true,
        ) else {
            panic!("native write job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 3, 3, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(
            job.write_block(1, b"x", false),
            Err(NativeHostWriteJobError::UnexpectedFileNumber)
        );
        let oversized_wire = vec![0; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES + 1];
        assert_eq!(
            job.write_block(0, &oversized_wire, false),
            Err(NativeHostWriteJobError::WirePayloadTooLarge)
        );
        let oversized_decoded = hbb_common::compress::compress(&vec![
            b'x';
            hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES
                + 1
        ]);
        assert_eq!(
            job.write_block(0, &oversized_decoded, true),
            Err(NativeHostWriteJobError::DecodedPayloadInvalidOrTooLarge)
        );
        assert_eq!(
            job.write_block(0, b"four", false),
            Err(NativeHostWriteJobError::FileSizeExceeded)
        );
        drop(job);
        assert!(!fixture.root.join("bounded/file.txt").exists());
        assert!(!fixture.root.join("bounded/file.txt.farpane-part").exists());

        assert!(matches!(
            native_host_begin_new_file_write_job(
                43,
                "../escape",
                0,
                vec![NativeHostWriteEntry::new("file.txt".to_string(), 0, 0)],
                0,
                false,
            ),
            NativeHostWriteJobAdmission::Rejected(NativeHostWriteJobError::InvalidPath)
        ));
        assert!(matches!(
            native_host_begin_new_file_write_job(
                44,
                "incoming",
                0,
                vec![
                    NativeHostWriteEntry::new("same.txt".to_string(), 0, 0),
                    NativeHostWriteEntry::new("same.txt".to_string(), 0, 0),
                ],
                0,
                false,
            ),
            NativeHostWriteJobAdmission::Rejected(NativeHostWriteJobError::DuplicateDestination)
        ));
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_new_file_write_job_abort_cleans_only_staging() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-write-drop-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            45,
            "cancel",
            0,
            vec![
                NativeHostWriteEntry::new("committed.txt".to_string(), 1, 4),
                NativeHostWriteEntry::new("partial.txt".to_string(), 2, 5),
            ],
            3,
            false,
        ) else {
            panic!("native write job must be admitted");
        };
        assert_eq!(job.write_block(0, b"a", false), Ok(()));
        assert_eq!(job.write_block(1, b"b", false), Ok(()));
        assert!(fixture.root.join("cancel/committed.txt").is_file());
        assert!(fixture
            .root
            .join("cancel/partial.txt.farpane-part")
            .is_file());
        job.abort();

        assert_eq!(
            fs::read(fixture.root.join("cancel/committed.txt")).unwrap(),
            b"a"
        );
        assert!(!fixture.root.join("cancel/partial.txt").exists());
        assert!(!fixture
            .root
            .join("cancel/partial.txt.farpane-part")
            .exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_new_file_write_job_rejects_after_unbind() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-write-unbind-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            46,
            "unbind/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 2, 6)],
            2,
            false,
        ) else {
            panic!("native write job must be admitted");
        };
        assert_eq!(job.write_block(0, b"a", false), Ok(()));
        unbind_media_host();
        assert_eq!(
            job.write_block(0, b"b", false),
            Err(NativeHostWriteJobError::Unavailable)
        );
        job.abort();
        assert!(!fixture.root.join("unbind/file.txt").exists());
        assert!(!fixture.root.join("unbind/file.txt.farpane-part").exists());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_single_file_resume_reuses_verified_checkpoint() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-resume-success-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut first) = native_host_begin_new_file_write_job(
            51,
            "resume/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 6, 10)],
            6,
            true,
        ) else {
            panic!("first native resume job must be admitted");
        };
        assert_eq!(
            first.confirm_file_digest(0, 6, 10, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(first.write_block(0, b"abc", false), Ok(()));
        drop(first);
        assert_eq!(
            fs::read(fixture.root.join("resume/file.txt.farpane-part")).unwrap(),
            b"abc"
        );

        let NativeHostWriteJobAdmission::Admitted(mut resumed) =
            native_host_begin_new_file_write_job(
                52,
                "resume/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 6, 10)],
                6,
                true,
            )
        else {
            panic!("second native resume job must be admitted");
        };
        assert_eq!(
            resumed.confirm_file_digest(0, 6, 10, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(3))
        );
        assert_eq!(resumed.write_block(0, b"def", false), Ok(()));
        assert_eq!(resumed.finish(1), Ok(()));
        assert_eq!(
            fs::read(fixture.root.join("resume/file.txt")).unwrap(),
            b"abcdef"
        );
        assert!(!fixture.root.join("resume/file.txt.farpane-part").exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_existing_target_requires_skip_and_preserves_original() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let destination = fixture.root.join("existing/file.txt");
        fs::create_dir(destination.parent().unwrap()).expect("create existing parent");
        fs::set_permissions(
            destination.parent().unwrap(),
            fs::Permissions::from_mode(0o700),
        )
        .expect("secure existing parent");
        HostStorageFixture::write_private(&destination, b"original");
        HostStorageFixture::write_private(
            &fixture.root.join("existing/file.txt.farpane-part"),
            b"old-partial",
        );
        let existing_modified = fs::metadata(&destination)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-existing-skip-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            63,
            "existing/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 3, 99)],
            3,
            true,
        ) else {
            panic!("existing-target job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 3, 99, false),
            Ok(NativeHostWriteDigestDecision::ExistingTarget {
                file_size: 8,
                last_modified: existing_modified,
                is_identical: false,
            })
        );
        assert_eq!(
            job.write_block(0, b"new", false),
            Err(NativeHostWriteJobError::ExistingTargetDecisionRequired)
        );
        assert_eq!(
            job.confirm_existing_target_decision(0, NativeHostExistingTargetDecision::Skip),
            Ok(())
        );
        assert_eq!(job.finish(1), Ok(()));
        assert_eq!(fs::read(&destination).unwrap(), b"original");
        assert!(!fixture.root.join("existing/file.txt.farpane-part").exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_existing_target_rejects_replace_decisions_and_unsafe_entries() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let destination = fixture.root.join("replace.txt");
        HostStorageFixture::write_private(&destination, b"keep");
        let existing_modified = fs::metadata(&destination)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-existing-replace-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            64,
            "replace.txt",
            0,
            vec![NativeHostWriteEntry::new(
                String::new(),
                4,
                existing_modified,
            )],
            4,
            true,
        ) else {
            panic!("replace-target job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 4, existing_modified, false),
            Ok(NativeHostWriteDigestDecision::ExistingTarget {
                file_size: 4,
                last_modified: existing_modified,
                is_identical: true,
            })
        );
        assert_eq!(
            job.confirm_existing_target_decision(
                0,
                NativeHostExistingTargetDecision::Replace { offset: 0 },
            ),
            Err(NativeHostWriteJobError::ExistingTargetReplacementUnsupported)
        );
        job.abort();
        assert_eq!(fs::read(&destination).unwrap(), b"keep");

        let unsafe_target = fixture.root.join("unsafe.txt");
        HostStorageFixture::write_private(&unsafe_target, b"unsafe");
        fs::set_permissions(&unsafe_target, fs::Permissions::from_mode(0o644)).unwrap();
        let NativeHostWriteJobAdmission::Admitted(mut unsafe_job) =
            native_host_begin_new_file_write_job(
                65,
                "unsafe.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 6, 101)],
                6,
                true,
            )
        else {
            panic!("unsafe-target job must be admitted before descriptor inspection");
        };
        assert_eq!(
            unsafe_job.confirm_file_digest(0, 6, 101, false),
            Err(NativeHostWriteJobError::ExistingTargetUnsafe)
        );
        unsafe_job.abort();
        assert_eq!(fs::read(&unsafe_target).unwrap(), b"unsafe");
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_existing_target_skip_preserves_multifile_accounting() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let batch = fixture.root.join("batch");
        fs::create_dir(&batch).expect("create batch directory");
        fs::set_permissions(&batch, fs::Permissions::from_mode(0o700))
            .expect("secure batch directory");
        HostStorageFixture::write_private(&batch.join("keep.txt"), b"keep");
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-existing-multifile-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            66,
            "batch",
            0,
            vec![
                NativeHostWriteEntry::new("new.txt".to_string(), 3, 102),
                NativeHostWriteEntry::new("keep.txt".to_string(), 4, 103),
            ],
            7,
            true,
        ) else {
            panic!("multi-file existing-target job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 3, 102, false),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(job.write_block(0, b"new", false), Ok(()));
        assert!(matches!(
            job.confirm_file_digest(1, 4, 103, false),
            Ok(NativeHostWriteDigestDecision::ExistingTarget { .. })
        ));
        assert_eq!(
            job.confirm_existing_target_decision(1, NativeHostExistingTargetDecision::Skip),
            Ok(())
        );
        assert_eq!(job.finish(2), Ok(()));
        assert_eq!(fs::read(batch.join("new.txt")).unwrap(), b"new");
        assert_eq!(fs::read(batch.join("keep.txt")).unwrap(), b"keep");
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_write_job_reserves_staging_path_until_drop() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-resume-reservation-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(first) = native_host_begin_new_file_write_job(
            60,
            "reserved/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 4, 16)],
            4,
            true,
        ) else {
            panic!("first reserved job must be admitted");
        };
        assert!(matches!(
            native_host_begin_new_file_write_job(
                61,
                "reserved/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 16)],
                4,
                true,
            ),
            NativeHostWriteJobAdmission::Rejected(NativeHostWriteJobError::DuplicateDestination)
        ));
        drop(first);
        assert!(matches!(
            native_host_begin_new_file_write_job(
                62,
                "reserved/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 16)],
                4,
                true,
            ),
            NativeHostWriteJobAdmission::Admitted(_)
        ));
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_resume_rejects_tampered_or_mismatched_checkpoint() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-resume-tamper-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut first) = native_host_begin_new_file_write_job(
            53,
            "tamper/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 6, 11)],
            6,
            true,
        ) else {
            panic!("tamper seed job must be admitted");
        };
        assert_eq!(
            first.confirm_file_digest(0, 6, 11, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(first.write_block(0, b"abc", false), Ok(()));
        drop(first);
        let staging = fixture.root.join("tamper/file.txt.farpane-part");
        let mut tampered = fs::OpenOptions::new()
            .write(true)
            .open(&staging)
            .expect("open staging for tamper fixture");
        std::io::Seek::seek(&mut tampered, std::io::SeekFrom::Start(0))
            .expect("seek tamper fixture");
        std::io::Write::write_all(&mut tampered, b"x").expect("tamper staged prefix");
        tampered.sync_all().expect("sync tamper fixture");
        drop(tampered);

        let NativeHostWriteJobAdmission::Admitted(mut tampered_resume) =
            native_host_begin_new_file_write_job(
                54,
                "tamper/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 6, 11)],
                6,
                true,
            )
        else {
            panic!("tampered resume job must be admitted");
        };
        assert_eq!(
            tampered_resume.confirm_file_digest(0, 6, 11, true),
            Err(NativeHostWriteJobError::ResumeStateInvalid)
        );
        assert!(!staging.exists());

        let NativeHostWriteJobAdmission::Admitted(mut mismatch_seed) =
            native_host_begin_new_file_write_job(
                55,
                "mismatch/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 12)],
                4,
                true,
            )
        else {
            panic!("mismatch seed job must be admitted");
        };
        assert_eq!(
            mismatch_seed.confirm_file_digest(0, 4, 12, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(mismatch_seed.write_block(0, b"ab", false), Ok(()));
        drop(mismatch_seed);
        let NativeHostWriteJobAdmission::Admitted(mut mismatch_resume) =
            native_host_begin_new_file_write_job(
                56,
                "mismatch/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 13)],
                4,
                true,
            )
        else {
            panic!("mismatch resume job must be admitted");
        };
        assert_eq!(
            mismatch_resume.confirm_file_digest(0, 4, 13, true),
            Err(NativeHostWriteJobError::ResumeStateInvalid)
        );
        assert!(!fixture.root.join("mismatch/file.txt.farpane-part").exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_resume_abort_removes_checkpointed_staging() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-resume-abort-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            57,
            "abort/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 4, 14)],
            4,
            true,
        ) else {
            panic!("abort job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 4, 14, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(job.write_block(0, b"ab", false), Ok(()));
        job.abort();
        assert!(!fixture.root.join("abort/file.txt.farpane-part").exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_resume_rejects_after_unbind() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-resume-unbind-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut first) = native_host_begin_new_file_write_job(
            58,
            "resume-unbind/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 4, 15)],
            4,
            true,
        ) else {
            panic!("resume unbind seed must be admitted");
        };
        assert_eq!(
            first.confirm_file_digest(0, 4, 15, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(first.write_block(0, b"ab", false), Ok(()));
        drop(first);

        let NativeHostWriteJobAdmission::Admitted(mut resumed) =
            native_host_begin_new_file_write_job(
                59,
                "resume-unbind/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 15)],
                4,
                true,
            )
        else {
            panic!("resume unbind job must be admitted");
        };
        unbind_media_host();
        assert_eq!(
            resumed.confirm_file_digest(0, 4, 15, true),
            Err(NativeHostWriteJobError::Unavailable)
        );
        resumed.abort();
        assert!(fixture
            .root
            .join("resume-unbind/file.txt.farpane-part")
            .exists());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_read_lists_virtual_root_recursive_files_and_empty_directories() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(&receive_root)
                .expect("open read owner"),
        );
        owner
            .create_directory(Path::new("folder"))
            .expect("create folder");
        owner
            .create_directory(Path::new("empty"))
            .expect("create empty folder");
        let mut file = owner
            .create_new_file(Path::new("folder/item.txt"))
            .expect("create read file");
        file.write_all(b"payload").expect("write read file");
        drop(file);
        let mut host = ready_test_host("native-read-list-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostFileReadOutcome::Succeeded((path, entries)) =
            native_host_list_directory("/", false)
        else {
            panic!("virtual root listing must succeed");
        };
        assert_eq!(path, "/");
        assert_eq!(
            entries
                .iter()
                .map(|entry| (entry.name(), entry.kind()))
                .collect::<Vec<_>>(),
            vec![
                ("empty", NativeHostReadEntryKind::Directory),
                ("folder", NativeHostReadEntryKind::Directory),
            ]
        );

        let NativeHostFileReadOutcome::Succeeded((path, entries)) =
            native_host_list_files_recursive("/folder", false)
        else {
            panic!("recursive file listing must succeed");
        };
        assert_eq!(path, "/folder");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name(), "item.txt");
        assert_eq!(entries[0].kind(), NativeHostReadEntryKind::File);
        assert_eq!(entries[0].size(), 7);

        let NativeHostFileReadOutcome::Succeeded((path, empty_directories)) =
            native_host_list_empty_directories("/", false)
        else {
            panic!("empty-directory listing must succeed");
        };
        assert_eq!(path, "/");
        assert_eq!(empty_directories, vec!["/empty"]);
        assert!(matches!(
            native_host_list_directory("/../escape", false),
            NativeHostFileReadOutcome::Rejected(NativeHostReadJobError::InvalidPath)
        ));
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_read_job_requires_confirmation_and_streams_exact_bounded_suffix() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(&receive_root)
                .expect("open read owner"),
        );
        let payload = vec![b'A'; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES + 37];
        let mut file = owner
            .create_new_file(Path::new("payload.bin"))
            .expect("create payload");
        file.write_all(&payload).expect("write payload");
        drop(file);
        let mut host = ready_test_host("native-read-job-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostReadJobAdmission::Admitted(mut job) =
            native_host_begin_read_job(81, "/payload.bin", 0, false, true)
        else {
            panic!("read job must be admitted");
        };
        assert_eq!(job.id(), 81);
        assert_eq!(job.wire_path(), "/payload.bin");
        assert_eq!(job.entries().len(), 1);
        assert!(matches!(
            job.poll(),
            Ok(NativeHostReadJobStep::Digest {
                file_num: 0,
                file_size,
                ..
            }) if file_size == payload.len() as u64
        ));
        assert_eq!(
            job.poll(),
            Ok(NativeHostReadJobStep::WaitingForConfirmation)
        );
        assert_eq!(
            job.confirm(
                0,
                NativeHostReadConfirmation::ContinueAt { offset: u32::MAX },
            ),
            Err(NativeHostReadJobError::OffsetOutOfRange)
        );
        job.confirm(0, NativeHostReadConfirmation::ContinueAt { offset: 7 })
            .expect("confirm bounded resume offset");

        let mut received = Vec::new();
        loop {
            match job.poll().expect("poll read job") {
                NativeHostReadJobStep::Block {
                    file_num,
                    data,
                    compressed,
                } => {
                    assert_eq!(file_num, 0);
                    let data = if compressed {
                        hbb_common::compress::decompress_with_limit(
                            &data,
                            hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES,
                        )
                        .expect("decode bounded block")
                    } else {
                        data
                    };
                    assert!(data.len() <= hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES);
                    received.extend_from_slice(&data);
                }
                NativeHostReadJobStep::Done { file_num } => {
                    assert_eq!(file_num, 1);
                    break;
                }
                other => panic!("unexpected read step: {other:?}"),
            }
        }
        assert_eq!(received, payload[7..]);
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_read_job_skip_snapshot_replacement_and_unbind_fail_closed() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(&receive_root)
                .expect("open read owner"),
        );
        owner
            .create_directory(Path::new("folder"))
            .expect("create folder");
        for (name, bytes) in [("a.txt", b"aaa".as_slice()), ("b.txt", b"bbb".as_slice())] {
            let mut file = owner
                .create_new_file(Path::new(&format!("folder/{name}")))
                .expect("create read fixture");
            file.write_all(bytes).expect("write read fixture");
        }
        let mut host = ready_test_host("native-read-fail-closed-test");
        host.file_service_owner = Some(owner.clone());
        bind_media_host(&host);

        let NativeHostReadJobAdmission::Admitted(mut job) =
            native_host_begin_read_job(82, "/folder", 0, false, true)
        else {
            panic!("multi-file read job must be admitted");
        };
        assert!(matches!(
            job.poll(),
            Ok(NativeHostReadJobStep::Digest { file_num: 0, .. })
        ));
        job.confirm(0, NativeHostReadConfirmation::Skip)
            .expect("skip first file");
        assert!(matches!(
            job.poll(),
            Ok(NativeHostReadJobStep::Digest { file_num: 1, .. })
        ));
        owner
            .rename_entry(Path::new("folder/b.txt"), Path::new("folder/b-old.txt"))
            .expect("replace snapshotted file");
        let mut replacement = owner
            .create_new_file(Path::new("folder/b.txt"))
            .expect("create replacement");
        replacement.write_all(b"bbb").expect("write replacement");
        drop(replacement);
        assert_eq!(
            job.confirm(1, NativeHostReadConfirmation::ContinueAt { offset: 0 },),
            Err(NativeHostReadJobError::SnapshotChanged)
        );

        let NativeHostReadJobAdmission::Admitted(mut unbound) =
            native_host_begin_read_job(83, "/folder/b.txt", 0, false, false)
        else {
            panic!("unbind read job must be admitted");
        };
        unbind_media_host();
        assert_eq!(unbound.poll(), Err(NativeHostReadJobError::Unavailable));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_file_mutation_adapter_is_relative_bounded_and_no_replace() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
            receive_root.as_path(),
        )
        .expect("open private receive root");

        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::CreateDirectory { path: "folder" },
        )
        .is_ok());
        drop(
            owner
                .create_new_file(Path::new("folder/source.txt"))
                .expect("create private source"),
        );
        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::Rename {
                path: "folder/source.txt",
                new_name: "renamed.txt",
            },
        )
        .is_ok());
        assert!(fixture.root.join("folder/renamed.txt").is_file());

        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::Rename {
                path: "folder/renamed.txt",
                new_name: "../escape.txt",
            },
        )
        .is_err());
        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::RemoveDirectory {
                path: "folder",
                recursive: true,
            },
        )
        .is_err());
        assert!(fixture.root.join("folder/renamed.txt").is_file());

        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::RemoveFile {
                path: "folder/renamed.txt",
            },
        )
        .is_ok());
        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::RemoveDirectory {
                path: "folder",
                recursive: false,
            },
        )
        .is_ok());

        let mut host = ready_test_host("file-mutation-test");
        host.file_service_owner = Some(Arc::new(owner));
        bind_media_host(&host);
        assert_eq!(
            native_host_dispatch_file_mutation(NativeHostFileMutation::CreateDirectory {
                path: "bound",
            }),
            NativeHostFileMutationOutcome::Succeeded
        );
        assert_eq!(
            native_host_dispatch_file_mutation(NativeHostFileMutation::CreateDirectory {
                path: "../escape",
            }),
            NativeHostFileMutationOutcome::Rejected
        );
        MEDIA_BROKER.lock().unwrap().file_service_owner = None;
        assert_eq!(
            native_host_dispatch_file_mutation(NativeHostFileMutation::CreateDirectory {
                path: "unavailable",
            }),
            NativeHostFileMutationOutcome::Unavailable
        );
        unbind_media_host();
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_accepts_explicit_audio_opt_in_only() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "";
        let server_public_key = "synthetic-public-key";
        let (identity, options) = fixture.write_startup_documents(
            rendezvous_server,
            relay_server,
            server_public_key,
            true,
            false,
        );

        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                true,
                "",
                false,
            ),
            Ok(())
        );
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                false,
                "",
                false,
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_accepts_explicit_file_transfer_opt_in_only() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "";
        let server_public_key = "synthetic-public-key";
        let (identity, options) = fixture.write_startup_documents(
            rendezvous_server,
            relay_server,
            server_public_key,
            false,
            true,
        );

        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                false,
                "",
                true,
            ),
            Ok(())
        );
        assert_eq!(
            verify_host_start_storage_paths(
                &fixture.identity,
                &fixture.options,
                rendezvous_server,
                relay_server,
                server_public_key,
                NativeClipboardTransferPolicy::default(),
                false,
                "",
                false,
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_password_storage_readback_accepts_exact_set_and_clear_without_mutation() {
        let fixture = HostStorageFixture::new();
        let storage = "synthetic-verifier";
        let salt = "synthetic-salt";
        let (identity, options) = fixture.write_password_documents(storage, salt);

        assert_eq!(
            verify_host_password_storage_paths(&fixture.identity, &fixture.options, storage, salt,),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);

        let (cleared_identity, cleared_options) = fixture.write_password_documents("", salt);
        assert_eq!(
            verify_host_password_storage_paths(&fixture.identity, &fixture.options, "", salt,),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), cleared_identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), cleared_options);
    }

    #[cfg(unix)]
    #[test]
    fn host_password_storage_readback_rejects_stale_verifier_or_salt_without_mutation() {
        let fixture = HostStorageFixture::new();
        let (identity, options) =
            fixture.write_password_documents("persisted-verifier", "persisted-salt");

        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "new-verifier",
                "persisted-salt",
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "persisted-verifier",
                "new-salt",
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "",
                "persisted-salt",
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_password_storage_readback_rejects_wrong_typed_or_unknown_identity_fields() {
        let fixture = HostStorageFixture::new();
        let (_, options) = fixture.write_password_documents("persisted-verifier", "salt");
        let wrong_type = b"enc_id = \"opaque\"\npassword = 1\nsalt = \"salt\"\n";
        HostStorageFixture::write_private(&fixture.identity, wrong_type);
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "persisted-verifier",
                "salt",
            ),
            Err(HostStoragePreflightError::InvalidToml)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), wrong_type);

        let unknown = b"enc_id = \"opaque\"\npassword = \"persisted-verifier\"\nsalt = \"salt\"\nforeign = true\n";
        HostStorageFixture::write_private(&fixture.identity, unknown);
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "persisted-verifier",
                "salt",
            ),
            Err(HostStoragePreflightError::InvalidToml)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), unknown);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_preserves_malformed_documents() {
        let fixture = HostStorageFixture::new();
        let (valid_identity, _) = fixture.write_valid_documents();
        let malformed = b"not-toml = [";

        HostStorageFixture::write_private(&fixture.identity, malformed);
        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Err(HostStoragePreflightError::InvalidToml)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), malformed);

        HostStorageFixture::write_private(&fixture.identity, &valid_identity);
        HostStorageFixture::write_private(&fixture.options, malformed);
        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Err(HostStoragePreflightError::InvalidToml)
        );
        assert_eq!(fs::read(&fixture.options).unwrap(), malformed);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_rejects_unsafe_file_shapes() {
        let loose = HostStorageFixture::new();
        loose.write_valid_documents();
        fs::set_permissions(&loose.identity, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&loose.identity, &loose.options),
            Err(HostStoragePreflightError::UnsafeFile)
        );

        let linked = HostStorageFixture::new();
        let (_, options) = linked.write_valid_documents();
        fs::remove_file(&linked.identity).unwrap();
        let seed = linked.root.join("identity-seed.toml");
        HostStorageFixture::write_private(&seed, &options);
        fs::hard_link(&seed, &linked.identity).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&linked.identity, &linked.options),
            Err(HostStoragePreflightError::UnsafeFile)
        );

        let symbolic = HostStorageFixture::new();
        symbolic.write_valid_documents();
        let target = symbolic.root.join("identity-target.toml");
        HostStorageFixture::write_private(&target, b"id = \"safe\"\n");
        fs::remove_file(&symbolic.identity).unwrap();
        symlink(&target, &symbolic.identity).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&symbolic.identity, &symbolic.options),
            Err(HostStoragePreflightError::OpenFile)
        );

        let oversized = HostStorageFixture::new();
        oversized.write_valid_documents();
        HostStorageFixture::write_private(
            &oversized.identity,
            &vec![b'a'; MAX_HOST_CONFIG_BYTES + 1],
        );
        assert_eq!(
            preflight_host_storage_paths(&oversized.identity, &oversized.options),
            Err(HostStoragePreflightError::UnsafeFile)
        );

        let nonregular = HostStorageFixture::new();
        nonregular.write_valid_documents();
        fs::remove_file(&nonregular.identity).unwrap();
        fs::create_dir(&nonregular.identity).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&nonregular.identity, &nonregular.options),
            Err(HostStoragePreflightError::UnsafeFile)
        );
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_preflight_rejects_writable_directory() {
        let fixture = HostStorageFixture::new();
        fixture.write_valid_documents();
        fs::set_permissions(&fixture.root, fs::Permissions::from_mode(0o770)).unwrap();
        assert_eq!(
            preflight_host_storage_paths(&fixture.identity, &fixture.options),
            Err(HostStoragePreflightError::UnsafeDirectory)
        );
    }

    struct BuiltinSettingGuard {
        key: &'static str,
        previous: Option<String>,
    }

    impl BuiltinSettingGuard {
        fn set(key: &'static str, value: &str) -> Self {
            let previous = config::BUILTIN_SETTINGS
                .write()
                .unwrap()
                .insert(key.to_owned(), value.to_owned());
            Self { key, previous }
        }
    }

    impl Drop for BuiltinSettingGuard {
        fn drop(&mut self) {
            let mut settings = config::BUILTIN_SETTINGS.write().unwrap();
            if let Some(previous) = &self.previous {
                settings.insert(self.key.to_owned(), previous.clone());
            } else {
                settings.remove(self.key);
            }
        }
    }

    unsafe extern "C" fn collect_test_event(
        context: *mut c_void,
        json: *const c_char,
        length: usize,
    ) {
        if context.is_null() || json.is_null() || length == 0 {
            return;
        }
        let sink = &*(context as *const Mutex<Vec<Value>>);
        let bytes = std::slice::from_raw_parts(json as *const u8, length);
        if let Ok(event) = serde_json::from_slice(bytes) {
            sink.lock().unwrap().push(event);
        }
    }

    struct BoundMediaTestGuard;

    impl Drop for BoundMediaTestGuard {
        fn drop(&mut self) {
            unbind_media_host();
        }
    }

    fn ready_test_host(instance_id: &str) -> RdnHost {
        RdnHost {
            instance_id: instance_id.to_owned(),
            state: RdnHostState::Ready,
            local_id: "test-local-id".to_owned(),
            registration_status: "ready",
            recovery_epoch: 0,
            recovery_state: HostRecoveryState::Running,
            network_path_generation: 0,
            reveal_temporary_password: false,
            last_error: None,
            event_id: Arc::new(AtomicU64::new(0)),
            callbacks: RdnHostCallbacks {
                abi_version: HOST_ABI_VERSION,
                on_event: None,
                context: std::ptr::null_mut(),
            },
            rendezvous_server: String::new(),
            relay_server: String::new(),
            server_public_key: String::new(),
            clipboard_transfer_policy: NativeClipboardTransferPolicy::default(),
            audio_enabled: false,
            audio_input_device: String::new(),
            file_transfer_enabled: false,
            #[cfg(target_os = "macos")]
            file_service_owner: None,
            runtime: None,
        }
    }

    #[test]
    fn native_host_session_availability_tuple_is_exact_and_fail_closed() {
        assert_eq!(
            native_host_session_availability_payload(true),
            ("available", None)
        );
        assert_eq!(
            native_host_session_availability_payload(false),
            ("limited", Some("sessionUnavailable"))
        );

        let mut host = ready_test_host("session-availability-host");
        let snapshot = host.snapshot_json();
        match snapshot["sessionAvailability"].as_str() {
            Some("available") => assert!(snapshot["sessionUnavailableReason"].is_null()),
            Some("limited") => {
                assert_eq!(snapshot["sessionUnavailableReason"], "sessionUnavailable")
            }
            value => panic!("unexpected session availability: {value:?}"),
        }
    }

    #[test]
    fn network_path_recovery_admission_is_exact_generation_and_fail_closed() {
        assert!(!is_next_network_path_generation(0, 0));
        assert!(is_next_network_path_generation(0, 1));
        assert!(!is_next_network_path_generation(7, 7));
        assert!(!is_next_network_path_generation(7, 9));
        assert!(!is_next_network_path_generation(u64::MAX, 0));
        assert!(!is_next_network_path_generation(u64::MAX, u64::MAX));

        let mut host = ready_test_host("network-generation-host");
        host.network_path_generation = 7;
        host.runtime = Some(HostRuntime {
            stop_requested: Arc::new(AtomicBool::new(false)),
            finished: Arc::new(AtomicBool::new(false)),
            thread: None,
        });
        assert_eq!(
            unsafe { rdn_host_recover_network_path(std::ptr::null_mut(), 8) },
            RDN_HOST_ERR_INVALID_ARG
        );
        for generation in [0, 7, 9, u64::MAX] {
            assert_eq!(
                unsafe { rdn_host_recover_network_path(&mut host, generation) },
                RDN_HOST_ERR_STALE_GENERATION
            );
            assert_eq!(host.network_path_generation, 7);
            assert_eq!(state_name(host.state), "ready");
            assert_eq!(host.registration_status, "ready");
            assert!(host.runtime.is_some());
        }

        host.recovery_state = HostRecoveryState::Suspended;
        host.state = RdnHostState::Starting;
        assert_eq!(
            unsafe { rdn_host_recover_network_path(&mut host, 8) },
            RDN_HOST_ERR_BAD_STATE
        );
        assert_eq!(host.network_path_generation, 7);
        assert!(host.runtime.is_some());
    }

    #[test]
    fn network_path_recovery_failure_is_terminal_but_not_sleep_failure() {
        let mut host = ready_test_host("network-failure-host");
        assert_eq!(
            fail_host_network_recovery(
                &mut host,
                "registration.runtimeRestartFailedDuringNetworkRecovery",
            ),
            RDN_HOST_ERR_INTERNAL
        );
        assert_eq!(state_name(host.state), "error");
        assert_eq!(host.registration_status, "degraded");
        assert_eq!(host.recovery_state, HostRecoveryState::Running);
        assert_eq!(host.recovery_epoch, 0);
        assert_eq!(host.network_path_generation, 0);
        assert_eq!(
            host.last_error.as_deref(),
            Some("registration.runtimeRestartFailedDuringNetworkRecovery")
        );
    }

    #[test]
    fn permanent_password_change_disabled_wipes_secret_and_propagates_clear_error() {
        let _lock = PASSWORD_COMMAND_TEST_LOCK.lock().unwrap();
        let _setting =
            BuiltinSettingGuard::set(config::keys::OPTION_DISABLE_CHANGE_PERMANENT_PASSWORD, "Y");
        let events = Mutex::new(Vec::new());
        let mut host = ready_test_host("password-disabled-host");
        host.callbacks = RdnHostCallbacks {
            abi_version: HOST_ABI_VERSION,
            on_event: Some(collect_test_event),
            context: &events as *const Mutex<Vec<Value>> as *mut c_void,
        };

        let command_id = CString::new("password-disabled").unwrap();
        let mut secret = b"valid-password".to_vec();
        let result = unsafe {
            rdn_host_set_permanent_password(
                &mut host,
                command_id.as_ptr(),
                secret.as_mut_ptr(),
                secret.len(),
            )
        };
        assert_eq!(result, RDN_HOST_ERR_CHANGE_DISABLED);
        assert!(secret.iter().all(|byte| *byte == 0));

        assert_eq!(
            handle_command(
                &mut host,
                "clear-disabled",
                "clearPermanentPassword",
                &json!({
                    "commandId": "clear-disabled",
                    "name": "clearPermanentPassword",
                }),
            ),
            RDN_HOST_ERR_CHANGE_DISABLED
        );
        let encoded = serde_json::to_string(&*events.lock().unwrap()).unwrap();
        assert!(encoded.contains("permanent-password-change-disabled"));
        assert!(!encoded.contains("valid-password"));
    }

    fn pending_approval_fixture(
        connection_id: &str,
        core_connection_id: i32,
        deadline: Instant,
    ) -> (
        PendingNativeApproval,
        tokio::sync::mpsc::UnboundedReceiver<crate::ipc::Data>,
    ) {
        let (decision_sender, decision_receiver) = tokio::sync::mpsc::unbounded_channel();
        (
            PendingNativeApproval {
                request: NativeApprovalRequest {
                    connection_id: connection_id.to_owned(),
                    core_connection_id,
                    remote_id: "remote-id".to_owned(),
                    remote_name: "Remote Mac".to_owned(),
                    remote_platform: "macOS".to_owned(),
                    requested_at_ms: 1_000,
                    expires_at_ms: 31_000,
                    requested_capabilities: vec![
                        "viewDisplay".to_owned(),
                        "controlKeyboardMouse".to_owned(),
                    ],
                },
                deadline,
                decision_sender,
            },
            decision_receiver,
        )
    }

    #[test]
    fn native_approval_broker_is_single_final_and_expiry_safe() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let base = Instant::now();
        let deadline = base + Duration::from_secs(30);
        let mut broker = NativeApprovalBroker::default();

        let (first, mut first_receiver) = pending_approval_fixture("host:1", 1, deadline);
        assert_eq!(broker.begin(first), NativeApprovalStartResult::Accepted);
        let (duplicate, _duplicate_receiver) = pending_approval_fixture("host:1", 1, deadline);
        assert_eq!(broker.begin(duplicate), NativeApprovalStartResult::Existing);
        let (busy, _busy_receiver) = pending_approval_fixture("host:2", 2, deadline);
        assert_eq!(broker.begin(busy), NativeApprovalStartResult::Busy);

        let (result, completion) = broker.resolve(
            "host:1",
            NativeApprovalDecision::Approve,
            base + Duration::from_secs(29),
        );
        assert_eq!(result, NativeApprovalResolveResult::Approved);
        let completion = completion.unwrap();
        assert_eq!(completion.status, NativeApprovalFinalStatus::Approved);
        emit_native_approval_completion(&completion);
        assert!(matches!(
            first_receiver.try_recv(),
            Ok(crate::ipc::Data::Authorize)
        ));
        let (result, completion) = broker.resolve(
            "host:1",
            NativeApprovalDecision::Reject,
            base + Duration::from_secs(29),
        );
        assert_eq!(result, NativeApprovalResolveResult::AlreadyFinal);
        assert!(completion.is_none());

        let second_deadline = base + Duration::from_secs(60);
        let (second, mut second_receiver) = pending_approval_fixture("host:2", 2, second_deadline);
        assert_eq!(broker.begin(second), NativeApprovalStartResult::Accepted);
        assert!(broker
            .expire("host:2", second_deadline - Duration::from_millis(1))
            .is_none());
        let completion = broker.expire("host:2", second_deadline).unwrap();
        assert_eq!(completion.status, NativeApprovalFinalStatus::Expired);
        emit_native_approval_completion(&completion);
        assert!(matches!(
            second_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));
        let (result, completion) =
            broker.resolve("host:2", NativeApprovalDecision::Approve, second_deadline);
        assert_eq!(result, NativeApprovalResolveResult::AlreadyFinal);
        assert!(completion.is_none());

        let (third, mut third_receiver) =
            pending_approval_fixture("host:3", 3, base + Duration::from_secs(90));
        assert_eq!(broker.begin(third), NativeApprovalStartResult::Accepted);
        let cancelled = broker.cancel(3).unwrap();
        assert_eq!(cancelled.status, NativeApprovalFinalStatus::Cancelled);
        assert!(third_receiver.try_recv().is_err());
        let (finalized, _finalized_receiver) =
            pending_approval_fixture("host:3", 3, base + Duration::from_secs(90));
        assert_eq!(
            broker.begin(finalized),
            NativeApprovalStartResult::Finalized
        );
    }

    fn active_session_fixture(
        connection_id: &str,
        core_connection_id: i32,
        initial_capabilities: NativeSessionCapabilities,
        active_capabilities: NativeSessionCapabilities,
    ) -> NativeActiveSession {
        let (command_sender, _command_receiver) = tokio::sync::mpsc::unbounded_channel();
        NativeActiveSession {
            snapshot: NativeSessionSnapshot {
                connection_id: connection_id.to_owned(),
                core_connection_id,
                remote_id: "remote-id".to_owned(),
                remote_name: "Remote Mac".to_owned(),
                remote_platform: "macOS".to_owned(),
                started_at_ms: 1_000,
                initial_capabilities,
                active_capabilities,
                input_availability: if active_capabilities.control_keyboard_mouse {
                    NativeSessionInputAvailability::available()
                } else {
                    NativeSessionInputAvailability::disabled(
                        NativeSessionInputUnavailableReason::LocalPolicyDisabled,
                    )
                },
            },
            command_sender,
            disconnect_requested: false,
        }
    }

    #[test]
    fn native_clipboard_policy_represents_read_and_write_independently() {
        let disabled = NativeClipboardPolicy::new(false, false);
        let read_only = NativeClipboardPolicy::new(true, false);
        let write_only = NativeClipboardPolicy::new(false, true);
        let bidirectional = NativeClipboardPolicy::new(true, true);

        for (policy, expected_names) in [
            (disabled, vec!["viewDisplay"]),
            (read_only, vec!["viewDisplay", "readClipboard"]),
            (write_only, vec!["viewDisplay", "writeClipboard"]),
            (
                bidirectional,
                vec!["viewDisplay", "readClipboard", "writeClipboard"],
            ),
        ] {
            assert_eq!(
                NativeSessionCapabilities::with_clipboard_policy(false, policy, false).names(),
                expected_names
            );
        }

        assert!(disabled.is_subset_of(read_only));
        assert!(read_only.is_subset_of(bidirectional));
        assert!(write_only.is_subset_of(bidirectional));
        assert!(!read_only.is_subset_of(write_only));
        assert!(!write_only.is_subset_of(read_only));
        assert_eq!(
            NativeSessionCapabilities::new(false, true, false),
            NativeSessionCapabilities::with_clipboard_policy(false, bidirectional, false,)
        );
    }

    fn clipboard_fixture(content: Vec<u8>, compress: bool, format: ClipboardFormat) -> Clipboard {
        Clipboard {
            compress,
            content: content.into(),
            format: format.into(),
            ..Default::default()
        }
    }

    #[test]
    fn native_clipboard_data_plane_gates_read_and_write_independently() {
        let text = clipboard_fixture(b"small text".to_vec(), false, ClipboardFormat::Text);
        let clipboards = std::slice::from_ref(&text);
        let read_only = NativeClipboardPolicy::new(true, false);
        let write_only = NativeClipboardPolicy::new(false, true);
        let small_read_only =
            NativeClipboardTransferPolicy::new(read_only, NativeClipboardPolicy::default());
        let small_write_only =
            NativeClipboardTransferPolicy::new(write_only, NativeClipboardPolicy::default());

        let non_clipboard_message = Message::new();
        assert!(matches!(
            native_host_prepare_outgoing_clipboard_message(
                &non_clipboard_message,
                small_read_only,
                read_only,
            ),
            NativeHostOutgoingClipboardDecision::NotClipboard
        ));
        let mut clipboard_message = Message::new();
        clipboard_message.set_clipboard(text.clone());
        assert!(matches!(
            native_host_prepare_outgoing_clipboard_message(
                &clipboard_message,
                small_read_only,
                read_only,
            ),
            NativeHostOutgoingClipboardDecision::Send(_)
        ));
        assert!(matches!(
            native_host_prepare_outgoing_clipboard_message(
                &clipboard_message,
                small_read_only,
                write_only,
            ),
            NativeHostOutgoingClipboardDecision::Reject
        ));

        assert!(native_host_prepare_incoming_clipboard_entries(
            clipboards,
            small_write_only,
            write_only,
        )
        .is_some());
        assert!(native_host_prepare_incoming_clipboard_entries(
            clipboards,
            small_write_only,
            read_only,
        )
        .is_none());
        assert!(native_host_prepare_incoming_clipboard_entries(
            &[text.clone(), text],
            small_write_only,
            write_only,
        )
        .is_none());
    }

    #[test]
    fn native_clipboard_data_plane_accepts_only_bounded_utf8_plain_text() {
        let at_limit = vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES];
        assert!(native_host_small_text_clipboard(&clipboard_fixture(
            at_limit.clone(),
            false,
            ClipboardFormat::Text,
        )));
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1],
            false,
            ClipboardFormat::Text,
        )));

        let compressed_at_limit = hbb_common::compress::compress(&at_limit);
        assert!(native_host_small_text_clipboard(&clipboard_fixture(
            compressed_at_limit,
            true,
            ClipboardFormat::Text,
        )));
        let compressed_over_limit =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1]);
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            compressed_over_limit,
            true,
            ClipboardFormat::Text,
        )));

        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            vec![0xff],
            false,
            ClipboardFormat::Text,
        )));
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            b"before\0after".to_vec(),
            false,
            ClipboardFormat::Text,
        )));
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            b"<b>rich</b>".to_vec(),
            false,
            ClipboardFormat::Html,
        )));
    }

    #[test]
    fn native_clipboard_payload_taxonomy_separates_inline_text_from_rich_transfer() {
        assert_eq!(
            native_host_clipboard_payload_disposition(&clipboard_fixture(
                b"small text".to_vec(),
                false,
                ClipboardFormat::Text,
            )),
            NativeClipboardPayloadDisposition::InlineSmallText
        );

        for format in [ClipboardFormat::Rtf, ClipboardFormat::Html] {
            let rich = clipboard_fixture(b"rich payload".to_vec(), false, format);
            assert_eq!(
                native_host_clipboard_payload_disposition(&rich),
                NativeClipboardPayloadDisposition::IndependentTransferRequired
            );
            let mut message = Message::new();
            message.set_clipboard(rich);
            assert!(matches!(
                native_host_prepare_outgoing_clipboard_message(
                    &message,
                    NativeClipboardTransferPolicy::new(
                        NativeClipboardPolicy::new(true, true),
                        NativeClipboardPolicy::default(),
                    ),
                    NativeClipboardPolicy::new(true, true),
                ),
                NativeHostOutgoingClipboardDecision::Reject
            ));
        }

        let mut rgba = clipboard_fixture(vec![0, 0, 0, 255], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        assert_eq!(
            native_host_clipboard_payload_disposition(&rgba),
            NativeClipboardPayloadDisposition::IndependentTransferRequired
        );
        let mut rgba_message = Message::new();
        rgba_message.set_clipboard(rgba);
        assert!(matches!(
            native_host_prepare_outgoing_clipboard_message(
                &rgba_message,
                NativeClipboardTransferPolicy::new(
                    NativeClipboardPolicy::default(),
                    NativeClipboardPolicy::new(true, true),
                ),
                NativeClipboardPolicy::new(true, true),
            ),
            NativeHostOutgoingClipboardDecision::Reject
        ));

        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[0, 0, 0, 255]).unwrap();
        for image in [
            clipboard_fixture(png, false, ClipboardFormat::ImagePng),
            clipboard_fixture(
                b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".to_vec(),
                false,
                ClipboardFormat::ImageSvg,
            ),
        ] {
            assert_eq!(
                native_host_clipboard_payload_disposition(&image),
                NativeClipboardPayloadDisposition::IndependentTransferRequired
            );
            let mut message = Message::new();
            message.set_clipboard(image);
            assert!(matches!(
                native_host_prepare_outgoing_clipboard_message(
                    &message,
                    NativeClipboardTransferPolicy::new(
                        NativeClipboardPolicy::default(),
                        NativeClipboardPolicy::new(true, true),
                    ),
                    NativeClipboardPolicy::new(true, true),
                ),
                NativeHostOutgoingClipboardDecision::Reject
            ));
        }

        let mut malformed_html =
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        malformed_html.width = 1;
        assert_eq!(
            native_host_clipboard_payload_disposition(&malformed_html),
            NativeClipboardPayloadDisposition::Reject
        );

        let mut special = clipboard_fixture(b"untrusted".to_vec(), false, ClipboardFormat::Special);
        special.special_name = "untrusted.remote.uti".to_owned();
        assert_eq!(
            native_host_clipboard_payload_disposition(&special),
            NativeClipboardPayloadDisposition::Reject
        );

        let mut unknown = clipboard_fixture(b"unknown".to_vec(), false, ClipboardFormat::Text);
        unknown.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert_eq!(
            native_host_clipboard_payload_disposition(&unknown),
            NativeClipboardPayloadDisposition::Reject
        );
    }

    #[test]
    fn native_rich_text_transfer_envelope_is_owned_bounded_and_strict() {
        for (format, expected) in [
            (ClipboardFormat::Rtf, NativeRichTextFormat::Rtf),
            (ClipboardFormat::Html, NativeRichTextFormat::Html),
        ] {
            let mut source = clipboard_fixture(b"rich text".to_vec(), false, format);
            let envelope = NativeRichTextTransferEnvelope::from_clipboard(&source).unwrap();
            source.content.clear();
            assert_eq!(envelope.format, expected);
            assert_eq!(envelope.payload, "rich text");
        }

        let at_limit = vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES];
        let envelope = NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
            at_limit.clone(),
            false,
            ClipboardFormat::Rtf,
        ))
        .unwrap();
        assert_eq!(envelope.payload.len(), MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES);

        let compressed_at_limit = hbb_common::compress::compress(&at_limit);
        let envelope = NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
            compressed_at_limit,
            true,
            ClipboardFormat::Html,
        ))
        .unwrap();
        assert_eq!(envelope.payload.len(), MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES);

        let compressed_over_limit =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES + 1]);
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                compressed_over_limit,
                true,
                ClipboardFormat::Rtf,
            ))
            .is_none()
        );
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES + 1],
                false,
                ClipboardFormat::Html,
            ))
            .is_none()
        );

        for content in [vec![0xff], b"before\0after".to_vec()] {
            assert!(
                NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                    content,
                    false,
                    ClipboardFormat::Html,
                ))
                .is_none()
            );
        }

        let mut wrong_metadata =
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        wrong_metadata.special_name = "public.html".to_owned();
        assert!(NativeRichTextTransferEnvelope::from_clipboard(&wrong_metadata).is_none());

        for (width, height) in [(1, 0), (0, 1)] {
            let mut wrong_dimensions =
                clipboard_fixture(b"{\\rtf1}".to_vec(), false, ClipboardFormat::Rtf);
            wrong_dimensions.width = width;
            wrong_dimensions.height = height;
            assert!(NativeRichTextTransferEnvelope::from_clipboard(&wrong_dimensions).is_none());
        }
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                Vec::new(),
                false,
                ClipboardFormat::Rtf,
            ))
            .is_none()
        );

        let mut unknown_format = clipboard_fixture(b"rich".to_vec(), false, ClipboardFormat::Rtf);
        unknown_format.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert!(NativeRichTextTransferEnvelope::from_clipboard(&unknown_format).is_none());
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                b"plain".to_vec(),
                false,
                ClipboardFormat::Text,
            ))
            .is_none()
        );
    }

    #[test]
    fn native_image_transfer_envelope_is_owned_bounded_and_format_strict() {
        let mut rgba = clipboard_fixture(vec![1, 2, 3, 255], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        let envelope = NativeImageTransferEnvelope::from_clipboard(&rgba).unwrap();
        assert_eq!(
            envelope.format,
            NativeImageFormat::Rgba {
                width: 1,
                height: 1,
            }
        );
        assert_eq!(envelope.payload, vec![1, 2, 3, 255]);
        rgba.content.clear();
        assert_eq!(envelope.payload, vec![1, 2, 3, 255]);

        let compressed_rgba = hbb_common::compress::compress(&[4, 5, 6, 255]);
        let mut rgba = clipboard_fixture(compressed_rgba, true, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        assert!(NativeImageTransferEnvelope::from_clipboard(&rgba).is_some());

        let mut wrong_rgba_length =
            clipboard_fixture(vec![1, 2, 3], false, ClipboardFormat::ImageRgba);
        wrong_rgba_length.width = 1;
        wrong_rgba_length.height = 1;
        assert!(NativeImageTransferEnvelope::from_clipboard(&wrong_rgba_length).is_none());

        let mut excessive_rgba = clipboard_fixture(vec![0; 4], false, ClipboardFormat::ImageRgba);
        excessive_rgba.width = MAX_CLIPBOARD_IMAGE_DIMENSION + 1;
        excessive_rgba.height = 1;
        assert!(NativeImageTransferEnvelope::from_clipboard(&excessive_rgba).is_none());
        excessive_rgba.width = MAX_CLIPBOARD_IMAGE_DIMENSION;
        excessive_rgba.height = MAX_CLIPBOARD_IMAGE_DIMENSION;
        assert!(NativeImageTransferEnvelope::from_clipboard(&excessive_rgba).is_none());

        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[7, 8, 9, 255]).unwrap();
        let envelope = NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
            png.clone(),
            false,
            ClipboardFormat::ImagePng,
        ))
        .unwrap();
        assert_eq!(
            envelope.format,
            NativeImageFormat::Png {
                width: 1,
                height: 1,
            }
        );
        assert_eq!(envelope.payload, png);

        let mut png_with_wire_dimensions =
            clipboard_fixture(png.clone(), false, ClipboardFormat::ImagePng);
        png_with_wire_dimensions.width = 1;
        assert!(NativeImageTransferEnvelope::from_clipboard(&png_with_wire_dimensions).is_none());
        assert!(
            NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                png[..24].to_vec(),
                false,
                ClipboardFormat::ImagePng,
            ))
            .is_none()
        );

        let mut compressed_png = clipboard_fixture(
            hbb_common::compress::compress(&png),
            true,
            ClipboardFormat::ImagePng,
        );
        assert!(NativeImageTransferEnvelope::from_clipboard(&compressed_png).is_none());
        compressed_png.compress = false;
        assert!(NativeImageTransferEnvelope::from_clipboard(&compressed_png).is_none());

        let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".to_vec();
        let envelope = NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
            hbb_common::compress::compress(&svg),
            true,
            ClipboardFormat::ImageSvg,
        ))
        .unwrap();
        assert_eq!(envelope.format, NativeImageFormat::Svg);
        assert_eq!(envelope.payload, svg);
        assert!(
            NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                b"<?xml version=\"1.0\"?><svg></svg>".to_vec(),
                false,
                ClipboardFormat::ImageSvg,
            ))
            .is_some()
        );

        for invalid_svg in [
            vec![0xff],
            b"before\0after".to_vec(),
            b"<html></html>".to_vec(),
            b"<svg ".to_vec(),
            b"<!DOCTYPE svg><svg></svg>".to_vec(),
        ] {
            assert!(
                NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                    invalid_svg,
                    false,
                    ClipboardFormat::ImageSvg,
                ))
                .is_none()
            );
        }
        assert!(
            NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                vec![b'a'; MAX_CLIPBOARD_SVG_UTF8_BYTES + 1],
                false,
                ClipboardFormat::ImageSvg,
            ))
            .is_none()
        );
        assert!(
            NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_SVG_UTF8_BYTES + 1]),
                true,
                ClipboardFormat::ImageSvg,
            ))
            .is_none()
        );

        let mut wrong_metadata = clipboard_fixture(png, false, ClipboardFormat::ImagePng);
        wrong_metadata.special_name = "public.png".to_owned();
        assert!(NativeImageTransferEnvelope::from_clipboard(&wrong_metadata).is_none());
        let mut unknown = clipboard_fixture(vec![1], false, ClipboardFormat::ImagePng);
        unknown.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert!(NativeImageTransferEnvelope::from_clipboard(&unknown).is_none());
    }

    #[test]
    fn native_rich_text_transfer_bundle_is_owned_atomic_and_canonical() {
        let compressed_html = hbb_common::compress::compress(b"<b>rich</b>");
        let mut source = vec![
            clipboard_fixture(compressed_html, true, ClipboardFormat::Html),
            clipboard_fixture(b"plain fallback".to_vec(), false, ClipboardFormat::Text),
            clipboard_fixture(b"{\\rtf1 rich}".to_vec(), false, ClipboardFormat::Rtf),
        ];
        let bundle = NativeRichTextTransferBundle::from_clipboards(&source).unwrap();
        source
            .iter_mut()
            .for_each(|clipboard| clipboard.content.clear());
        assert_eq!(bundle.plain_text.as_deref(), Some("plain fallback"));
        assert_eq!(bundle.rtf.as_deref(), Some("{\\rtf1 rich}"));
        assert_eq!(bundle.html.as_deref(), Some("<b>rich</b>"));

        let canonical = bundle.into_canonical_clipboards();
        assert_eq!(canonical.len(), 3);
        for (clipboard, format, payload) in [
            (
                &canonical[0],
                ClipboardFormat::Text,
                b"plain fallback".as_slice(),
            ),
            (
                &canonical[1],
                ClipboardFormat::Rtf,
                b"{\\rtf1 rich}".as_slice(),
            ),
            (
                &canonical[2],
                ClipboardFormat::Html,
                b"<b>rich</b>".as_slice(),
            ),
        ] {
            assert_eq!(clipboard.format.enum_value(), Ok(format));
            assert_eq!(clipboard.content.as_ref(), payload);
            assert!(!clipboard.compress);
            assert!(clipboard.special_name.is_empty());
            assert_eq!((clipboard.width, clipboard.height), (0, 0));
        }

        let plain = clipboard_fixture(b"plain".to_vec(), false, ClipboardFormat::Text);
        let html = clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        assert!(
            NativeRichTextTransferBundle::from_clipboards(std::slice::from_ref(&plain)).is_none()
        );
        assert!(NativeRichTextTransferBundle::from_clipboards(&[html.clone(), html]).is_none());
        assert!(
            NativeRichTextTransferBundle::from_clipboards(&[clipboard_fixture(
                b"image".to_vec(),
                false,
                ClipboardFormat::ImagePng
            ),])
            .is_none()
        );
    }

    #[test]
    fn native_host_rich_text_transport_requires_explicit_format_and_direction_policy() {
        let entries = vec![
            clipboard_fixture(b"plain fallback".to_vec(), false, ClipboardFormat::Text),
            clipboard_fixture(b"{\\rtf1 rich}".to_vec(), false, ClipboardFormat::Rtf),
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html),
        ];
        let rich_read = NativeClipboardTransferPolicy::new(
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::new(true, false),
        );
        let rich_write = NativeClipboardTransferPolicy::new(
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::new(false, true),
        );
        let active_read = NativeClipboardPolicy::new(true, false);
        let active_write = NativeClipboardPolicy::new(false, true);
        let mut message = Message::new();
        message.set_multi_clipboards(MultiClipboards {
            clipboards: entries.clone(),
            ..Default::default()
        });

        let NativeHostOutgoingClipboardDecision::Send(canonical) =
            native_host_prepare_outgoing_clipboard_message(&message, rich_read, active_read)
        else {
            panic!("explicit rich read must admit the canonical bundle");
        };
        let Some(message::Union::MultiClipboards(canonical)) = canonical.union else {
            panic!("three representations must remain atomic");
        };
        assert_eq!(canonical.clipboards.len(), 3);
        assert!(canonical
            .clipboards
            .iter()
            .all(|clipboard| !clipboard.compress));

        assert!(matches!(
            native_host_prepare_outgoing_clipboard_message(
                &message,
                NativeClipboardTransferPolicy::new(
                    NativeClipboardPolicy::new(true, false),
                    NativeClipboardPolicy::default(),
                ),
                active_read,
            ),
            NativeHostOutgoingClipboardDecision::Reject
        ));
        assert!(matches!(
            native_host_prepare_outgoing_clipboard_message(&message, rich_read, active_write),
            NativeHostOutgoingClipboardDecision::Reject
        ));

        let incoming =
            native_host_prepare_incoming_clipboard_entries(&entries, rich_write, active_write)
                .expect("explicit rich write must admit a bounded canonical bundle");
        assert_eq!(incoming.len(), 3);
        assert!(incoming.iter().all(|clipboard| !clipboard.compress));
        assert!(
            native_host_prepare_incoming_clipboard_entries(&entries, rich_write, active_read,)
                .is_none()
        );
        assert!(
            native_host_prepare_incoming_clipboard_entries(&entries, rich_read, active_write,)
                .is_none()
        );
    }

    #[test]
    fn native_host_image_transport_requires_explicit_format_and_direction_policy() {
        let mut rgba = clipboard_fixture(
            hbb_common::compress::compress(&[1, 2, 3, 255]),
            true,
            ClipboardFormat::ImageRgba,
        );
        rgba.width = 1;
        rgba.height = 1;
        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[4, 5, 6, 255]).unwrap();
        let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".to_vec();
        let images = [
            (rgba, vec![1, 2, 3, 255], 1, 1),
            (
                clipboard_fixture(png.clone(), false, ClipboardFormat::ImagePng),
                png,
                0,
                0,
            ),
            (
                clipboard_fixture(
                    hbb_common::compress::compress(&svg),
                    true,
                    ClipboardFormat::ImageSvg,
                ),
                svg,
                0,
                0,
            ),
        ];
        let image_read = NativeClipboardTransferPolicy::with_image_policy(
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::new(true, false),
        );
        let image_write = NativeClipboardTransferPolicy::with_image_policy(
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::new(false, true),
        );
        let active_read = NativeClipboardPolicy::new(true, false);
        let active_write = NativeClipboardPolicy::new(false, true);

        assert_eq!(image_read.image(), NativeClipboardPolicy::new(true, false));
        assert_eq!(image_read.directions(), active_read);
        assert_eq!(image_write.directions(), active_write);

        for (image, expected_payload, expected_width, expected_height) in &images {
            let mut message = Message::new();
            message.set_clipboard(image.clone());
            let NativeHostOutgoingClipboardDecision::Send(canonical) =
                native_host_prepare_outgoing_clipboard_message(&message, image_read, active_read)
            else {
                panic!("explicit image read must admit the canonical payload");
            };
            let Some(message::Union::Clipboard(canonical)) = canonical.union else {
                panic!("one image must remain one Clipboard message");
            };
            assert_eq!(canonical.format, image.format);
            assert_eq!(canonical.content.as_ref(), expected_payload);
            assert_eq!(
                (canonical.width, canonical.height),
                (*expected_width, *expected_height)
            );
            assert!(!canonical.compress);
            assert!(canonical.special_name.is_empty());

            assert!(matches!(
                native_host_prepare_outgoing_clipboard_message(
                    &message,
                    NativeClipboardTransferPolicy::new(
                        NativeClipboardPolicy::default(),
                        NativeClipboardPolicy::new(true, false),
                    ),
                    active_read,
                ),
                NativeHostOutgoingClipboardDecision::Reject
            ));
            assert!(matches!(
                native_host_prepare_outgoing_clipboard_message(&message, image_read, active_write,),
                NativeHostOutgoingClipboardDecision::Reject
            ));

            let incoming = native_host_prepare_incoming_clipboard_entries(
                std::slice::from_ref(&image),
                image_write,
                active_write,
            )
            .expect("explicit image write must admit the canonical payload");
            assert_eq!(incoming.len(), 1);
            assert_eq!(incoming[0].format, image.format);
            assert_eq!(incoming[0].content.as_ref(), expected_payload);
            assert!(!incoming[0].compress);
            assert!(native_host_prepare_incoming_clipboard_entries(
                std::slice::from_ref(&image),
                image_write,
                active_read,
            )
            .is_none());
            assert!(native_host_prepare_incoming_clipboard_entries(
                std::slice::from_ref(&image),
                image_read,
                active_write,
            )
            .is_none());
        }

        let image = images[0].0.clone();
        assert!(native_host_prepare_incoming_clipboard_entries(
            &[image.clone(), image],
            image_write,
            active_write,
        )
        .is_none());
    }

    #[test]
    fn native_active_session_broker_is_single_and_capability_snapshot_safe() {
        let initial = NativeSessionCapabilities::new(true, true, true);
        let active = NativeSessionCapabilities::new(true, false, true);
        let mut broker = NativeSessionBroker::default();
        assert_eq!(
            broker.begin(active_session_fixture("host:1", 1, initial, active)),
            NativeSessionStartResult::Accepted
        );
        assert_eq!(
            broker.begin(active_session_fixture("host:1", 1, initial, active)),
            NativeSessionStartResult::Existing
        );
        assert_eq!(
            broker.begin(active_session_fixture("host:2", 2, initial, active)),
            NativeSessionStartResult::Busy
        );

        let snapshot = broker.snapshot().unwrap();
        assert_eq!(snapshot.connection_id, "host:1");
        assert_eq!(
            snapshot.initial_capabilities.names(),
            vec![
                "viewDisplay",
                "controlKeyboardMouse",
                "readClipboard",
                "writeClipboard",
                "hearSystemAudio",
            ]
        );
        assert_eq!(
            snapshot.active_capabilities.names(),
            vec!["viewDisplay", "controlKeyboardMouse", "hearSystemAudio"]
        );
        assert_eq!(snapshot.event_payload()["remoteMetadataTrust"], "untrusted");

        let revoked = NativeSessionCapabilities::new(false, false, true);
        let unavailable = NativeSessionInputAvailability::limited(
            NativeSessionInputUnavailableReason::SessionUnavailable,
        );
        assert!(broker
            .update_capabilities(9, revoked, unavailable)
            .is_none());
        assert_eq!(
            broker
                .update_capabilities(1, revoked, unavailable)
                .unwrap()
                .input_availability,
            unavailable
        );
        assert_eq!(broker.snapshot().unwrap().active_capabilities, revoked);
        let accessibility_denied = NativeSessionInputAvailability::limited(
            NativeSessionInputUnavailableReason::AccessibilityDenied,
        );
        assert_eq!(
            broker
                .update_capabilities(1, revoked, accessibility_denied)
                .unwrap()
                .input_availability,
            accessibility_denied
        );
        assert!(broker
            .update_capabilities(1, revoked, accessibility_denied)
            .is_none());
        assert!(broker.end(9).is_none());
        assert_eq!(broker.end(1).unwrap().snapshot.connection_id, "host:1");
        assert!(broker.snapshot().is_none());

        let no_keyboard = NativeSessionCapabilities::new(false, true, true);
        assert_eq!(
            broker.begin(active_session_fixture(
                "host:3",
                3,
                no_keyboard,
                NativeSessionCapabilities::new(true, true, true),
            )),
            NativeSessionStartResult::Invalid
        );
    }

    #[test]
    fn native_active_session_lifecycle_emits_sanitized_events_and_closes_on_reset() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let events = Mutex::new(Vec::new());
        let mut host = ready_test_host("session-host");
        host.callbacks = RdnHostCallbacks {
            abi_version: HOST_ABI_VERSION,
            on_event: Some(collect_test_event),
            context: &events as *const Mutex<Vec<Value>> as *mut c_void,
        };
        bind_media_host(&host);
        let _guard = BoundMediaTestGuard;

        let initial = NativeSessionCapabilities::new(true, true, true);
        let active = NativeSessionCapabilities::new(true, true, false);
        let (first_sender, mut first_receiver) = tokio::sync::mpsc::unbounded_channel();
        assert!(native_host_begin_session(
            7,
            "remote-id".to_owned(),
            "Remote\nMac".to_owned(),
            "macOS".to_owned(),
            initial,
            active,
            NativeSessionInputAvailability::available(),
            first_sender,
        ));
        let active_snapshot = host.snapshot_json();
        assert_eq!(active_snapshot["schemaVersion"], SNAPSHOT_SCHEMA_VERSION);
        assert_eq!(active_snapshot["recoveryEpoch"], 0);
        assert_eq!(active_snapshot["recoveryStatus"], "running");
        assert_eq!(
            active_snapshot["activeSession"]["connectionId"],
            "session-host:7"
        );
        assert_eq!(
            active_snapshot["activeSession"]["remoteMetadataTrust"],
            "untrusted"
        );
        assert_eq!(
            active_snapshot["activeSession"]["activeCapabilities"],
            json!([
                "viewDisplay",
                "controlKeyboardMouse",
                "readClipboard",
                "writeClipboard"
            ])
        );
        assert_eq!(
            active_snapshot["activeSession"]["inputAvailability"],
            "available"
        );
        assert!(active_snapshot["activeSession"]["inputUnavailableReason"].is_null());
        assert_eq!(
            SESSION_BROKER
                .lock()
                .unwrap()
                .snapshot()
                .unwrap()
                .connection_id,
            "session-host:7"
        );
        native_host_update_session_capabilities(
            7,
            NativeSessionCapabilities::new(false, true, false),
            NativeSessionInputAvailability::limited(
                NativeSessionInputUnavailableReason::SessionUnavailable,
            ),
        );
        assert_eq!(
            host.snapshot_json()["activeSession"]["activeCapabilities"],
            json!(["viewDisplay", "readClipboard", "writeClipboard"])
        );
        assert_eq!(
            host.snapshot_json()["activeSession"]["inputAvailability"],
            "limited"
        );
        assert_eq!(
            host.snapshot_json()["activeSession"]["inputUnavailableReason"],
            "sessionUnavailable"
        );
        native_host_end_session(7);
        assert!(SESSION_BROKER.lock().unwrap().snapshot().is_none());
        assert!(host.snapshot_json()["activeSession"].is_null());
        assert!(first_receiver.try_recv().is_err());

        let (second_sender, mut second_receiver) = tokio::sync::mpsc::unbounded_channel();
        assert!(native_host_begin_session(
            8,
            "remote-id-2".to_owned(),
            "Second Mac".to_owned(),
            "macOS".to_owned(),
            initial,
            initial,
            NativeSessionInputAvailability::available(),
            second_sender,
        ));
        reset_native_session_broker("hostStopped");
        assert!(matches!(
            second_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));
        assert!(SESSION_BROKER.lock().unwrap().snapshot().is_none());

        let encoded = serde_json::to_string(&*events.lock().unwrap()).unwrap();
        assert!(encoded.contains("sessionStarted"));
        assert!(encoded.contains("sessionCapabilitiesChanged"));
        assert!(encoded.contains("sessionEnded"));
        assert!(encoded.contains("RemoteMac"));
        assert!(!encoded.contains("Remote\\nMac"));
        assert!(encoded.contains("hostStopped"));
    }

    #[test]
    fn native_active_session_commands_are_exact_scoped_and_fail_closed() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let events = Mutex::new(Vec::new());
        let mut host = ready_test_host("session-command-host");
        host.callbacks = RdnHostCallbacks {
            abi_version: HOST_ABI_VERSION,
            on_event: Some(collect_test_event),
            context: &events as *const Mutex<Vec<Value>> as *mut c_void,
        };
        bind_media_host(&host);
        let _guard = BoundMediaTestGuard;

        let initial = NativeSessionCapabilities::new(true, true, true);
        let (command_sender, mut command_receiver) = tokio::sync::mpsc::unbounded_channel();
        assert!(native_host_begin_session(
            17,
            "remote-id".to_owned(),
            "Remote Mac".to_owned(),
            "macOS".to_owned(),
            initial,
            initial,
            NativeSessionInputAvailability::available(),
            command_sender,
        ));

        let malformed = json!({
            "commandId": "session-malformed",
            "name": "disableInputForActiveSession",
            "connectionId": "session-command-host:17",
            "ignored": true,
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-malformed",
                "disableInputForActiveSession",
                &malformed,
            ),
            RDN_HOST_ERR_VALIDATION
        );
        assert!(command_receiver.try_recv().is_err());

        for (command_id, name, expected) in [
            (
                "session-input",
                "disableInputForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "keyboard".to_owned(),
                    enabled: false,
                },
            ),
            (
                "session-clipboard-read",
                "disableClipboardReadForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-read".to_owned(),
                    enabled: false,
                },
            ),
            (
                "session-clipboard-write",
                "disableClipboardWriteForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-write".to_owned(),
                    enabled: false,
                },
            ),
            (
                "session-clipboard",
                "disableClipboardForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard".to_owned(),
                    enabled: false,
                },
            ),
            (
                "session-audio",
                "disableAudioForActiveSession",
                crate::ipc::Data::SwitchPermission {
                    name: "audio".to_owned(),
                    enabled: false,
                },
            ),
        ] {
            let envelope = json!({
                "commandId": command_id,
                "name": name,
                "connectionId": "session-command-host:17",
            });
            assert_eq!(
                handle_command(&mut host, command_id, name, &envelope),
                RDN_HOST_OK
            );
            match (command_receiver.try_recv().unwrap(), expected) {
                (
                    crate::ipc::Data::SwitchPermission { name, enabled },
                    crate::ipc::Data::SwitchPermission {
                        name: expected_name,
                        enabled: expected_enabled,
                    },
                ) => {
                    assert_eq!(name, expected_name);
                    assert_eq!(enabled, expected_enabled);
                }
                _ => panic!("unexpected session permission command"),
            }
        }

        native_host_update_session_capabilities(
            17,
            NativeSessionCapabilities::with_clipboard_policy(
                true,
                NativeClipboardPolicy::new(false, true),
                true,
            ),
            NativeSessionInputAvailability::available(),
        );
        let read_already_disabled = json!({
            "commandId": "session-clipboard-read-already-disabled",
            "name": "disableClipboardReadForActiveSession",
            "connectionId": "session-command-host:17",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-clipboard-read-already-disabled",
                "disableClipboardReadForActiveSession",
                &read_already_disabled,
            ),
            RDN_HOST_OK
        );
        assert!(command_receiver.try_recv().is_err());

        let write_still_enabled = json!({
            "commandId": "session-clipboard-write-enabled",
            "name": "disableClipboardWriteForActiveSession",
            "connectionId": "session-command-host:17",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-clipboard-write-enabled",
                "disableClipboardWriteForActiveSession",
                &write_still_enabled,
            ),
            RDN_HOST_OK
        );
        assert!(matches!(
            command_receiver.try_recv(),
            Ok(crate::ipc::Data::SwitchPermission { name, enabled })
                if name == "clipboard-write" && !enabled
        ));

        native_host_update_session_capabilities(
            17,
            NativeSessionCapabilities::new(false, false, false),
            NativeSessionInputAvailability::disabled(
                NativeSessionInputUnavailableReason::LocalPolicyDisabled,
            ),
        );
        let already_disabled = json!({
            "commandId": "session-input-already-disabled",
            "name": "disableInputForActiveSession",
            "connectionId": "session-command-host:17",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-input-already-disabled",
                "disableInputForActiveSession",
                &already_disabled,
            ),
            RDN_HOST_OK
        );
        assert!(command_receiver.try_recv().is_err());

        let stale = json!({
            "commandId": "session-stale",
            "name": "disconnectSession",
            "connectionId": "session-command-host:18",
        });
        assert_eq!(
            handle_command(&mut host, "session-stale", "disconnectSession", &stale),
            RDN_HOST_ERR_SESSION_STALE
        );
        let foreign = json!({
            "commandId": "session-foreign",
            "name": "disconnectSession",
            "connectionId": "other-host:17",
        });
        assert_eq!(
            handle_command(&mut host, "session-foreign", "disconnectSession", &foreign),
            RDN_HOST_ERR_SESSION_NOT_FOUND
        );

        let disconnect = json!({
            "commandId": "session-disconnect",
            "name": "disconnectSession",
            "connectionId": "session-command-host:17",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-disconnect",
                "disconnectSession",
                &disconnect,
            ),
            RDN_HOST_OK
        );
        assert!(matches!(
            command_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));
        assert_eq!(
            handle_command(
                &mut host,
                "session-disconnect-again",
                "disconnectSession",
                &disconnect,
            ),
            RDN_HOST_OK
        );
        assert!(command_receiver.try_recv().is_err());

        native_host_end_session(17);
        assert_eq!(
            handle_command(&mut host, "session-ended", "disconnectSession", &disconnect,),
            RDN_HOST_ERR_SESSION_NOT_FOUND
        );

        let (dead_sender, dead_receiver) = tokio::sync::mpsc::unbounded_channel();
        drop(dead_receiver);
        assert!(native_host_begin_session(
            19,
            "remote-id".to_owned(),
            "Remote Mac".to_owned(),
            "macOS".to_owned(),
            initial,
            initial,
            NativeSessionInputAvailability::available(),
            dead_sender,
        ));
        let unavailable = json!({
            "commandId": "session-unavailable",
            "name": "disableInputForActiveSession",
            "connectionId": "session-command-host:19",
        });
        assert_eq!(
            handle_command(
                &mut host,
                "session-unavailable",
                "disableInputForActiveSession",
                &unavailable,
            ),
            RDN_HOST_ERR_SESSION_COMMAND_UNAVAILABLE
        );
        native_host_end_session(19);
    }

    #[test]
    fn native_approval_snapshot_and_commands_are_recoverable_and_fail_closed() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let events = Mutex::new(Vec::new());
        let mut host = ready_test_host("approval-command-host");
        host.callbacks = RdnHostCallbacks {
            abi_version: HOST_ABI_VERSION,
            on_event: Some(collect_test_event),
            context: &events as *const Mutex<Vec<Value>> as *mut c_void,
        };

        let (pending, mut approve_receiver) = pending_approval_fixture(
            "approval-command-host:7",
            7,
            Instant::now() + Duration::from_secs(30),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(pending),
            NativeApprovalStartResult::Accepted
        );
        let snapshot = host.snapshot_json();
        assert_eq!(snapshot["schemaVersion"], SNAPSHOT_SCHEMA_VERSION);
        assert_eq!(snapshot["authenticatedConnectionCount"], 0);
        assert_eq!(
            snapshot["pendingApproval"]["connectionId"],
            "approval-command-host:7"
        );
        assert_eq!(
            snapshot["pendingApproval"]["remoteMetadataTrust"],
            "untrusted"
        );

        let approve = json!({
            "commandId": "approval-approve",
            "name": "approveConnection",
            "connectionId": "approval-command-host:7",
        });
        assert_eq!(
            handle_command(&mut host, "approval-approve", "approveConnection", &approve,),
            RDN_HOST_OK
        );
        assert!(matches!(
            approve_receiver.try_recv(),
            Ok(crate::ipc::Data::Authorize)
        ));
        assert!(host.snapshot_json()["pendingApproval"].is_null());
        assert_eq!(
            handle_command(&mut host, "approval-late", "approveConnection", &approve,),
            RDN_HOST_ERR_APPROVAL_FINALIZED
        );

        let malformed = json!({
            "commandId": "approval-malformed",
            "name": "rejectConnection",
            "connectionId": "approval-command-host:8",
            "ignored": true,
        });
        assert_eq!(
            handle_command(
                &mut host,
                "approval-malformed",
                "rejectConnection",
                &malformed,
            ),
            RDN_HOST_ERR_VALIDATION
        );

        let (reject_pending, mut reject_receiver) = pending_approval_fixture(
            "approval-command-host:8",
            8,
            Instant::now() + Duration::from_secs(30),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(reject_pending),
            NativeApprovalStartResult::Accepted
        );
        let reject = json!({
            "commandId": "approval-reject",
            "name": "rejectConnection",
            "connectionId": "approval-command-host:8",
        });
        assert_eq!(
            handle_command(&mut host, "approval-reject", "rejectConnection", &reject,),
            RDN_HOST_OK
        );
        assert!(matches!(
            reject_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));

        let (expired_pending, mut expired_receiver) = pending_approval_fixture(
            "approval-command-host:9",
            9,
            Instant::now() - Duration::from_millis(1),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(expired_pending),
            NativeApprovalStartResult::Accepted
        );
        let expired = json!({
            "commandId": "approval-expired",
            "name": "approveConnection",
            "connectionId": "approval-command-host:9",
        });
        assert_eq!(
            handle_command(&mut host, "approval-expired", "approveConnection", &expired,),
            RDN_HOST_ERR_APPROVAL_EXPIRED
        );
        assert!(matches!(
            expired_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));

        let (snapshot_expired, mut snapshot_expired_receiver) = pending_approval_fixture(
            "approval-command-host:10",
            10,
            Instant::now() - Duration::from_millis(1),
        );
        assert_eq!(
            APPROVAL_BROKER.lock().unwrap().begin(snapshot_expired),
            NativeApprovalStartResult::Accepted
        );
        assert!(host.snapshot_json()["pendingApproval"].is_null());
        assert!(matches!(
            snapshot_expired_receiver.try_recv(),
            Ok(crate::ipc::Data::Close)
        ));

        let encoded_events = serde_json::to_string(&*events.lock().unwrap()).unwrap();
        assert!(encoded_events.contains("approval-approved"));
        assert!(encoded_events.contains("approval-rejected"));
        assert!(encoded_events.contains("approval-expired"));
        assert!(!encoded_events.contains("decision_sender"));
        unbind_media_host();
    }

    fn submit_h264_access_unit(
        host: &mut RdnHost,
        route: &NativeMediaRoute,
        instance_id: &CString,
        pts_us: u64,
        keyframe: bool,
    ) -> i32 {
        let data = [pts_us as u8];
        let flags = if keyframe {
            MEDIA_FLAG_KEYFRAME | MEDIA_FLAG_PARAMETER_SETS
        } else {
            0
        };
        let access_unit = RdnHostEncodedAccessUnit {
            abi_version: HOST_MEDIA_ABI_VERSION,
            host_instance_id: instance_id.as_ptr(),
            connection_epoch: route.connection_epoch,
            codec_epoch: route.codec_epoch,
            display_id: route.display_id,
            display_revision: route.display_revision,
            codec: MEDIA_CODEC_H264,
            framing: MEDIA_FRAMING_AVCC,
            flags,
            pts_us,
            data: data.as_ptr(),
            length: data.len(),
        };
        unsafe { rdn_host_media_submit_access_unit(host, &access_unit) }
    }

    fn media_packet(pts_us: u64, keyframe: bool) -> NativeMediaAccessUnit {
        NativeMediaAccessUnit {
            codec: MEDIA_CODEC_H264,
            framing: MEDIA_FRAMING_AVCC,
            pts_us,
            keyframe,
            has_parameter_sets: keyframe,
            data: vec![pts_us as u8],
        }
    }

    #[test]
    fn rejects_namespace_components_that_could_escape_directories() {
        assert!(valid_namespace_component("FarPaneHost"));
        assert!(valid_namespace_component("io.rustdesknative"));
        assert!(!valid_namespace_component(""));
        assert!(!valid_namespace_component("../evil"));
        assert!(!valid_namespace_component("a/b"));
        assert!(!valid_namespace_component("a:b"));
        assert!(!valid_namespace_component(&"x".repeat(MAX_NAME_BYTES + 1)));
    }

    #[test]
    fn command_envelope_bounds_are_enforced() {
        assert_eq!(parse_envelope(b""), Err(RDN_HOST_ERR_VALIDATION));
        assert_eq!(
            parse_envelope(&vec![b' '; MAX_ENVELOPE_BYTES + 1]),
            Err(RDN_HOST_ERR_VALIDATION)
        );
        assert!(parse_envelope(b"{\"commandId\":\"1\",\"name\":\"enableHost\"}").is_ok());
        assert_eq!(parse_envelope(b"{not json"), Err(RDN_HOST_ERR_VALIDATION));
    }

    #[test]
    fn media_milestone_payload_is_sanitized_and_fail_closed() {
        let (_, receiver) = sync_channel(1);
        let route = NativeMediaRoute {
            connection_epoch: 7,
            codec_epoch: 9,
            display_id: 0,
            display_revision: 3,
            codec: MEDIA_CODEC_H264,
            receiver,
            queue_telemetry: Arc::new(NativeMediaQueueTelemetry::default()),
            writer_telemetry: Arc::new(NativeMediaWriterTelemetry::default()),
            network_telemetry: Arc::new(NativeMediaNetworkTelemetry::default()),
            transport_telemetry: Arc::new(NativeMediaTransportTelemetry::default()),
        };
        let packet = NativeMediaPacketMetadata {
            framing: MEDIA_FRAMING_AVCC,
            pts_us: 42_999,
            keyframe: true,
            has_parameter_sets: true,
        };
        let payload = native_media_milestone_payload(
            &route,
            NativeMediaMilestone::FirstPacketAcknowledged,
            packet,
            1,
        )
        .unwrap();
        assert_eq!(payload["kind"], "firstPacketAcknowledged");
        assert_eq!(payload["codec"], "h264");
        assert_eq!(payload["framing"], "avcc");
        assert_eq!(payload["subscriberCount"], 1);
        let encoded = serde_json::to_string(&payload).unwrap();
        for forbidden in ["peerId", "data", "password", "server"] {
            assert!(!encoded.contains(forbidden));
        }
        assert!(native_media_milestone_payload(
            &route,
            NativeMediaMilestone::FirstPacketDispatched,
            packet,
            0,
        )
        .is_none());
        let invalid_packet = NativeMediaPacketMetadata {
            framing: 99,
            ..packet
        };
        assert!(native_media_milestone_payload(
            &route,
            NativeMediaMilestone::RefreshKeyframeDispatched,
            invalid_packet,
            1,
        )
        .is_none());
    }

    #[test]
    fn full_media_queue_rejects_newest_without_evicting_encoded_packets() {
        let (sender, receiver) = sync_channel(MEDIA_QUEUE_CAPACITY);
        let telemetry = NativeMediaQueueTelemetry::default();
        for (pts_us, keyframe) in [(100, true), (200, false), (300, false)] {
            assert!(
                try_enqueue_native_media(&sender, &telemetry, media_packet(pts_us, keyframe))
                    .is_ok()
            );
        }
        assert_eq!(
            telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: MEDIA_QUEUE_CAPACITY,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            }
        );

        let (reason, rejected) =
            try_enqueue_native_media(&sender, &telemetry, media_packet(400, false))
                .expect_err("a full encoded queue must reject the new packet");
        assert_eq!(reason, NativeMediaQueueDropReason::NetworkBackpressure);
        assert_eq!(rejected.pts_us, 400);
        assert_eq!(
            telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: MEDIA_QUEUE_CAPACITY,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            }
        );

        let retained = (0..MEDIA_QUEUE_CAPACITY)
            .map(|_| {
                let packet = receiver.try_recv().expect("queued packet");
                telemetry.record_dequeued();
                packet
            })
            .collect::<Vec<_>>();
        assert_eq!(
            telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 0,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            }
        );
        assert_eq!(
            retained
                .iter()
                .map(|packet| packet.pts_us)
                .collect::<Vec<_>>(),
            vec![100, 200, 300]
        );
        assert_eq!(
            retained
                .iter()
                .map(|packet| packet.keyframe)
                .collect::<Vec<_>>(),
            vec![true, false, false]
        );
    }

    #[test]
    fn public_access_unit_api_reports_saturation_then_accepts_replacement_idr() {
        let _serial = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        let mut host = ready_test_host("queue-saturation-host");
        bind_media_host(&host);
        let _bound = BoundMediaTestGuard;
        {
            let mut broker = MEDIA_BROKER.lock().unwrap();
            broker.capabilities = MediaCapabilities {
                h264_hardware: true,
                h265_hardware: false,
                max_width: 1_920,
                max_height: 1_080,
                max_fps: 60,
            };
        }
        let route = native_media_begin_route(0, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
            .expect("test route should use the production bounded queue");
        let instance_id = CString::new(host.instance_id.clone()).unwrap();

        for (pts_us, keyframe) in [(100, true), (200, false), (300, false)] {
            assert_eq!(
                submit_h264_access_unit(&mut host, &route, &instance_id, pts_us, keyframe),
                RDN_HOST_OK
            );
        }
        assert_eq!(
            route.queue_telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 3,
                maximum_depth: 3,
            }
        );
        assert_eq!(
            submit_h264_access_unit(&mut host, &route, &instance_id, 400, false),
            RDN_HOST_ERR_BACKPRESSURE
        );

        let first = route.receiver.try_recv().expect("first queued IDR");
        native_media_record_dequeued(&route);
        assert_eq!(first.pts_us, 100);
        assert!(first.keyframe);
        assert!(first.has_parameter_sets);

        // A rejected submit must not advance route state. Reusing its PTS for
        // the replacement generation's IDR is therefore valid once one queue
        // slot is available.
        assert_eq!(
            submit_h264_access_unit(&mut host, &route, &instance_id, 400, true),
            RDN_HOST_OK
        );
        assert_eq!(
            route.queue_telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 3,
                maximum_depth: 3,
            }
        );
        let retained = (0..MEDIA_QUEUE_CAPACITY)
            .map(|_| {
                let packet = route.receiver.try_recv().expect("retained queued packet");
                native_media_record_dequeued(&route);
                packet
            })
            .collect::<Vec<_>>();
        assert_eq!(
            route.queue_telemetry.snapshot(),
            NativeMediaQueueSnapshot {
                current_depth: 0,
                maximum_depth: 3,
            }
        );
        assert_eq!(
            retained
                .iter()
                .map(|packet| packet.pts_us)
                .collect::<Vec<_>>(),
            vec![200, 300, 400]
        );
        assert!(!retained[0].keyframe);
        assert!(!retained[1].keyframe);
        assert!(retained[2].keyframe);
        assert!(retained[2].has_parameter_sets);
    }

    #[test]
    fn disconnected_media_queue_classifies_shutdown_and_returns_packet() {
        let (sender, receiver) = sync_channel(MEDIA_QUEUE_CAPACITY);
        let telemetry = NativeMediaQueueTelemetry::default();
        drop(receiver);

        let (reason, rejected) =
            try_enqueue_native_media(&sender, &telemetry, media_packet(500, true))
                .expect_err("a disconnected queue must reject the packet");
        assert_eq!(reason, NativeMediaQueueDropReason::Shutdown);
        assert_eq!(rejected.pts_us, 500);
        assert!(rejected.keyframe);
        assert!(rejected.has_parameter_sets);
        assert_eq!(telemetry.snapshot(), NativeMediaQueueSnapshot::default());
    }

    #[test]
    fn media_queue_payload_is_sanitized_and_bounded() {
        let payload = native_media_queue_payload(
            "routeStopped",
            7,
            9,
            0,
            3,
            NativeMediaQueueSnapshot {
                current_depth: 1,
                maximum_depth: MEDIA_QUEUE_CAPACITY,
            },
        );
        assert_eq!(payload["kind"], "routeStopped");
        assert_eq!(payload["connectionEpoch"], 7);
        assert_eq!(payload["codecEpoch"], 9);
        assert_eq!(payload["displayId"], 0);
        assert_eq!(payload["displayRevision"], 3);
        assert_eq!(payload["currentDepth"], 1);
        assert_eq!(payload["maximumDepth"], MEDIA_QUEUE_CAPACITY);
        assert_eq!(payload["capacity"], MEDIA_QUEUE_CAPACITY);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn writer_timing_aggregates_only_route_scoped_wall_measurements() {
        let telemetry = NativeMediaWriterTelemetry::default();
        telemetry.record(
            0,
            Duration::from_micros(99),
            Duration::from_millis(99),
            false,
        );
        telemetry.record(2, Duration::from_micros(15), Duration::from_millis(2), true);
        telemetry.record(
            1,
            Duration::from_micros(10),
            Duration::from_millis(3),
            false,
        );
        let snapshot = NativeMediaWriterSnapshot {
            cycles: 2,
            subscriber_dispatches: 3,
            dispatch_wall_total_us: 25,
            maximum_dispatch_wall_us: 15,
            confirmation_wait_total_us: 5_000,
            maximum_confirmation_wait_us: 3_000,
            completed_confirmations: 1,
            timed_out_confirmations: 1,
        };
        assert_eq!(telemetry.snapshot(), snapshot);
        let payload = native_media_writer_payload("sample", 7, 9, 0, 3, snapshot);
        assert_eq!(payload["cycles"], 2);
        assert_eq!(payload["subscriberDispatches"], 3);
        assert_eq!(payload["dispatchWallTotalUs"], 25);
        assert_eq!(payload["maximumConfirmationWaitUs"], 3_000);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn network_payload_preserves_sample_availability_and_count_bounds() {
        let telemetry = NativeMediaNetworkTelemetry::default();
        assert!(telemetry.record(3, 2, 2, 1, 1, Some(180), Some(42)));
        assert!(!telemetry.record(1, 2, 2, 1, 1, Some(180), Some(42)));
        assert!(!telemetry.record(3, 2, 0, 0, 0, Some(180), None));
        let snapshot = NativeMediaNetworkSnapshot {
            subscriber_count: 3,
            qos_subscriber_count: 2,
            delay_sampled_subscribers: 2,
            rtt_sampled_subscribers: 1,
            response_delayed_subscribers: 1,
            worst_network_delay_ms: Some(180),
            worst_rtt_ms: Some(42),
        };
        assert_eq!(telemetry.snapshot(), snapshot);
        let payload = native_media_network_payload("sample", 7, 9, 0, 3, snapshot);
        assert_eq!(payload["subscriberCount"], 3);
        assert_eq!(payload["qosSubscriberCount"], 2);
        assert_eq!(payload["delaySampledSubscribers"], 2);
        assert_eq!(payload["rttSampledSubscribers"], 1);
        assert_eq!(payload["responseDelayedSubscribers"], 1);
        assert_eq!(payload["worstNetworkDelayMs"], 180);
        assert_eq!(payload["worstRttMs"], 42);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn transport_payload_preserves_unknown_and_rejects_inconsistent_counts() {
        let telemetry = NativeMediaTransportTelemetry::default();
        assert!(telemetry.record(4, 2, 1, 1));
        assert!(!telemetry.record(4, 2, 1, 0));
        let snapshot = NativeMediaTransportSnapshot {
            subscriber_count: 4,
            direct_subscribers: 2,
            relay_subscribers: 1,
            unknown_subscribers: 1,
        };
        assert_eq!(telemetry.snapshot(), snapshot);
        let payload = native_media_transport_payload("sample", 7, 9, 0, 3, snapshot);
        assert_eq!(payload["subscriberCount"], 4);
        assert_eq!(payload["directSubscribers"], 2);
        assert_eq!(payload["relaySubscribers"], 1);
        assert_eq!(payload["unknownSubscribers"], 1);
        let encoded = payload.to_string().to_ascii_lowercase();
        for forbidden in ["peer", "server", "password", "publickey", "payload", "data"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn route_stop_emits_final_queue_sample_before_stop_control() {
        let _serial = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        let events = Mutex::new(Vec::<Value>::new());
        let mut host = ready_test_host("queue-event-host");
        host.callbacks.on_event = Some(collect_test_event);
        host.callbacks.context = &events as *const _ as *mut c_void;
        bind_media_host(&host);
        let _bound = BoundMediaTestGuard;
        {
            let mut broker = MEDIA_BROKER.lock().unwrap();
            broker.capabilities = MediaCapabilities {
                h264_hardware: true,
                h265_hardware: false,
                max_width: 1_920,
                max_height: 1_080,
                max_fps: 60,
            };
        }
        let route = native_media_begin_route(0, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
            .expect("test route");
        let instance_id = CString::new(host.instance_id.clone()).unwrap();
        assert_eq!(
            submit_h264_access_unit(&mut host, &route, &instance_id, 100, true),
            RDN_HOST_OK
        );
        native_media_record_writer_cycle(
            &route,
            1,
            Duration::from_micros(10),
            Duration::from_millis(2),
            true,
        );
        native_media_report_queue_depth(&route);
        native_media_report_writer_timing(&route);
        native_media_report_network(&route, 1, 1, 1, 1, 0, Some(25), Some(20));
        native_media_report_transport(&route, 1, 0, 1, 0);
        native_media_end_route(&route);

        let events = events.lock().unwrap();
        let tail = &events[events.len() - 9..];
        assert_eq!(tail[0]["eventType"], "mediaQueueDiagnostic");
        assert_eq!(tail[0]["payload"]["kind"], "sample");
        assert_eq!(tail[1]["eventType"], "mediaWriterDiagnostic");
        assert_eq!(tail[1]["payload"]["kind"], "sample");
        assert_eq!(tail[2]["eventType"], "mediaNetworkDiagnostic");
        assert_eq!(tail[2]["payload"]["kind"], "sample");
        assert_eq!(tail[3]["eventType"], "mediaTransportDiagnostic");
        assert_eq!(tail[3]["payload"]["kind"], "sample");
        assert_eq!(tail[4]["eventType"], "mediaQueueDiagnostic");
        assert_eq!(tail[4]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[4]["payload"]["currentDepth"], 1);
        assert_eq!(tail[4]["payload"]["maximumDepth"], 1);
        assert_eq!(tail[5]["eventType"], "mediaWriterDiagnostic");
        assert_eq!(tail[5]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[5]["payload"]["cycles"], 1);
        assert_eq!(tail[6]["eventType"], "mediaNetworkDiagnostic");
        assert_eq!(tail[6]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[6]["payload"]["worstRttMs"], 20);
        assert_eq!(tail[7]["eventType"], "mediaTransportDiagnostic");
        assert_eq!(tail[7]["payload"]["kind"], "routeStopped");
        assert_eq!(tail[7]["payload"]["relaySubscribers"], 1);
        assert_eq!(tail[8]["eventType"], "mediaControl");
        assert_eq!(tail[8]["payload"]["command"], "stopCapture");
    }

    #[test]
    fn display_reconfigure_provenance_is_exact_and_consumed_once() {
        let _serial = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        let events = Mutex::new(Vec::<Value>::new());
        let mut host = ready_test_host("display-provenance-host");
        host.callbacks.on_event = Some(collect_test_event);
        host.callbacks.context = &events as *const _ as *mut c_void;
        bind_media_host(&host);
        let _bound = BoundMediaTestGuard;
        {
            let mut broker = MEDIA_BROKER.lock().unwrap();
            broker.capabilities = MediaCapabilities {
                h264_hardware: true,
                h265_hardware: false,
                max_width: 1_920,
                max_height: 1_080,
                max_fps: 60,
            };
        }

        let previous = native_media_begin_route(0, MEDIA_CODEC_H264, 1_920, 1_080, 30, 4_000_000)
            .expect("initial route");
        assert_eq!(previous.display_revision, 1);
        native_media_mark_display_reconfigure(&previous).expect("display marker");
        assert!(native_media_mark_display_reconfigure(&previous).is_err());
        native_media_end_route(&previous);

        let replacement = native_media_begin_route(0, MEDIA_CODEC_H264, 1_280, 720, 30, 3_000_000)
            .expect("display replacement route");
        assert_eq!(replacement.display_revision, 2);
        assert!(replacement.connection_epoch > previous.connection_epoch);
        assert!(replacement.codec_epoch > previous.codec_epoch);

        native_media_end_route(&replacement);
        let generic_retry =
            native_media_begin_route(0, MEDIA_CODEC_H264, 1_280, 720, 30, 3_000_000)
                .expect("generic retry route");
        assert_eq!(generic_retry.display_revision, 2);

        let events = events.lock().unwrap();
        let started = events
            .iter()
            .filter(|event| event["eventType"] == "mediaDisplayReconfigureStarted")
            .collect::<Vec<_>>();
        assert_eq!(started.len(), 1);
        let marker = &started[0]["payload"];
        assert_eq!(marker["displayId"], 0);
        assert_eq!(marker["previousDisplayRevision"], 1);
        assert_eq!(marker["previousConnectionEpoch"], previous.connection_epoch);
        assert_eq!(marker["previousCodecEpoch"], previous.codec_epoch);
        assert!(marker["displayReconfigureGeneration"].as_u64().unwrap() > 0);

        let replacement_controls = events
            .iter()
            .filter(|event| {
                event["eventType"] == "mediaControl"
                    && event["payload"]["connectionEpoch"] == replacement.connection_epoch
                    && matches!(
                        event["payload"]["command"].as_str(),
                        Some("startCapture" | "reconfigure")
                    )
            })
            .collect::<Vec<_>>();
        assert_eq!(replacement_controls.len(), 2);
        for control in replacement_controls {
            assert_eq!(control["payload"]["displayRevision"], 2);
            assert_eq!(
                control["payload"]["displayReconfigure"]["displayReconfigureGeneration"],
                marker["displayReconfigureGeneration"]
            );
            assert_eq!(
                control["payload"]["displayReconfigure"]["previousDisplayRevision"],
                1
            );
            assert_eq!(
                control["payload"]["displayReconfigure"]["previousConnectionEpoch"],
                previous.connection_epoch
            );
            assert_eq!(
                control["payload"]["displayReconfigure"]["previousCodecEpoch"],
                previous.codec_epoch
            );
        }

        let generic_controls = events
            .iter()
            .filter(|event| {
                event["eventType"] == "mediaControl"
                    && event["payload"]["connectionEpoch"] == generic_retry.connection_epoch
            })
            .collect::<Vec<_>>();
        assert_eq!(generic_controls.len(), 2);
        assert!(generic_controls
            .iter()
            .all(|event| { event["payload"].get("displayReconfigure").is_none() }));
    }
}
