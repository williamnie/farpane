
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
