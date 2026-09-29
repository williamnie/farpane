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
