//! Native configuration commits, under the caller's lifetime owner lock.
//! Persist a recovery record before replacing either legacy TOML file. No
//! plaintext permanent password is serialized and no GTK/network code runs here.
use super::*;
use crate::{bail, ResultType};
use std::{
    fs::{File, OpenOptions},
    os::{
        fd::AsRawFd,
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    sync::atomic::{AtomicBool, Ordering},
};

const JOURNAL: &str = ".native-config-transaction.json";
const INITIALIZING: &str = ".native-new-install";
const INITIALIZING_MAGIC: &[u8] = b"farpane-native-init-1\n";
const LIMIT: u64 = 8 * 1024 * 1024;
static RECOVERY_REQUIRED: AtomicBool = AtomicBool::new(false);
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    schema: u32,
    identity: String,
    settings: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
    Prepared,
    Identity,
    Settings,
}
#[derive(Debug)]
struct NeedsRecovery;
impl std::fmt::Display for NeedsRecovery {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Prepared configuration transaction requires process recovery")
    }
}
impl std::error::Error for NeedsRecovery {}

pub fn recovery_required() -> bool {
    RECOVERY_REQUIRED.load(Ordering::Acquire)
}

/// Must run before the first CONFIG/CONFIG2 lazy load, after owner-lock and
/// previous-runtime checks. Names are fixed; journal data cannot redirect paths.
pub fn recover_before_load() -> ResultType<()> {
    if super::farpane_viewer::is_active() {
        bail!("Viewer configuration is read-only");
    }
    recover_at(Config::path("").as_path())
}
pub fn begin_new_install() -> ResultType<bool> {
    if super::farpane_viewer::is_active() {
        bail!("Viewer configuration is read-only");
    }
    begin_new_install_at(&Config::path(""))
}
pub fn finish_new_install() -> ResultType<()> {
    if super::farpane_viewer::is_active() {
        bail!("Viewer configuration is read-only");
    }
    Directory::open(&Config::path(""))?.remove(INITIALIZING)
}
fn begin_new_install_at(path: &Path) -> ResultType<bool> {
    let directory = Directory::open(path)?;
    match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(directory.path(INITIALIZING))
    {
        Ok(file) => {
            let meta = file.metadata()?;
            if !meta.is_file()
                || meta.uid() != unsafe { libc::geteuid() }
                || meta.mode() & 0o077 != 0
                || meta.nlink() != 1
                || meta.len() > 64
            {
                bail!("Unsafe initial configuration record");
            }
            let mut bytes = Vec::new();
            file.take(65).read_to_end(&mut bytes)?;
            if bytes != INITIALIZING_MAGIC {
                bail!("Invalid initial configuration record");
            }
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            if fs::symlink_metadata(directory.path("FarPane.toml")).is_ok()
                || fs::symlink_metadata(directory.path("FarPane2.toml")).is_ok()
            {
                return Ok(false);
            }
            Temporary::write(&directory, INITIALIZING_MAGIC)?.install(&directory, INITIALIZING)?;
            Ok(true)
        }
        Err(error) => Err(error.into()),
    }
}

