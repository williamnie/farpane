use hbb_common::config::{Config, APP_NAME};

/// Runs before any configuration, IPC, desktop probing or logging is initialized.
pub fn initialize() -> bool {
    *APP_NAME.write().unwrap() = "FarPane".to_owned();
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("--farpane-paths")) {
        println!("{}", serde_json::json!({
            "app_name": "FarPane",
            "config_file": Config::path("FarPane.toml"),
            "main_ipc": Config::ipc_path(""),
            "service_ipc": Config::ipc_path("_service"),
            "dbus_name": "org.farpane.FarPane",
            "gpu_media_enabled_by_default": false,
            "gpu_media_compiled": cfg!(feature = "linux-gpu-media"),
        }));
        return false;
    }
    // The upstream auto ID is derived from the NIC, even with a separate config
    // directory. Never rename its server-side record: RustDesk may still own it.
    if Config::get_option("farpane-network-identity") != "1" {
        Config::update_id();
        Config::set_key_confirmed(false);
        Config::set_option("farpane-network-identity".into(), "1".into());
    }
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("--farpane-identity")) {
        println!("{}", serde_json::json!({
            "id": Config::get_id(),
            "identity_version": Config::get_option("farpane-network-identity"),
            "registration_uuid": hex::encode(crate::common::get_network_uuid()),
            "gpu_enabled": Config::get_option("linux-gpu-media") == "Y",
        }));
        return false;
    }
    true
}

/// Network identity only; hbb_common::get_uuid still supplies local encryption.
pub fn namespace_uuid(machine_uuid: &[u8]) -> Vec<u8> {
    use hbb_common::sha2::{Digest, Sha256};
    let mut hash = Sha256::new();
    hash.update(b"org.farpane.FarPane/network-identity/v1\0");
    hash.update(machine_uuid);
    hex::encode(&hash.finalize()[..16]).into_bytes()
}

#[cfg(test)]
mod tests {
    #[test]
    fn network_identity_is_stable_and_distinct_from_the_same_machine() {
        let machine = b"0123456789abcdef0123456789abcdef";
        let uuid = super::namespace_uuid(machine);
        assert_eq!(uuid.len(), 32);
        assert_ne!(uuid, machine);
        assert_eq!(uuid, super::namespace_uuid(machine));
        assert_ne!(uuid, super::namespace_uuid(b"another-machine"));
    }
}
