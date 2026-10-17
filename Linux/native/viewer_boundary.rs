//! Integration checks run in a disposable child because Viewer config mode is
//! irreversible. All files and IPC endpoints belong to the isolated container.
#[cfg(test)]
mod tests {
    use hbb_common::config::{farpane_viewer, Config};
    #[test]
    fn viewer_network_snapshot_and_session_preferences_do_not_access_host() {
        let root = std::env::temp_dir().join(format!(
            "farpane-viewer-boundary-{:016x}",
            hbb_common::rand::random::<u64>()
        ));
        std::fs::create_dir(&root).unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "farpane_native::viewer_boundary::tests::isolated_child",
                "--nocapture",
            ])
            .env("FARPANE_VIEWER_BOUNDARY_TEST", "1")
            .env("XDG_CONFIG_HOME", &root)
            .output()
            .unwrap();
        let entries = std::fs::read_dir(&root).unwrap().count();
        std::fs::remove_dir_all(root).unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(entries, 0, "Viewer created configuration state");
    }
    #[test]
    fn isolated_child() {
        if std::env::var("FARPANE_VIEWER_BOUNDARY_TEST").as_deref() != Ok("1") {
            return;
        }
        farpane_viewer::seed(
            "viewer-public-id".into(),
            "127.0.0.1:21116".into(),
            "127.0.0.1:21117".into(),
            "public-test-key".into(),
            false,
        )
        .unwrap();
        let runtime = hbb_common::tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            assert_eq!(crate::common::get_key(false).await, "public-test-key");
            let server = crate::common::get_rendezvous_server(100).await;
            assert_eq!(server.0, "127.0.0.1:21116");
            assert_eq!(crate::common::get_nat_type(100).await, 0);
            for postfix in ["", "_cm", "_service", "_drm", "_pa"] {
                let error = crate::ipc::connect(100, postfix).await.err().unwrap();
                assert_eq!(error.to_string(), "Viewer cannot access Host IPC");
                assert_eq!(
                    crate::ipc::new_listener(postfix)
                        .await
                        .err()
                        .unwrap()
                        .to_string(),
                    "Viewer cannot access Host IPC"
                );
                assert_eq!(
                    crate::ipc::connect_for_uid(100, 0, postfix)
                        .await
                        .err()
                        .unwrap()
                        .to_string(),
                    "Viewer cannot access Host IPC"
                );
            }
        });
        let mut handler = crate::client::LoginConfigHandler::default();
        handler.initialize(
            "123456".into(),
            hbb_common::rendezvous_proto::ConnType::DEFAULT_CONN,
            None,
            false,
            None,
            None,
            None,
        );
        handler.set_option("native-session-test".into(), "memory-only".into());
        assert_eq!(
            handler
                .load_config()
                .options
                .get("native-session-test")
                .map(String::as_str),
            Some("memory-only")
        );
        let mut preferences = handler.load_config();
        preferences.password = vec![1, 2, 3];
        handler.remember = true;
        handler.save_config(preferences);
        assert!(!handler.remember);
        assert!(handler.load_config().password.is_empty());
        assert_eq!(Config::get_id(), "viewer-public-id");
        assert!(hbb_common::config::farpane::recover_before_load().is_err());
        assert!(hbb_common::config::farpane::begin_new_install().is_err());
    }
}