pub fn commit(mut options: HashMap<String, String>, password: Option<&str>) -> ResultType<()> {
    if super::farpane_viewer::is_active() {
        bail!("Viewer configuration is read-only");
    }
    if recovery_required() {
        bail!("Native configuration requires recovery before further changes");
    }
    if password.is_some() && Config::is_disable_change_permanent_password() {
        bail!("Changing the permanent password is disabled by policy");
    }
    let preset = if password.is_some() {
        Some(Config::get_preset_password_storage_and_salt())
    } else {
        None
    };
    Config::purify_options(&mut options);
    let mut identity = CONFIG.write().unwrap();
    let mut settings = CONFIG2.write().unwrap();
    let mut next_identity = identity.clone();
    let mut next_settings = settings.clone();
    next_settings.options = options;
    let mut password_changed = false;
    if let Some(password) = password {
        let (preset_storage, preset_salt) = preset.unwrap();
        let already_preset = next_identity.password.is_empty()
            && preset_permanent_password_storage_matches_plain(
                &preset_storage,
                &preset_salt,
                password,
            );
        if !already_preset {
            let stored = if password.is_empty() {
                String::new()
            } else {
                Config::compute_permanent_password_storage_for_update(&mut next_identity, password)
                    .ok_or_else(|| anyhow!("Permanent password could not be prepared"))?
            };
            password_changed = next_identity.password != stored;
            next_identity.password = stored;
            if password_changed {
                next_settings.trusted_devices =
                    encrypt_str_or_original("[]", PASSWORD_ENC_VERSION, 1024 * 1024);
            }
        }
    }
    let stored_identity = identity_storage(&next_identity);
    let stored_settings = settings_storage(&next_settings);
    let record = Record {
        schema: 1,
        identity: toml::to_string_pretty(&stored_identity)
            .map_err(|_| anyhow!("Cannot serialize identity configuration"))?,
        settings: toml::to_string_pretty(&stored_settings)
            .map_err(|_| anyhow!("Cannot serialize application configuration"))?,
    };
    let directory = Config::path("");
    if let Err(error) = persist_at(&directory, &record, |_| Ok(())) {
        // Once the durable record exists, the caller must stop this process.
        // Continuing old background Config writers could race crash recovery.
        if error.downcast_ref::<NeedsRecovery>().is_some() {
            RECOVERY_REQUIRED.store(true, Ordering::Release);
        }
        return Err(error);
    }
    *identity = next_identity;
    *settings = next_settings;
    if password_changed {
        *TRUSTED_DEVICES.write().unwrap() = (Vec::new(), true);
    }
    Ok(())
}

fn identity_storage(value: &Config) -> Config {
    let mut config = value.clone();
    Config::prepare_config_for_store(&mut config);
    if !config.password.is_empty()
        && decode_permanent_password_h1_from_storage(&config.password).is_none()
    {
        let stored = Config::load_::<Config>("");
        config.password =
            keep_encrypted_storage_if_plaintext_unchanged(&config.password, &stored.password);
    }
    let (stored_id, encrypted, _) = decrypt_str_or_original(&config.enc_id, PASSWORD_ENC_VERSION);
    if !encrypted || stored_id != config.id {
        config.enc_id = encrypt_str_or_original(&config.id, PASSWORD_ENC_VERSION, ENCRYPT_MAX_LEN);
    }
    config.id.clear();
    config
}
fn settings_storage(value: &Config2) -> Config2 {
    let mut config = value.clone();
    let stored = Config::load_::<Config2>("2");
    if let Some(mut socks) = config.socks {
        let old = stored
            .socks
            .as_ref()
            .map(|s| s.password.as_str())
            .unwrap_or_default();
        socks.password = keep_encrypted_storage_if_plaintext_unchanged(&socks.password, old);
        config.socks = Some(socks);
    }
    config.unlock_pin =
        keep_encrypted_storage_if_plaintext_unchanged(&config.unlock_pin, &stored.unlock_pin);
    config
}

