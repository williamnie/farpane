    #[test]
    fn native_viewer_display_catalog_fails_closed_on_malformed_inventory() {
        let captured = Mutex::new(Vec::<CapturedDisplayCatalogEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_display_catalog = Some(capture_display_catalog);
        shared.context = &captured as *const _ as usize;
        ui.shared.connection_epoch.store(9, Ordering::Release);
        ui.shared.active.store(true, Ordering::Release);

        let valid = vec![display_info("Main", 0, 0, 1920, 1080, true, 2.0)];
        ui.set_displays(&valid);
        ui.set_current_display(0);
        assert_eq!(ui.shared.video_catalog_binding(0), Some((9, 1)));

        let malformed = vec![display_info("bad\nname", 0, 0, 1920, 1080, true, 2.0)];
        ui.set_displays(&malformed);
        ui.set_displays(&malformed);
        assert_eq!(ui.shared.video_catalog_binding(0), None);
        assert_eq!(captured.lock().unwrap().len(), 3);
        assert_eq!(
            captured.lock().unwrap()[2],
            CapturedDisplayCatalogEvent {
                connection_epoch: 9,
                catalog_revision: 2,
                status: DISPLAY_CATALOG_STATUS_UNAVAILABLE,
                selected_display_index: None,
                entries: Vec::new(),
            }
        );

        assert!(normalized_native_viewer_display_catalog(&vec![display_info(
            "Main",
            0,
            0,
            1920,
            1080,
            true,
            f64::NAN,
        )])
        .is_none());
        assert!(normalized_native_viewer_display_catalog(
            &(0..=MAX_DISPLAY_CATALOG_ENTRIES)
                .map(|index| display_info(&format!("Display {index}"), 0, 0, 1, 1, true, 1.0))
                .collect::<Vec<_>>()
        )
        .is_none());

        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.set_displays(&valid);
        assert_eq!(captured.lock().unwrap().len(), 3);
    }

    #[test]
    fn native_viewer_display_selection_is_exact_single_flight_and_terminal() {
        let captured = Mutex::new(Vec::<CapturedDisplaySelectionEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_display_selection = Some(capture_display_selection);
        shared.context = &captured as *const _ as usize;
        ui.shared.connection_epoch.store(7, Ordering::Release);
        ui.shared.active.store(true, Ordering::Release);
        ui.shared.authenticated.store(true, Ordering::Release);
        let displays = vec![
            display_info("Main", 0, 0, 1920, 1080, true, 2.0),
            display_info("Studio", 1920, 0, 2560, 1440, true, 1.0),
        ];
        ui.shared.publish_display_catalog(&displays, Some(Some(0)));

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session)),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let client_pointer = &mut client as *mut RDNClient;
        let request = |command_id, catalog_revision, display_index| RDNDisplaySelectionRequest {
            abi_version: ABI_VERSION,
            connection_epoch: 7,
            command_id,
            catalog_revision,
            display_index,
        };

        let current = request(1, 1, 0);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &current) },
            0
        );
        assert!(receiver.try_recv().is_err());
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 1,
                catalog_revision: 1,
                display_index: 0,
                result: DISPLAY_SELECTION_RESULT_ALREADY_SELECTED,
                failure: DISPLAY_SELECTION_FAILURE_NONE,
            }]
        );

        let target = request(2, 1, 1);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &target) },
            0
        );
        let duplicate_while_pending = request(3, 1, 0);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &duplicate_while_pending) },
            -3
        );
        let mut sent_switch = false;
        while let Ok(data) = receiver.try_recv() {
            let Data::Message(message) = data else {
                continue;
            };
            let Some(message::Union::Misc(misc)) = message.union else {
                continue;
            };
            if let Some(misc::Union::SwitchDisplay(display)) = misc.union {
                sent_switch = display.display == 1;
            }
        }
        assert!(sent_switch);
        ui.switch_display(&SwitchDisplay {
            display: 1,
            width: 2560,
            height: 1440,
            ..Default::default()
        });
        assert_eq!(
            captured.lock().unwrap()[1],
            CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 2,
                catalog_revision: 1,
                display_index: 1,
                result: DISPLAY_SELECTION_RESULT_SELECTED,
                failure: DISPLAY_SELECTION_FAILURE_NONE,
            }
        );

        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &target) },
            -5
        );
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &duplicate_while_pending) },
            0
        );
        let mut changed = displays.clone();
        changed[1].width = 3008;
        ui.set_displays(&changed);
        assert_eq!(
            captured.lock().unwrap()[2],
            CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 3,
                catalog_revision: 1,
                display_index: 0,
                result: DISPLAY_SELECTION_RESULT_FAILED,
                failure: DISPLAY_SELECTION_FAILURE_CATALOG_CHANGED,
            }
        );

        let remote_drift = request(4, 2, 0);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &remote_drift) },
            0
        );
        ui.set_current_display(0);
        assert_eq!(
            captured.lock().unwrap()[3],
            CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 4,
                catalog_revision: 2,
                display_index: 0,
                result: DISPLAY_SELECTION_RESULT_FAILED,
                failure: DISPLAY_SELECTION_FAILURE_REMOTE_SELECTION_DRIFT,
            }
        );

        let mut stale_epoch = request(5, 2, 1);
        stale_epoch.connection_epoch = 6;
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &stale_epoch) },
            -10
        );
        let stale_revision = request(5, 1, 1);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &stale_revision) },
            -10
        );
        let out_of_range = request(5, 2, 9);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &out_of_range) },
            -5
        );

        let disconnect = request(5, 2, 1);
        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &disconnect) },
            0
        );
        client.disconnect(false);
        assert_eq!(
            captured.lock().unwrap()[4],
            CapturedDisplaySelectionEvent {
                connection_epoch: 7,
                command_id: 5,
                catalog_revision: 2,
                display_index: 1,
                result: DISPLAY_SELECTION_RESULT_FAILED,
                failure: DISPLAY_SELECTION_FAILURE_CONNECTION_CLOSED,
            }
        );

        assert_eq!(
            unsafe { rdn_client_select_display(client_pointer, &current) },
            -3
        );
    }

    #[test]
    fn viewer_remote_listing_owns_bounded_regular_entries() {
        let mut entries = vec![
            remote_list_entry(FileType::Dir, "资料", 0),
            remote_list_entry(FileType::File, "report.txt", 42),
        ];
        let listing = native_viewer_remote_listing(&entries).unwrap();
        entries[0].name = "changed".to_owned();
        assert_eq!(listing.len(), 2);
        assert_eq!(listing[0].kind, NativeViewerRemoteListEntryKind::Directory);
        assert_eq!(listing[0].relative_path, "资料");
        assert_eq!(listing[0].size, 0);
        assert_eq!(listing[1].kind, NativeViewerRemoteListEntryKind::File);
        assert_eq!(listing[1].relative_path, "report.txt");
        assert_eq!(listing[1].size, 42);
        assert_eq!(listing[1].modified_time, 123);
        assert_eq!(native_viewer_remote_listing(&[]), Some(Vec::new()));
    }

    #[test]
    fn viewer_remote_listing_rejects_unsafe_types_names_aliases_and_bounds() {
        for invalid_name in [
            "",
            ".",
            "..",
            "/absolute",
            "nested/file",
            "windows\\path",
            "bad\nname",
        ] {
            assert!(native_viewer_remote_listing(&[remote_list_entry(
                FileType::File,
                invalid_name,
                1,
            )])
            .is_none());
        }
        assert!(native_viewer_remote_listing(&[
            remote_list_entry(FileType::File, "Report.txt", 1),
            remote_list_entry(FileType::File, "report.TXT", 1),
        ])
        .is_none());
        assert!(native_viewer_remote_listing(&[remote_list_entry(
            FileType::File,
            "partial.FARPANE-PART",
            1,
        )])
        .is_none());

        let mut hidden = remote_list_entry(FileType::File, "hidden", 1);
        hidden.is_hidden = true;
        assert!(native_viewer_remote_listing(&[hidden]).is_none());
        assert!(native_viewer_remote_listing(&[remote_list_entry(
            FileType::Dir,
            "nonempty-dir",
            1,
        )])
        .is_none());
        assert!(
            native_viewer_remote_listing(&[remote_list_entry(FileType::FileLink, "link", 1,)])
                .is_none()
        );
        let mut unknown = remote_list_entry(FileType::File, "unknown", 1);
        unknown.entry_type = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert!(native_viewer_remote_listing(&[unknown]).is_none());

        let too_many: Vec<_> = (0..=MAX_FILE_TRANSFER_LIST_ENTRIES)
            .map(|index| remote_list_entry(FileType::File, &format!("file-{index}"), 1))
            .collect();
        assert!(native_viewer_remote_listing(&too_many).is_none());
        let oversized_name = "a".repeat(MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES + 1);
        assert!(native_viewer_remote_listing(&[remote_list_entry(
            FileType::File,
            &oversized_name,
            1,
        )])
        .is_none());
    }

    #[test]
    fn viewer_recursive_manifest_parts_are_owned_bounded_and_semantic() {
        let mut files = vec![
            remote_list_entry(FileType::File, "资料/report.txt", 42),
            remote_list_entry(FileType::File, "top.txt", 1),
        ];
        let listing = native_viewer_remote_manifest_files(&files).unwrap();
        files[0].name = "changed".to_owned();
        assert_eq!(listing[0].relative_path, "资料/report.txt");
        assert!(native_viewer_remote_manifest_files(&[remote_list_entry(
            FileType::Dir,
            "folder",
            0
        ),])
        .is_none());
        assert!(native_viewer_remote_manifest_files(&[remote_list_entry(
            FileType::File,
            "a/../escape",
            1
        ),])
        .is_none());

        let response = ReadEmptyDirsResponse {
            path: "/".to_owned(),
            empty_dirs: vec![FileDirectory {
                path: "/资料/empty".to_owned(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let directories = native_viewer_remote_manifest_empty_directories(&response).unwrap();
        assert_eq!(directories[0].relative_path, "资料/empty");
        assert_eq!(
            directories[0].kind,
            NativeViewerRemoteListEntryKind::Directory
        );

        let invalid = ReadEmptyDirsResponse {
            path: "/".to_owned(),
            empty_dirs: vec![FileDirectory {
                path: "/bad/../empty".to_owned(),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(native_viewer_remote_manifest_empty_directories(&invalid).is_none());
    }

    #[test]
    fn requests_capture_headroom_for_native_decoder() {
        let message = native_stream_configuration_message(native_stream_fps(false));
        let Some(message::Union::Misc(misc)) = message.union else {
            panic!("native stream configuration must be a Misc message");
        };
        let Some(misc::Union::Option(option)) = misc.union else {
            panic!("native stream configuration must carry an OptionMessage");
        };
        assert_eq!(option.custom_fps, 36);
        assert_eq!(native_stream_fps(true), 38);
    }

    #[test]
    fn maps_semantic_pointer_masks_without_exposing_wire_types() {
        assert_eq!(
            pointer_mask(RDNPointerKind::Down, POINTER_BUTTON_LEFT),
            Some(MOUSE_TYPE_DOWN | (MOUSE_BUTTON_LEFT << 3))
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::Up, POINTER_BUTTON_RIGHT),
            Some(MOUSE_TYPE_UP | (MOUSE_BUTTON_RIGHT << 3))
        );
        assert_eq!(pointer_mask(RDNPointerKind::Down, 0), None);
        assert_eq!(
            pointer_mask(
                RDNPointerKind::Move,
                POINTER_BUTTON_LEFT | POINTER_BUTTON_RIGHT
            ),
            Some(MOUSE_TYPE_MOVE | ((MOUSE_BUTTON_LEFT | MOUSE_BUTTON_RIGHT) << 3))
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::Scroll, 0),
            Some(MOUSE_TYPE_WHEEL)
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::Scroll, POINTER_BUTTON_LEFT),
            None
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::PreciseScroll, 0),
            Some(MOUSE_TYPE_TRACKPAD)
        );
        assert_eq!(
            pointer_mask(RDNPointerKind::PreciseScroll, POINTER_BUTTON_RIGHT),
            None
        );
        assert!(pointer_payload_fields_are_canonical(
            RDNPointerKind::Move,
            10,
            20,
            0,
            0
        ));
        assert!(!pointer_payload_fields_are_canonical(
            RDNPointerKind::Down,
            10,
            20,
            1,
            0
        ));
        assert!(pointer_payload_fields_are_canonical(
            RDNPointerKind::Scroll,
            0,
            0,
            3,
            -3
        ));
        assert!(!pointer_payload_fields_are_canonical(
            RDNPointerKind::PreciseScroll,
            1,
            0,
            3,
            -3
        ));
        assert_eq!(clamp_pointer_coordinates(-1, 200, (100, 50)), Some((0, 49)));
        assert_eq!(clamp_pointer_coordinates(0, 0, (0, 50)), None);
        assert_eq!(
            normalized_pointer_coordinates(RDNPointerKind::Scroll, 0, 0, 0, 0, (0, 0)),
            None
        );
        assert_eq!(
            normalized_pointer_coordinates(RDNPointerKind::PreciseScroll, 0, 0, 500, -500, (0, 0)),
            Some((120, -120))
        );
    }

    #[test]
    fn maps_basic_semantic_keys() {
        assert_eq!(
            key_name(RDNKeyCode::Character, 'a' as u32).as_deref(),
            Some("a")
        );
        assert_eq!(
            key_name(RDNKeyCode::Return, 0).as_deref(),
            Some("VK_RETURN")
        );
        assert_eq!(key_name(RDNKeyCode::Command, 0).as_deref(), Some("Meta"));
        assert!(key_name(RDNKeyCode::Character, 0).is_none());
        assert!(key_name(RDNKeyCode::Character, 0x11_0000).is_none());
        assert!(key_payload_fields_are_canonical(
            RDNKeyCode::Character,
            'a' as u32,
            0
        ));
        assert!(!key_payload_fields_are_canonical(
            RDNKeyCode::Character,
            'a' as u32,
            1
        ));
        assert!(key_payload_fields_are_canonical(RDNKeyCode::Return, 0, 0));
        assert!(!key_payload_fields_are_canonical(
            RDNKeyCode::Return,
            'a' as u32,
            0
        ));
        assert!(!key_payload_fields_are_canonical(RDNKeyCode::Return, 0, 1));
        assert!(key_payload_fields_are_canonical(
            RDNKeyCode::Physical,
            0,
            55
        ));
        assert!(!key_payload_fields_are_canonical(
            RDNKeyCode::Physical,
            'a' as u32,
            55
        ));
        assert_eq!(physical_macos_keycode(0), Some(0));
        assert_eq!(physical_macos_keycode(0x7f), Some(0x7f));
        assert_eq!(physical_macos_keycode(0x80), None);
    }

    #[test]
    fn gates_input_on_authentication_and_remote_permission() {
        assert!(!input_is_allowed(false, true));
        assert!(!input_is_allowed(false, false));
        assert!(!input_is_allowed(true, false));
        assert!(input_is_allowed(true, true));
    }

    #[test]
    fn gates_viewer_clipboard_receive_on_lifecycle_and_both_policies() {
        for missing in 0..4 {
            let mut gates = [true; 4];
            gates[missing] = false;
            assert!(!clipboard_receive_allowed(
                gates[0], gates[1], gates[2], gates[3]
            ));
        }
        assert!(clipboard_receive_allowed(true, true, true, true));
    }

    #[test]
    fn native_viewer_clipboard_permission_defaults_enabled_and_honors_explicit_revoke() {
        let ui = BridgeUi::default();
        assert!(ui.shared.remote_clipboard_enabled.load(Ordering::Acquire));

        ui.set_permission("clipboard", false);
        assert!(!ui.shared.remote_clipboard_enabled.load(Ordering::Acquire));

        ui.set_permission("clipboard", true);
        assert!(ui.shared.remote_clipboard_enabled.load(Ordering::Acquire));
    }

    #[test]
    fn native_viewer_rich_receive_preparse_gate_requires_every_authority() {
        let ui = BridgeUi::default();
        assert!(!ui.native_clipboard_rich_text_enabled());
        ui.shared.active.store(true, Ordering::Release);
        ui.shared.authenticated.store(true, Ordering::Release);
        ui.shared
            .receive_clipboard_rich_text
            .store(true, Ordering::Release);
        ui.shared
            .remote_clipboard_enabled
            .store(true, Ordering::Release);
        assert!(ui.native_clipboard_rich_text_enabled());

        for gate in [
            &ui.shared.active,
            &ui.shared.authenticated,
            &ui.shared.receive_clipboard_rich_text,
            &ui.shared.remote_clipboard_enabled,
        ] {
            gate.store(false, Ordering::Release);
            assert!(!ui.native_clipboard_rich_text_enabled());
            gate.store(true, Ordering::Release);
        }
    }
