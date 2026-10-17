//! The Viewer is a disposable, read-only configuration consumer. Activate this
//! before any legacy lazy config; feed it only the authenticated GUI snapshot.
use super::*;
use crate::{bail, ResultType};
use std::sync::atomic::{AtomicU8, Ordering};

static MODE: AtomicU8 = AtomicU8::new(0);

pub fn is_active() -> bool {
    MODE.load(Ordering::Acquire) == 2
}

/// The first legacy load/store fixes this process as a normal config owner;
/// seeding a Viewer afterwards is rejected, without relying on lazy internals.
pub(super) fn access_is_read_only() -> bool {
    matches!(
        MODE.compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire),
        Err(2)
    )
}

pub fn seed(
    local_id: String,
    rendezvous: String,
    relay: String,
    public_key: String,
    force_relay: bool,
) -> ResultType<()> {
    if local_id.is_empty()
        || local_id.len() > 128
        || [&local_id, &rendezvous, &relay, &public_key]
            .iter()
            .any(|s| s.len() > 4096 || s.chars().any(char::is_control))
    {
        bail!("Invalid Viewer configuration snapshot");
    }
    if MODE
        .compare_exchange(0, 2, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        bail!("Viewer configuration must be seeded once, before configuration access");
    }
    *APP_NAME.write().unwrap() = "FarPane".into();
    *CONFIG.write().unwrap() = Config {
        id: local_id,
        ..Default::default()
    };
    *CONFIG2.write().unwrap() = Config2 {
        options: HashMap::from([
            ("custom-rendezvous-server".into(), rendezvous),
            ("relay-server".into(), relay),
            ("key".into(), public_key),
            (
                "force-always-relay".into(),
                if force_relay { "Y" } else { "" }.into(),
            ),
        ]),
        ..Default::default()
    };
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    // A separate process is essential: native read-only mode never resets and
    // must be set before lazy statics, regardless of the test runner's order.
    #[test]
    fn legacy_viewer_config_cannot_read_or_overwrite_host_files() {
        let root = std::env::temp_dir().join(format!(
            "farpane-viewer-config-{:016x}",
            rand::random::<u64>()
        ));
        fs::create_dir(&root).unwrap();
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "config::farpane_viewer::tests::isolated_child",
                "--nocapture",
            ])
            .env("FARPANE_VIEWER_CONFIG_TEST", &root)
            .env("XDG_CONFIG_HOME", &root)
            .output()
            .unwrap();
        fs::remove_dir_all(root).unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn isolated_child() {
        let Ok(root) = std::env::var("FARPANE_VIEWER_CONFIG_TEST") else {
            return;
        };
        *APP_NAME.write().unwrap() = "FarPane".into();
        let paths = [
            Config::file_(""),
            Config::file_("2"),
            Config::file_("_local"),
            PeerConfig::path("123456"),
        ];
        let fixtures = [
            "id = 'original-host-id'\npassword = 'never-import-host-secret'\n",
            "[options]\ncustom-rendezvous-server = 'old.invalid:21116'\n",
            "[options]\naccess_token = 'never-import-token'\nallow-auto-record-outgoing = 'Y'\n",
            "password = [1, 2, 3]\n[options]\nos-password = 'never-import-peer-secret'\nauto-login = 'Y'\n",
        ];
        for (path, content) in paths.iter().zip(fixtures) {
            assert!(path.starts_with(&root));
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, content).unwrap();
        }
        seed(
            "snapshot-id".into(),
            "server.invalid:21116".into(),
            "relay.invalid:21117".into(),
            "public-key".into(),
            true,
        )
        .unwrap();
        assert_eq!(Config::get_id(), "snapshot-id");
        assert_eq!(Config::get_option("key"), "public-key");
        assert_eq!(
            Config::get_option("custom-rendezvous-server"),
            "server.invalid:21116"
        );
        assert!(Config::get().password.is_empty());
        assert!(Config2::get().unlock_pin.is_empty());
        assert!(LocalConfig::get_option("access_token").is_empty());
        let mut peer = PeerConfig::load("123456");
        assert!(peer.password.is_empty());
        assert!(!peer.options.contains_key("os-password"));
        assert!(!peer.lock_after_session_end.v);
        peer.password = vec![7, 8, 9];
        peer.store("123456");
        PeerConfig::remove("123456");
        // Loading a malformed peer used to delete it through batch_peers.
        PeerConfig::batch_peers(
            &vec![("123456".into(), SystemTime::now(), paths[3].clone())],
            0,
            None,
        );
        assert!(PeerConfig::peers(None).is_empty());
        Config::set_option("key".into(), "memory-only-change".into());
        LocalConfig::set_option("example".into(), "memory-only-change".into());
        assert!(store_path(paths[0].clone(), Config::default()).is_err());
        assert!(farpane::commit(HashMap::new(), Some("never-store-this")).is_err());
        for (path, content) in paths.iter().zip(fixtures) {
            assert_eq!(fs::read_to_string(path).unwrap(), content);
        }
        assert!(seed(
            "second-id".into(),
            String::new(),
            String::new(),
            String::new(),
            false
        )
        .is_err());
    }
}
