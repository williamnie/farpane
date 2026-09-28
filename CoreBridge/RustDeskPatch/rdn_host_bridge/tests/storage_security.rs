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