/// Open the directory once. renameat/unlinkat and temporary-file creation use
/// this same fd, so replacing a pathname cannot redirect a partially committed
/// transaction into a different directory.
struct Directory(File);
impl Directory {
    fn open(path: &Path) -> ResultType<Self> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        let meta = file.metadata()?;
        if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o022 != 0 {
            bail!("Unsafe configuration directory");
        }
        Ok(Self(file))
    }
    fn path(&self, name: &str) -> PathBuf {
        PathBuf::from(format!("/proc/self/fd/{}/{}", self.0.as_raw_fd(), name))
    }
    fn check_target(&self, name: &str) -> ResultType<()> {
        match fs::symlink_metadata(self.path(name)) {
            Ok(meta)
                if !meta.is_file()
                    || meta.uid() != unsafe { libc::geteuid() }
                    || meta.nlink() != 1 =>
            {
                bail!("Unexpected configuration target")
            }
            Ok(_) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }
    fn remove(&self, name: &str) -> ResultType<()> {
        fs::remove_file(self.path(name))?;
        self.0.sync_all()?;
        Ok(())
    }
    fn clean_temporary_files(&self) -> ResultType<()> {
        for entry in fs::read_dir(self.path(""))? {
            let entry = entry?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let Some(token) = name
                .strip_prefix(".native-config-")
                .and_then(|s| s.strip_suffix(".tmp"))
            else {
                continue;
            };
            if token.len() != 16 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
                continue;
            }
            let meta = fs::symlink_metadata(self.path(name))?;
            if meta.is_file()
                && meta.uid() == unsafe { libc::geteuid() }
                && meta.nlink() == 1
                && meta.mode() & 0o077 == 0
            {
                fs::remove_file(self.path(name))?;
            }
        }
        Ok(())
    }
}
struct Temporary {
    file: File,
    path: PathBuf,
}
impl Drop for Temporary {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}
impl Temporary {
    fn write(directory: &Directory, data: &[u8]) -> ResultType<Self> {
        if data.len() as u64 > LIMIT {
            bail!("Configuration exceeds the transaction size limit");
        }
        let path = directory.path(&format!(
            ".native-config-{:016x}.tmp",
            rand::random::<u64>()
        ));
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&path)?;
        let mut temporary = Self { file, path };
        temporary.file.write_all(data)?;
        temporary.file.sync_all()?;
        Ok(temporary)
    }
    fn install(self, directory: &Directory, name: &str) -> ResultType<()> {
        directory.check_target(name)?;
        // The open temporary fd also keeps the source alive until rename.
        self.file.sync_all()?;
        fs::rename(&self.path, directory.path(name))?;
        directory.0.sync_all()?;
        Ok(())
    }
}
fn persist_at(
    path: &Path,
    record: &Record,
    mut step: impl FnMut(Stage) -> ResultType<()>,
) -> ResultType<()> {
    let directory = Directory::open(path)?;
    for target in ["FarPane.toml", "FarPane2.toml", JOURNAL] {
        directory.check_target(target)?;
    }
    if directory.path(JOURNAL).exists() {
        return Err(anyhow!(NeedsRecovery));
    }
    let identity = Temporary::write(&directory, record.identity.as_bytes())?;
    let settings = Temporary::write(&directory, record.settings.as_bytes())?;
    let bytes = serde_json::to_vec(record)
        .map_err(|_| anyhow!("Cannot serialize configuration transaction"))?;
    if let Err(error) = Temporary::write(&directory, &bytes)?.install(&directory, JOURNAL) {
        return Err(if directory.path(JOURNAL).exists() {
            error.context(NeedsRecovery)
        } else {
            error
        });
    }
    let finish = (|| {
        step(Stage::Prepared)?;
        identity.install(&directory, "FarPane.toml")?;
        step(Stage::Identity)?;
        settings.install(&directory, "FarPane2.toml")?;
        step(Stage::Settings)?;
        directory.remove(JOURNAL)
    })();
    finish.map_err(|error| error.context(NeedsRecovery))
}
fn recover_at(path: &Path) -> ResultType<()> {
    let directory = Directory::open(path)?;
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(directory.path(JOURNAL))
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return directory.clean_temporary_files()
        }
        Err(error) => return Err(error.into()),
    };
    let meta = file.metadata()?;
    if !meta.is_file()
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
        || meta.nlink() != 1
        || meta.len() > LIMIT
    {
        bail!("Unsafe configuration recovery record");
    }
    let mut bytes = Vec::new();
    file.take(LIMIT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > LIMIT {
        bail!("Configuration recovery record is too large");
    }
    let record: Record = serde_json::from_slice(&bytes)
        .map_err(|_| anyhow!("Invalid configuration recovery record"))?;
    if record.schema != 1 {
        bail!("Unsupported configuration recovery record");
    }
    let _: Config =
        toml::from_str(&record.identity).map_err(|_| anyhow!("Invalid identity recovery data"))?;
    let _: Config2 =
        toml::from_str(&record.settings).map_err(|_| anyhow!("Invalid settings recovery data"))?;
    // Replaying is idempotent after a crash at any installation step.
    Temporary::write(&directory, record.identity.as_bytes())?
        .install(&directory, "FarPane.toml")?;
    Temporary::write(&directory, record.settings.as_bytes())?
        .install(&directory, "FarPane2.toml")?;
    directory.remove(JOURNAL)?;
    directory.clean_temporary_files()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "farpane-transaction-{name}-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        fs::create_dir(&root).unwrap();
        root
    }
    fn record() -> Record {
        Record {
            schema: 1,
            identity: toml::to_string(&Config {
                enc_id: "test-encrypted-id".into(),
                ..Default::default()
            })
            .unwrap(),
            settings: toml::to_string(&Config2 {
                options: HashMap::from([
                    ("farpane-native-revision".into(), "7".into()),
                    (
                        "verification-method".into(),
                        "use-permanent-password".into(),
                    ),
                ]),
                ..Default::default()
            })
            .unwrap(),
        }
    }
    #[test]
    fn interrupted_first_start_retains_defaults_without_resetting_existing_installs() {
        let root = root("first-start");
        assert!(begin_new_install_at(&root).unwrap());
        fs::write(root.join("FarPane.toml"), "partial first start").unwrap();
        assert!(begin_new_install_at(&root).unwrap());
        Directory::open(&root)
            .unwrap()
            .remove(INITIALIZING)
            .unwrap();
        assert!(!begin_new_install_at(&root).unwrap());
        fs::remove_file(root.join("FarPane.toml")).unwrap();
        fs::write(root.join("FarPane2.toml"), "existing preferences").unwrap();
        assert!(!begin_new_install_at(&root).unwrap());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn every_interrupted_commit_rolls_forward_before_config_load() {
        for stop in [Stage::Prepared, Stage::Identity, Stage::Settings] {
            let root = root("crash");
            let record = record();
            fs::write(root.join("FarPane.toml"), "old identity").unwrap();
            fs::write(root.join("FarPane2.toml"), "old settings").unwrap();
            assert!(persist_at(&root, &record, |stage| if stage == stop {
                bail!("simulated crash")
            } else {
                Ok(())
            })
            .is_err());
            assert!(root.join(JOURNAL).is_file());
            recover_at(&root).unwrap();
            recover_at(&root).unwrap();
            assert_eq!(
                fs::read_to_string(root.join("FarPane.toml")).unwrap(),
                record.identity
            );
            assert_eq!(
                fs::read_to_string(root.join("FarPane2.toml")).unwrap(),
                record.settings
            );
            assert!(!root.join(JOURNAL).exists());
            assert_eq!(
                fs::metadata(root.join("FarPane.toml")).unwrap().mode() & 0o777,
                0o600
            );
            fs::remove_dir_all(root).unwrap();
        }
    }
    #[test]
    fn invalid_targets_and_corrupt_journals_do_not_overwrite_identity() {
        let root = root("invalid");
        fs::write(root.join("FarPane.toml"), "unchanged").unwrap();
        fs::create_dir(root.join("FarPane2.toml")).unwrap();
        assert!(persist_at(&root, &record(), |_| Ok(())).is_err());
        assert!(!root.join(JOURNAL).exists());
        fs::remove_dir(root.join("FarPane2.toml")).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::write(root.join(JOURNAL), b"{bad: secret payload}").unwrap();
        fs::set_permissions(root.join(JOURNAL), fs::Permissions::from_mode(0o600)).unwrap();
        let error = recover_at(&root).unwrap_err();
        assert!(!error.to_string().contains("secret payload"));
        assert_eq!(
            fs::read_to_string(root.join("FarPane.toml")).unwrap(),
            "unchanged"
        );
        fs::remove_dir_all(root).unwrap();
    }
}
