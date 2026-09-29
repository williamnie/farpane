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
