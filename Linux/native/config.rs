use farpane_protocol::{
    Authentication, Command, Permissions, RecoveryPhase, Role, ServerSettings, SharingSettings,
    Snapshot,
};
use hbb_common::{
    bail,
    config::{self, Config, APP_NAME},
    libc, ResultType,
};
use std::{
    fs::{self, File, OpenOptions},
    os::{
        fd::AsRawFd,
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    sync::Mutex,
};

static TRANSACTION: Mutex<()> = Mutex::new(());
const REVISION: &str = "farpane-native-revision";
const DEVICES: &str = "farpane-native-devices";

fn server_settings() -> ServerSettings {
    ServerSettings {
        rendezvous: Config::get_option("custom-rendezvous-server"),
        relay: Config::get_option("relay-server"),
        public_key: Config::get_option("key"),
        force_relay: Config::get_option("always-relay") == "Y",
    }
}

/// Held before the first lazy Config access and for the lifetime of its writer.
pub struct OwnerLock {
    _file: File,
}
impl OwnerLock {
    pub fn acquire() -> ResultType<Self> {
        *APP_NAME.write().unwrap() = "FarPane".into();
        let path = Config::path(".native-owner.lock");
        let parent = path
            .parent()
            .ok_or_else(|| hbb_common::anyhow::anyhow!("Invalid config directory"))?;
        fs::create_dir_all(parent)?;
        let meta = fs::symlink_metadata(parent)?;
        if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o022 != 0 {
            bail!("Unsafe FarPane configuration directory");
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        let meta = file.metadata()?;
        if !meta.is_file()
            || meta.uid() != unsafe { libc::geteuid() }
            || meta.mode() & 0o077 != 0
            || meta.nlink() != 1
        {
            bail!("Unsafe FarPane configuration lock");
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        // The previous Flutter product does not take this new lock. Refuse
        // concurrent migration while its own FarPane endpoints are listening.
        // Original RustDesk uses a different namespace and is never contacted.
        let mut endpoints = vec!["", "_cm"];
        if unsafe { libc::geteuid() } == 0 {
            endpoints.push("_service");
        }
        for postfix in endpoints {
            match farpane_protocol::transport::connect(std::path::Path::new(&Config::ipc_path(postfix))) {
                Ok(_) => bail!("An existing FarPane runtime is active; complete its coordinated upgrade before using native configuration"),
                Err(error) if matches!(error.kind(), std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused) => {},
                Err(_) => bail!("Cannot establish whether the existing FarPane runtime is stopped; configuration is unchanged"),
            }
        }
        Ok(Self { _file: file })
    }
}

pub fn initialize() -> ResultType<()> {
    config::farpane::recover_before_load()?;
    let fresh = config::farpane::begin_new_install()?;
    let migrate = Config::get_option("farpane-network-identity") != "1";
    crate::platform::linux::farpane::initialize();
    // Only genuinely new identities get new-install defaults. Existing settings
    // are not reset just because the presentation layer is being replaced.
    if fresh {
        let mut options = Config::get_options();
        for (key, value) in [
            ("stop-service", "Y"),
            ("approve-mode", "click"),
            ("access-mode", "custom"),
            ("enable-keyboard", "Y"),
            ("enable-audio", "N"),
            ("enable-clipboard", "N"),
            ("enable-file-transfer", "N"),
        ] {
            options.insert(key.into(), value.into());
        }
        config::farpane::commit(options, None)?;
        config::farpane::finish_new_install()?;
    } else if migrate {
        config::farpane::commit(Config::get_options(), None)?;
    }
    Ok(())
}
pub fn revision() -> u64 {
    Config::get_option(REVISION).parse().unwrap_or(0)
}

pub fn snapshot(role: Role) -> Snapshot {
    let _transaction = TRANSACTION.lock().unwrap();
    let mode = if Config::get_option("approve-mode") == "click" {
        Authentication::Approval
    } else {
        match Config::get_option("verification-method").as_str() {
            "use-permanent-password" => Authentication::Permanent,
            "use-temporary-password" => Authentication::Temporary,
            _ => Authentication::Both,
        }
    };
    let permissions = Permissions {
        keyboard: crate::Connection::is_permission_enabled_locally("enable-keyboard"),
        clipboard: crate::Connection::is_permission_enabled_locally("enable-clipboard"),
        audio: crate::Connection::is_permission_enabled_locally("enable-audio"),
        file: crate::Connection::is_permission_enabled_locally("enable-file-transfer"),
    };
    let mut result = Snapshot {
        revision: revision(),
        role: Some(role),
        local_id: Config::get_id(),
        host_enabled: Config::get_option("stop-service") != "Y",
        registered: role == Role::Agent && config::get_online_state() > 0,
        authentication: mode,
        permanent_password_set: Config::has_permanent_password(),
        temporary_password: if role == Role::Agent
            && matches!(mode, Authentication::Temporary | Authentication::Both)
        {
            Some(farpane_protocol::Secret(
                hbb_common::password_security::temporary_password(),
            ))
        } else {
            None
        },
        server: server_settings(),
        sharing: SharingSettings {
            permissions,
            clipboard: super::host_clipboard::settings().unwrap_or_default(),
            audio_source: Config::get_option("farpane-audio-source"),
            microphone: Config::get_option("farpane-audio-microphone") == "Y",
            receive_directory: Config::get_option("farpane-files-root"),
            confirm_files: Config::get_option("farpane-files-confirm") != "N",
            ..Default::default()
        },
        clipboard_detail: super::host_clipboard::detail(),
        audio_needs_selection: super::audio::needs_source_selection(),
        gpu_enabled: Config::get_option("linux-gpu-media") == "Y",
        capabilities: vec![
            "configuration".into(),
            "host-authentication".into(),
            "host-gpu-control".into(),
        ],
        ..Default::default()
    };
    match farpane_protocol::devices::Catalog::load(&Config::get_option(DEVICES))
        .and_then(|catalog| catalog.visible(&result.server))
    {
        Ok(devices) => result.devices = devices,
        Err(error) => result.unavailable.push(format!("Device history: {error}")),
    }
    if role == Role::Agent {
        result.desktop = super::desktop::status();
        result.recovery = super::recovery::status();
        result.registered &= result.host_enabled
            && !matches!(
                result.recovery.phase,
                RecoveryPhase::Suspended
                    | RecoveryPhase::WaitingNetwork
                    | RecoveryPhase::Waiting
                    | RecoveryPhase::Registering
                    | RecoveryPhase::WaitingServer
            );
        let audio = super::audio::status();
        result.audio_sources = audio.sources;
        result.audio_error = audio.error;
        result.audio_capture = audio.capture;
        result.inbound = super::cm::connections();
        result.file_tasks = super::files::snapshot();
        result.capabilities.push("inbound-approval".into());
        #[cfg(feature = "linux-gpu-media")]
        if let Ok(status) =
            serde_json::from_str::<serde_json::Value>(&crate::platform::linux::gpu_status::json())
        {
            result.media_backend = status["backend"].as_str().unwrap_or("unavailable").into();
            result.media_reason = status["reason"].as_str().unwrap_or_default().into();
        }
    } else {
        result.media_backend = "unavailable".into();
    }
    result
}

pub fn recover_registration(expected_revision: u64) -> bool {
    let _transaction = TRANSACTION.lock().unwrap();
    if revision() != expected_revision
        || Config::get_option("stop-service") == "Y"
        || !super::recovery::begin_registration()
    {
        return false;
    }
    Config::reset_online();
    crate::RendezvousMediator::restart();
    true
}

pub fn apply(command: &Command, role: Role) -> ResultType<u64> {
    let _transaction = TRANSACTION.lock().unwrap();
    if !command.allowed_for(role) {
        bail!("Command is unavailable for this core role");
    }
    let expected = match command {
        Command::SetHost { revision, .. }
        | Command::SetServer { revision, .. }
        | Command::SetAuthentication { revision, .. }
        | Command::SetGpu { revision, .. }
        | Command::SetHostAudio { revision, .. }
        | Command::SetHostFiles { revision, .. }
        | Command::SetHostClipboard { revision, .. } => *revision,
        Command::RememberDevice { revision, .. }
        | Command::SetDevice { revision, .. }
        | Command::ForgetDevice { revision, .. } => *revision,
        _ => bail!("Not a configuration command"),
    };
    if expected != revision() {
        bail!("Configuration changed; refresh the current settings before saving");
    }
    let revision = expected
        .checked_add(1)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Revision exhausted"))?;
    let mut options = Config::get_options();
    let mut put = |key: &str, value: String| {
        options.insert(key.to_string(), value);
    };
    match command {
        Command::SetHost { enabled, .. } => {
            put("stop-service", if *enabled { "" } else { "Y" }.into())
        }
        Command::SetServer { settings, .. } => {
            farpane_protocol::devices::validate_server(settings)
                .map_err(hbb_common::anyhow::Error::msg)?;
            put("custom-rendezvous-server", settings.rendezvous.clone());
            put("relay-server", settings.relay.clone());
            put("key", settings.public_key.clone());
            put(
                "always-relay",
                if settings.force_relay { "Y" } else { "" }.into(),
            );
        }
        Command::SetAuthentication { mode, password, .. } => {
            if let Some(password) = password {
                if password.0.len() > 1024 {
                    bail!("Password exceeds the allowed length");
                }
            }
            put(
                "approve-mode",
                if *mode == Authentication::Approval {
                    "click"
                } else {
                    "password"
                }
                .into(),
            );
            put(
                "verification-method",
                match mode {
                    Authentication::Permanent => "use-permanent-password",
                    Authentication::Temporary => "use-temporary-password",
                    Authentication::Both => "use-both-passwords",
                    Authentication::Approval => "use-permanent-password",
                }
                .into(),
            );
        }
        Command::SetGpu { enabled, retry, .. } => {
            put("linux-gpu-media", if *enabled { "Y" } else { "" }.into());
            if *retry {
                put("linux-gpu-retry", revision.to_string());
            }
        }
        Command::SetHostAudio {
            enabled,
            source,
            microphone,
            ..
        } => {
            if source.len() > 512 || source.chars().any(char::is_control) {
                bail!("Invalid audio source identifier");
            }
            if *microphone && source.is_empty() {
                bail!("Select a specific microphone before granting consent");
            }
            put("enable-audio", if *enabled { "Y" } else { "N" }.into());
            put(
                "farpane-audio-enabled",
                if *enabled { "Y" } else { "N" }.into(),
            );
            put("farpane-audio-source", source.clone());
            put("farpane-audio-choice", "1".into());
            put(
                "farpane-audio-microphone",
                if *microphone { "Y" } else { "N" }.into(),
            );
        }
        Command::SetHostFiles {
            enabled,
            directory,
            confirm,
            ..
        } => {
            if directory.len() > 4096
                || directory.chars().any(char::is_control)
                || (!directory.is_empty() && !std::path::Path::new(directory).is_absolute())
            {
                bail!("Choose an absolute shared directory");
            }
            if *enabled {
                farpane_files::Root::provision(std::path::Path::new(directory))?;
            }
            // Leave the old runtime's unconstrained file policy unchanged.
            put(
                "farpane-files-enabled",
                if *enabled { "Y" } else { "N" }.into(),
            );
            put("farpane-files-root", directory.clone());
            put(
                "farpane-files-confirm",
                if *confirm { "Y" } else { "N" }.into(),
            );
            put("farpane-files-generation", revision.to_string());
        }
        Command::SetHostClipboard { policy, .. } => {
            put(super::host_clipboard::KEY, serde_json::to_string(policy)?);
            put(super::host_clipboard::GENERATION, revision.to_string());
        }
        Command::RememberDevice { .. }
        | Command::SetDevice { .. }
        | Command::ForgetDevice { .. } => {
            use farpane_protocol::devices::Catalog;
            let mut catalog = Catalog::load(&Config::get_option(DEVICES))
                .map_err(hbb_common::anyhow::Error::msg)?;
            let current = server_settings();
            match command {
                Command::RememberDevice {
                    peer, server, name, ..
                } => {
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)?
                        .as_secs();
                    catalog.remember_named(server, peer, name, now)
                }
                Command::SetDevice {
                    peer,
                    alias,
                    favorite,
                    ..
                } => catalog.edit(&current, peer, alias, *favorite),
                Command::ForgetDevice { peer, .. } => catalog.forget(&current, peer),
                _ => unreachable!(),
            }
            .map_err(hbb_common::anyhow::Error::msg)?;
            put(
                DEVICES,
                catalog.store().map_err(hbb_common::anyhow::Error::msg)?,
            );
        }
        _ => unreachable!(),
    }
    options.insert(REVISION.into(), revision.to_string());
    let restart = if role == Role::Agent {
        Some(crate::ipc::CheckIfRestart::new())
    } else {
        None
    };
    let password = match command {
        Command::SetAuthentication { password, .. } => password.as_ref().map(|p| p.0.as_str()),
        _ => None,
    };
    if let Err(error) = config::farpane::commit(options, password) {
        if config::farpane::recovery_required() {
            hbb_common::log::error!("Configuration commit was interrupted after prepare; exiting for recovery before further configuration access");
            std::process::exit(74);
        }
        return Err(error);
    }
    drop(restart);
    if let Command::SetHostClipboard { policy, .. } = command {
        if role == Role::Agent {
            super::host_clipboard::reload();
            if !policy.any(farpane_protocol::clipboard::Direction::Send)
                && !policy.any(farpane_protocol::clipboard::Direction::Receive)
            {
                for client in super::cm::connections() {
                    super::host_clipboard::revoke(client.id);
                    if client.permissions.clipboard {
                        crate::ui_cm_interface::switch_permission(
                            client.id,
                            "clipboard".into(),
                            false,
                        );
                    }
                }
            }
            super::host_clipboard::barrier()?;
        }
    }
    if let Command::SetHostAudio { enabled, .. } = command {
        if role == Role::Agent {
            crate::audio_service::restart();
            if !enabled {
                for client in super::cm::connections() {
                    if client.permissions.audio {
                        crate::ui_cm_interface::switch_permission(client.id, "audio".into(), false);
                    }
                }
            }
        }
    }
    if let Command::SetHostFiles { enabled: false, .. } = command {
        if role == Role::Agent {
            for client in super::cm::connections() {
                if client.permissions.file {
                    crate::ui_cm_interface::switch_permission(client.id, "file".into(), false);
                }
            }
        }
    }
    Ok(revision)
}
