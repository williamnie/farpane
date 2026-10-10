
    use super::*;

    #[test]
    fn native_viewer_advertises_h264_on_login_and_codec_refresh() {
        let handler = crate::client::LoginConfigHandler::default();
        let login = handler.get_supported_decoding();
        let refresh = handler.update_supported_decodings();
        let Some(message::Union::Misc(misc)) = refresh.union else {
            panic!("codec refresh must carry an option message");
        };
        let refreshed = misc.option().supported_decoding.as_ref().unwrap().clone();

        for decoding in [login, refreshed] {
            // Linux 只有 H.264 编码时仍须有共同格式；保留 Mac 的 HEVC 能力。
            assert!(decoding.ability_h264 > 0, "H.264-only hosts need a common codec");
            assert!(decoding.ability_h265 > 0, "HEVC hosts must remain supported");
            assert_eq!(decoding.ability_vp8, 0);
            assert_eq!(decoding.ability_vp9, 0);
            assert_eq!(decoding.ability_av1, 0);
        }
    }

    unsafe extern "C" fn capture_state(
        context: *mut c_void,
        state: RDNState,
        code: i32,
        message: *const c_char,
    ) {
        if context.is_null() || message.is_null() {
            return;
        }
        let capture = &*(context as *const Mutex<Vec<(u32, i32, String)>>);
        capture.lock().unwrap().push((
            state as u32,
            code,
            CStr::from_ptr(message).to_string_lossy().into_owned(),
        ));
    }

    #[test]
    fn viewer_terminal_error_state_preserves_retry_authority() {
        assert_eq!(
            viewer_terminal_error_state("Closed manually by the peer", false),
            (TERMINAL_NO_RETRY_CODE, "connection-peer-closed")
        );
        assert_eq!(
            viewer_terminal_error_state("Timeout", true),
            (10, "connection-timeout")
        );
        assert_eq!(
            viewer_terminal_error_state("Connection reset", true),
            (11, "connection-reset")
        );
    }

    #[test]
    fn viewer_temporary_offline_does_not_disable_recovery() {
        let states = Mutex::new(Vec::<(u32, i32, String)>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_state = Some(capture_state);
        shared.context = &states as *const _ as usize;
        shared.active.store(true, Ordering::Release);
        let session: Session<BridgeUi> = Session {
            ui_handler: ui.clone(),
            ..Default::default()
        };
        // 经过真实上游分类：离线会给 UI retry=false，但不能终止有界恢复。
        crate::client::Interface::msgbox(
            &session,
            "error",
            "Connection Error",
            "Remote desktop is offline",
            "",
        );
        assert!(ui.shared.terminal_retry_allowed.load(Ordering::Acquire));
        assert_eq!(
            states.lock().unwrap().as_slice(),
            &[(
                RDNState::Error as u32,
                16,
                "connection-peer-offline".to_owned()
            )]
        );
        assert_eq!(
            viewer_terminal_error_state("Remote desktop is offline", true),
            (16, "connection-peer-offline")
        );
    }

    #[test]
    fn viewer_endpoint_transport_errors_are_retryable() {
        // pinned hbb_common::tcp::FramedStream::new 的实际错误格式。
        for endpoint in [
            "192.0.2.1:21116",
            "[2001:db8::1]:21116",
            "rendezvous.example.com:21116",
        ] {
            assert_eq!(
                viewer_transient_connect_error(&format!(
                    "Failed to connect to {endpoint}: Please try later"
                )),
                Some((17, "connection-establishment-failed")),
                "{endpoint}"
            );
        }
    }

    #[test]
    fn viewer_transient_connection_failures_keep_retry_through_upstream_callbacks() {
        for text in [
            "Failed to connect to rendezvous server",
            "Failed to connect via rendezvous server",
            "Failed to connect to relay server",
            "Failed to make direct connection to remote desktop",
            "Failed to connect via relay server: Timeout",
            "Failed to connect via relay server: deadline has elapsed",
            "Failed to connect via relay server: Failed to connect to rendezvous server",
            "Failed to connect via relay server: Failed to connect to relay server",
            "Failed to connect to 192.0.2.1:21116",
            "Failed to connect to [2001:db8::1]:21116",
            "Failed to connect to rendezvous.example.com:21116",
            "Failed to connect to localhost:21116",
        ] {
            for suffix in ["", ": Please try later"] {
                let states = Mutex::new(Vec::<(u32, i32, String)>::new());
                let mut ui = BridgeUi::default();
                let shared = Arc::get_mut(&mut ui.shared).unwrap();
                shared.callbacks.on_state = Some(capture_state);
                shared.context = &states as *const _ as usize;
                shared.active.store(true, Ordering::Release);
                let session: Session<BridgeUi> = Session {
                    ui_handler: ui.clone(),
                    ..Default::default()
                };
                crate::client::Interface::msgbox(
                    &session,
                    "error",
                    "Connection Error",
                    &format!("{text}{suffix}"),
                    "",
                );
                assert!(
                    ui.shared.terminal_retry_allowed.load(Ordering::Acquire),
                    "{text}{suffix}"
                );
                assert_eq!(
                    states.lock().unwrap().as_slice(),
                    &[(
                        RDNState::Error as u32,
                        17,
                        "connection-establishment-failed".to_owned()
                    )]
                );
            }
        }
    }

    #[test]
    fn viewer_offline_exception_does_not_override_authentication_or_peer_close() {
        for (authenticated, title) in [(true, "Connection Error"), (false, "Login Error")] {
            for text in [
                "Remote desktop is offline",
                "Failed to connect to 192.0.2.1:21116",
            ] {
                let ui = BridgeUi::default();
                ui.shared
                    .authenticated
                    .store(authenticated, Ordering::Release);
                ui.msgbox("error", title, text, "", false);
                assert!(!ui.shared.terminal_retry_allowed.load(Ordering::Acquire));
            }
        }
        for text in [
            "Closed manually by the peer",
            "Key mismatch",
            "ID does not exist",
            "Connection not allowed",
            "Failed to connect via relay server",
            "Failed to connect via relay server: Key mismatch: Please try later",
            "Failed to connect via relay server: Connection not allowed: Please try later",
            "Failed to connect via relay server: Closed manually by the peer: Please try later",
            "Failed to connect via relay server: unknown reason: Please try later",
            "Handshake failed",
            "Remote desktop is offline: unknown reason",
            "Failed to connect to 192.0.2.1:21116: Key mismatch",
            "Failed to connect to rendezvous.example.com:21116: Connection not allowed",
            "Failed to connect to relay server: Closed manually by the peer",
            "Failed to connect to user:password@example.com:21116",
            "Failed to connect to https://example.com:21116",
            "Failed to connect to example.com:0",
            "Failed to connect to example.com:65536",
            "Failed to connect to example.com:not-a-port",
            "Failed to connect to example.com:21116/path",
            "Failed to connect to -invalid.example:21116",
            "Failed to connect to invalid..example:21116",
        ] {
            let ui = BridgeUi::default();
            ui.msgbox("error", "Connection Error", text, "", false);
            assert!(
                !ui.shared.terminal_retry_allowed.load(Ordering::Acquire),
                "{text}"
            );
            assert_eq!(
                viewer_terminal_error_state(text, false).0,
                TERMINAL_NO_RETRY_CODE
            );
        }
    }

    #[test]
    fn viewer_terminal_diagnostics_never_include_raw_error_details() {
        for (text, reason) in [
            (
                "Key mismatch secret-peer-address",
                "connection-key-mismatch",
            ),
            (
                "Failed to secure tcp: secret-key",
                "connection-handshake-failed",
            ),
            (
                "Failed to resolve secret-host",
                "connection-name-resolution-failed",
            ),
            (
                "Failed to connect to rendezvous server: secret-host",
                "connection-establishment-failed",
            ),
            ("secret-unrecognized-message", "connection-no-retry"),
        ] {
            assert_eq!(
                viewer_terminal_error_state(text, false),
                (TERMINAL_NO_RETRY_CODE, reason)
            );
        }
    }

    #[test]
    fn viewer_no_retry_error_latches_terminal_disconnect() {
        let ui = BridgeUi::default();
        assert!(ui.shared.terminal_retry_allowed.load(Ordering::Acquire));
        ui.msgbox(
            "error",
            "Connection Error",
            "Closed manually by the peer",
            "",
            false,
        );
        assert!(!ui.shared.terminal_retry_allowed.load(Ordering::Acquire));
        ui.msgbox("error", "Connection Error", "Timeout", "", true);
        assert!(!ui.shared.terminal_retry_allowed.load(Ordering::Acquire));
    }

    #[derive(Debug, Eq, PartialEq)]
    struct CapturedFileListEvent {
        session_epoch: u64,
        request_id: i32,
        status: u32,
        entries: Vec<(u32, String, u64, u64)>,
    }

    #[derive(Debug, Eq, PartialEq)]
    struct CapturedFileManifestEvent {
        session_epoch: u64,
        request_id: i32,
        status: u32,
        part: u32,
        entries: Vec<(u32, String, u64, u64)>,
    }

    #[derive(Clone, Copy, Debug, PartialEq)]
    struct CapturedFileTransferEvent {
        session_epoch: u64,
        transfer_id: i32,
        sequence: u64,
        kind: u32,
        failure: u32,
        current_file_number: i32,
        files_completed: u32,
        total_files: u32,
        bytes_completed: u64,
        total_bytes: u64,
        bytes_per_second: f64,
    }

    #[derive(Debug, Eq, PartialEq)]
    struct CapturedFileReceiveBlock {
        abi_version: u32,
        session_epoch: u64,
        transfer_id: i32,
        file_number: u32,
        payload: Vec<u8>,
    }

    #[derive(Debug, PartialEq)]
    struct CapturedDisplayCatalogEntry {
        display_index: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        online: bool,
        scale: f64,
        name: String,
    }

    #[derive(Debug, PartialEq)]
    struct CapturedDisplayCatalogEvent {
        connection_epoch: u64,
        catalog_revision: u64,
        status: u32,
        selected_display_index: Option<u32>,
        entries: Vec<CapturedDisplayCatalogEntry>,
    }

    #[derive(Debug, Eq, PartialEq)]
    struct CapturedDisplaySelectionEvent {
        connection_epoch: u64,
        command_id: u64,
        catalog_revision: u64,
        display_index: u32,
        result: u32,
        failure: u32,
    }

    #[derive(Default, Debug, Eq, PartialEq)]
    struct UploadReadCapture {
        source: Vec<u8>,
        requests: Vec<(u64, i32, u64, u32, u64, usize)>,
        short_write: bool,
        reject: bool,
    }

    unsafe extern "C" fn capture_file_upload_read(
        context: *mut c_void,
        request: *const RDNFileTransferUploadReadRequest,
        bytes_written: *mut usize,
    ) -> i32 {
        if context.is_null() || request.is_null() || bytes_written.is_null() {
            return -4;
        }
        *bytes_written = 0;
        let capture = &*(context as *const Mutex<UploadReadCapture>);
        let request = &*request;
        if request.abi_version != ABI_VERSION || request.buffer.is_null() || request.length == 0 {
            return -4;
        }
        let mut capture = capture.lock().unwrap();
        capture.requests.push((
            request.session_epoch,
            request.transfer_id,
            request.source_token,
            request.file_number,
            request.offset,
            request.length,
        ));
        if capture.reject {
            return -5;
        }
        let Ok(offset) = usize::try_from(request.offset) else {
            return -5;
        };
        let Some(end) = offset.checked_add(request.length) else {
            return -5;
        };
        let Some(source) = capture.source.get(offset..end) else {
            return -5;
        };
        ptr::copy_nonoverlapping(source.as_ptr(), request.buffer, source.len());
        *bytes_written = if capture.short_write {
            request.length.saturating_sub(1)
        } else {
            request.length
        };
        0
    }

    unsafe extern "C" fn capture_file_transfer_event(
        context: *mut c_void,
        event: *const RDNFileTransferEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedFileTransferEvent>>);
        let event = &*event;
        capture.lock().unwrap().push(CapturedFileTransferEvent {
            session_epoch: event.session_epoch,
            transfer_id: event.transfer_id,
            sequence: event.sequence,
            kind: event.kind,
            failure: event.failure,
            current_file_number: event.current_file_number,
            files_completed: event.files_completed,
            total_files: event.total_files,
            bytes_completed: event.bytes_completed,
            total_bytes: event.total_bytes,
            bytes_per_second: event.bytes_per_second,
        });
    }

    unsafe extern "C" fn capture_file_receive_block(
        context: *mut c_void,
        block: *const RDNFileTransferReceiveBlock,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedFileReceiveBlock>>);
        let block = &*block;
        let payload = std::slice::from_raw_parts(block.data, block.length).to_vec();
        capture.lock().unwrap().push(CapturedFileReceiveBlock {
            abi_version: block.abi_version,
            session_epoch: block.session_epoch,
            transfer_id: block.transfer_id,
            file_number: block.file_number,
            payload,
        });
    }

    unsafe extern "C" fn capture_display_catalog(
        context: *mut c_void,
        event: *const RDNDisplayCatalogEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedDisplayCatalogEvent>>);
        let event = &*event;
        let entries = if event.entry_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(event.entries, event.entry_count)
                .iter()
                .map(|entry| {
                    let name = if entry.name_length == 0 {
                        String::new()
                    } else {
                        String::from_utf8(
                            std::slice::from_raw_parts(entry.name_utf8, entry.name_length).to_vec(),
                        )
                        .unwrap()
                    };
                    CapturedDisplayCatalogEntry {
                        display_index: entry.display_index,
                        x: entry.x,
                        y: entry.y,
                        width: entry.width,
                        height: entry.height,
                        online: entry.online,
                        scale: entry.scale,
                        name,
                    }
                })
                .collect()
        };
        capture.lock().unwrap().push(CapturedDisplayCatalogEvent {
            connection_epoch: event.connection_epoch,
            catalog_revision: event.catalog_revision,
            status: event.status,
            selected_display_index: event
                .selected_display_known
                .then_some(event.selected_display_index),
            entries,
        });
    }

    unsafe extern "C" fn capture_display_selection(
        context: *mut c_void,
        event: *const RDNDisplaySelectionEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedDisplaySelectionEvent>>);
        let event = &*event;
        capture.lock().unwrap().push(CapturedDisplaySelectionEvent {
            connection_epoch: event.connection_epoch,
            command_id: event.command_id,
            catalog_revision: event.catalog_revision,
            display_index: event.display_index,
            result: event.result,
            failure: event.failure,
        });
    }

    fn display_info(
        name: &str,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        online: bool,
        scale: f64,
    ) -> DisplayInfo {
        DisplayInfo {
            x,
            y,
            width,
            height,
            name: name.to_owned(),
            online,
            scale,
            ..Default::default()
        }
    }

    unsafe extern "C" fn capture_file_list_event(
        context: *mut c_void,
        event: *const RDNFileTransferListEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedFileListEvent>>);
        let event = &*event;
        let entries = if event.entry_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(event.entries, event.entry_count)
                .iter()
                .map(|entry| {
                    let bytes = std::slice::from_raw_parts(
                        entry.relative_path_utf8,
                        entry.relative_path_length,
                    );
                    (
                        entry.kind,
                        String::from_utf8(bytes.to_vec()).unwrap(),
                        entry.size,
                        entry.modified_time,
                    )
                })
                .collect()
        };
        capture.lock().unwrap().push(CapturedFileListEvent {
            session_epoch: event.session_epoch,
            request_id: event.request_id,
            status: event.status,
            entries,
        });
    }

    unsafe extern "C" fn capture_file_manifest_event(
        context: *mut c_void,
        event: *const RDNFileTransferManifestEvent,
    ) {
        let capture = &*(context as *const Mutex<Vec<CapturedFileManifestEvent>>);
        let event = &*event;
        let entries = if event.entry_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(event.entries, event.entry_count)
                .iter()
                .map(|entry| {
                    let bytes = std::slice::from_raw_parts(
                        entry.relative_path_utf8,
                        entry.relative_path_length,
                    );
                    (
                        entry.kind,
                        String::from_utf8(bytes.to_vec()).unwrap(),
                        entry.size,
                        entry.modified_time,
                    )
                })
                .collect()
        };
        capture.lock().unwrap().push(CapturedFileManifestEvent {
            session_epoch: event.session_epoch,
            request_id: event.request_id,
            status: event.status,
            part: event.part,
            entries,
        });
    }

    fn remote_list_entry(entry_type: FileType, name: &str, size: u64) -> FileEntry {
        FileEntry {
            entry_type: entry_type.into(),
            name: name.to_owned(),
            size,
            modified_time: 123,
            ..Default::default()
        }
    }

    fn viewer_manifest_file_authorities(
        entries: &[(u64, u64)],
    ) -> Arc<[NativeViewerManifestFileAuthority]> {
        entries
            .iter()
            .map(|(size, modified_time)| NativeViewerManifestFileAuthority {
                size: *size,
                modified_time: *modified_time,
            })
            .collect::<Vec<_>>()
            .into()
    }

    fn nal(nal_type: u8) -> [u8; 3] {
        [nal_type << 1, 1, 0x80]
    }

    #[test]
    fn identifies_annex_b_parameter_sets() {
        let mut data = Vec::new();
        for nal_type in [32, 33, 34, 19] {
            data.extend_from_slice(&[0, 0, 0, 1]);
            data.extend_from_slice(&nal(nal_type));
        }
        let result = inspect_packet(&data, RDNCodec::H265);
        assert_eq!(result.format, RDNPacketFormat::AnnexB);
        assert_eq!(result.flags, FLAG_VPS | FLAG_SPS | FLAG_PPS);
    }

    #[test]
    fn identifies_avcc_parameter_sets() {
        let mut data = Vec::new();
        for nal_type in [32, 33, 34, 1] {
            let unit = nal(nal_type);
            data.extend_from_slice(&(unit.len() as u32).to_be_bytes());
            data.extend_from_slice(&unit);
        }
        let result = inspect_packet(&data, RDNCodec::H265);
        assert_eq!(result.format, RDNPacketFormat::Avcc);
        assert_eq!(result.flags, FLAG_VPS | FLAG_SPS | FLAG_PPS);
    }

    #[test]
    fn rejects_unframed_packet() {
        assert_eq!(
            inspect_packet(&[0x26, 0x01, 0x80], RDNCodec::H265).format,
            RDNPacketFormat::Unknown
        );
    }

    #[test]
    fn identifies_h264_parameter_sets_in_annex_b_and_avcc() {
        let units = [vec![0x67, 0x64, 0x00, 0x1f], vec![0x68, 0xce, 0x0f], vec![0x65, 0x80]];
        let mut annex_b = Vec::new();
        let mut avcc = Vec::new();
        for unit in units {
            annex_b.extend_from_slice(&[0, 0, 0, 1]);
            annex_b.extend_from_slice(&unit);
            avcc.extend_from_slice(&(unit.len() as u32).to_be_bytes());
            avcc.extend_from_slice(&unit);
        }
        for (data, format) in [(annex_b, RDNPacketFormat::AnnexB), (avcc, RDNPacketFormat::Avcc)] {
            let result = inspect_packet(&data, RDNCodec::H264);
            assert_eq!(result.format, format);
            assert_eq!(result.flags, FLAG_SPS | FLAG_PPS);
        }
        // H.264 P 帧的 0x41 不能按 HEVC 位布局误报 VPS。
        assert_eq!(inspect_packet(&[0, 0, 0, 1, 0x41, 1, 0x80], RDNCodec::H264).flags, 0);
    }

    #[test]
    fn builds_client_housekeeping_test_delay() {
        let message = housekeeping_message();
        let Some(message::Union::TestDelay(delay)) = message.union else {
            panic!("housekeeping message must be TestDelay");
        };
        assert!(delay.from_client);
    }

    #[test]
    fn native_viewer_display_catalog_is_revisioned_and_binds_selected_frames() {
        let captured = Mutex::new(Vec::<CapturedDisplayCatalogEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_display_catalog = Some(capture_display_catalog);
        shared.context = &captured as *const _ as usize;
        ui.shared.connection_epoch.store(7, Ordering::Release);
        ui.shared.active.store(true, Ordering::Release);

        let mut peer = PeerInfo {
            displays: vec![
                display_info("Built-in", 0, 0, 1920, 1080, true, 2.0),
                display_info("Studio", 1920, 0, 2560, 1440, true, 1.0),
            ],
            current_display: 1,
            ..Default::default()
        };
        ui.set_peer_info(&peer);
        ui.set_displays(&peer.displays);
        assert_eq!(captured.lock().unwrap().len(), 1);
        assert_eq!(ui.shared.video_catalog_binding(1), Some((7, 1)));
        assert_eq!(ui.shared.video_catalog_binding(0), None);

        peer.displays[1].width = 3008;
        ui.set_displays(&peer.displays);
        ui.set_current_display(0);
        ui.switch_display(&SwitchDisplay {
            display: 1,
            width: 3008,
            height: 1440,
            ..Default::default()
        });

        assert_eq!(ui.shared.video_catalog_binding(1), Some((7, 2)));
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[
                CapturedDisplayCatalogEvent {
                    connection_epoch: 7,
                    catalog_revision: 1,
                    status: DISPLAY_CATALOG_STATUS_AVAILABLE,
                    selected_display_index: Some(1),
                    entries: vec![
                        CapturedDisplayCatalogEntry {
                            display_index: 0,
                            x: 0,
                            y: 0,
                            width: 1920,
                            height: 1080,
                            online: true,
                            scale: 2.0,
                            name: "Built-in".to_owned(),
                        },
                        CapturedDisplayCatalogEntry {
                            display_index: 1,
                            x: 1920,
                            y: 0,
                            width: 2560,
                            height: 1440,
                            online: true,
                            scale: 1.0,
                            name: "Studio".to_owned(),
                        },
                    ],
                },
                CapturedDisplayCatalogEvent {
                    connection_epoch: 7,
                    catalog_revision: 2,
                    status: DISPLAY_CATALOG_STATUS_AVAILABLE,
                    selected_display_index: Some(1),
                    entries: vec![
                        CapturedDisplayCatalogEntry {
                            display_index: 0,
                            x: 0,
                            y: 0,
                            width: 1920,
                            height: 1080,
                            online: true,
                            scale: 2.0,
                            name: "Built-in".to_owned(),
                        },
                        CapturedDisplayCatalogEntry {
                            display_index: 1,
                            x: 1920,
                            y: 0,
                            width: 3008,
                            height: 1440,
                            online: true,
                            scale: 1.0,
                            name: "Studio".to_owned(),
                        },
                    ],
                },
                CapturedDisplayCatalogEvent {
                    connection_epoch: 7,
                    catalog_revision: 2,
                    status: DISPLAY_CATALOG_STATUS_AVAILABLE,
                    selected_display_index: Some(0),
                    entries: vec![
                        CapturedDisplayCatalogEntry {
                            display_index: 0,
                            x: 0,
                            y: 0,
                            width: 1920,
                            height: 1080,
                            online: true,
                            scale: 2.0,
                            name: "Built-in".to_owned(),
                        },
                        CapturedDisplayCatalogEntry {
                            display_index: 1,
                            x: 1920,
                            y: 0,
                            width: 3008,
                            height: 1440,
                            online: true,
                            scale: 1.0,
                            name: "Studio".to_owned(),
                        },
                    ],
                },
                CapturedDisplayCatalogEvent {
                    connection_epoch: 7,
                    catalog_revision: 2,
                    status: DISPLAY_CATALOG_STATUS_AVAILABLE,
                    selected_display_index: Some(1),
                    entries: vec![
                        CapturedDisplayCatalogEntry {
                            display_index: 0,
                            x: 0,
                            y: 0,
                            width: 1920,
                            height: 1080,
                            online: true,
                            scale: 2.0,
                            name: "Built-in".to_owned(),
                        },
                        CapturedDisplayCatalogEntry {
                            display_index: 1,
                            x: 1920,
                            y: 0,
                            width: 3008,
                            height: 1440,
                            online: true,
                            scale: 1.0,
                            name: "Studio".to_owned(),
                        },
                    ],
                },
            ]
        );
    }
