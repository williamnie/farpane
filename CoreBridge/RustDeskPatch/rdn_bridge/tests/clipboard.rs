    #[test]
    fn validates_bounded_utf8_text_without_logging_content() {
        assert_eq!(validated_text("中文输入".as_bytes()), Some("中文输入"));
        assert!(validated_text(b"").is_none());
        assert!(validated_text(b"a\0b").is_none());
        assert!(validated_text(&[0xff]).is_none());
        assert!(validated_text(&vec![b'a'; MAX_TEXT_BYTES + 1]).is_none());
    }

    fn clipboard_fixture(content: Vec<u8>, compress: bool, format: ClipboardFormat) -> Clipboard {
        Clipboard {
            content: content.into(),
            compress,
            format: format.into(),
            ..Default::default()
        }
    }

    #[test]
    fn native_viewer_clipboard_accepts_only_one_bounded_utf8_text_entry() {
        let text = clipboard_fixture(
            "Viewer 小文本".as_bytes().to_vec(),
            false,
            ClipboardFormat::Text,
        );
        assert_eq!(
            native_viewer_clipboard_text(std::slice::from_ref(&text)).as_deref(),
            Some("Viewer 小文本")
        );
        assert!(native_viewer_clipboard_text(&[]).is_none());
        assert!(native_viewer_clipboard_text(&[text.clone(), text]).is_none());
        assert!(native_viewer_clipboard_text(&[clipboard_fixture(
            b"<b>rich</b>".to_vec(),
            false,
            ClipboardFormat::Html,
        )])
        .is_none());
        assert!(native_viewer_clipboard_text(&[clipboard_fixture(
            b"a\0b".to_vec(),
            false,
            ClipboardFormat::Text,
        )])
        .is_none());
        assert!(native_viewer_clipboard_text(&[clipboard_fixture(
            vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1],
            false,
            ClipboardFormat::Text,
        )])
        .is_none());
    }

    #[test]
    fn native_viewer_clipboard_bounds_decompression_and_builds_canonical_message() {
        let plain = vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES];
        let compressed = hbb_common::compress::compress(&plain);
        assert_eq!(
            native_viewer_clipboard_text(&[clipboard_fixture(
                compressed,
                true,
                ClipboardFormat::Text,
            )])
            .map(|text| text.len()),
            Some(MAX_CLIPBOARD_TEXT_UTF8_BYTES)
        );

        let oversized =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1]);
        assert!(native_viewer_clipboard_text(&[clipboard_fixture(
            oversized,
            true,
            ClipboardFormat::Text,
        )])
        .is_none());

        let message = native_viewer_clipboard_message("发送文本".as_bytes())
            .expect("bounded clipboard text message");
        let Some(message::Union::Clipboard(clipboard)) = message.union else {
            panic!("viewer clipboard output must be one Clipboard message");
        };
        assert_eq!(clipboard.format.enum_value(), Ok(ClipboardFormat::Text));
        assert_eq!(clipboard.content.as_ref(), "发送文本".as_bytes());
        assert!(!clipboard.compress);
        assert!(clipboard.special_name.is_empty());
        assert_eq!((clipboard.width, clipboard.height), (0, 0));
        assert!(native_viewer_clipboard_message(b"").is_none());
        assert!(native_viewer_clipboard_message(b"a\0b").is_none());
        assert!(native_viewer_clipboard_message(&[0xff]).is_none());
    }

    #[test]
    fn native_viewer_rich_clipboard_accepts_only_owned_bounded_canonical_bundle() {
        let mut source = vec![
            clipboard_fixture(b"plain fallback".to_vec(), false, ClipboardFormat::Text),
            clipboard_fixture(b"{\\rtf1 rich}".to_vec(), false, ClipboardFormat::Rtf),
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html),
        ];
        let bundle = native_viewer_clipboard_rich_text(&source).expect("canonical rich bundle");
        source
            .iter_mut()
            .for_each(|clipboard| clipboard.content.clear());
        assert_eq!(bundle.plain_text.as_deref(), Some("plain fallback"));
        assert_eq!(bundle.rtf.as_deref(), Some("{\\rtf1 rich}"));
        assert_eq!(bundle.html.as_deref(), Some("<b>rich</b>"));

        let at_limit = vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES];
        let compressed = hbb_common::compress::compress(&at_limit);
        let bundle = native_viewer_clipboard_rich_text(&[clipboard_fixture(
            compressed,
            true,
            ClipboardFormat::Html,
        )])
        .expect("bounded compressed rich entry");
        assert_eq!(bundle.html.map(|html| html.len()), Some(at_limit.len()));
    }

    #[test]
    fn native_viewer_rich_clipboard_rejects_ambiguous_or_unbounded_input() {
        let plain = clipboard_fixture(b"plain".to_vec(), false, ClipboardFormat::Text);
        let rtf = clipboard_fixture(b"{\\rtf1}".to_vec(), false, ClipboardFormat::Rtf);
        let html = clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        assert!(native_viewer_clipboard_rich_text(&[]).is_none());
        assert!(native_viewer_clipboard_rich_text(std::slice::from_ref(&plain)).is_none());
        assert!(native_viewer_clipboard_rich_text(&[
            plain.clone(),
            rtf.clone(),
            html.clone(),
            rtf.clone(),
        ])
        .is_none());
        assert!(native_viewer_clipboard_rich_text(&[rtf.clone(), rtf.clone()]).is_none());

        for invalid in [
            clipboard_fixture(Vec::new(), false, ClipboardFormat::Html),
            clipboard_fixture(b"before\0after".to_vec(), false, ClipboardFormat::Html),
            clipboard_fixture(vec![0xff], false, ClipboardFormat::Rtf),
            clipboard_fixture(
                vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES + 1],
                false,
                ClipboardFormat::Html,
            ),
            clipboard_fixture(b"image".to_vec(), false, ClipboardFormat::ImagePng),
            clipboard_fixture(b"special".to_vec(), false, ClipboardFormat::Special),
        ] {
            assert!(native_viewer_clipboard_rich_text(&[invalid]).is_none());
        }

        let compressed_over_limit =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES + 1]);
        assert!(native_viewer_clipboard_rich_text(&[clipboard_fixture(
            compressed_over_limit,
            true,
            ClipboardFormat::Rtf,
        )])
        .is_none());

        let mut wrong_metadata = html.clone();
        wrong_metadata.special_name = "public.html".to_owned();
        assert!(native_viewer_clipboard_rich_text(&[wrong_metadata]).is_none());
        let mut wrong_dimensions = html;
        wrong_dimensions.width = 1;
        assert!(native_viewer_clipboard_rich_text(&[wrong_dimensions]).is_none());
        let mut unknown = rtf;
        unknown.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert!(native_viewer_clipboard_rich_text(&[unknown]).is_none());
    }

    #[test]
    fn native_viewer_image_receive_preparse_gate_requires_every_authority() {
        let ui = BridgeUi::default();
        assert!(!ui.native_clipboard_image_enabled());
        ui.shared.active.store(true, Ordering::Release);
        ui.shared.authenticated.store(true, Ordering::Release);
        ui.shared
            .receive_clipboard_image
            .store(true, Ordering::Release);
        ui.shared
            .remote_clipboard_enabled
            .store(true, Ordering::Release);
        assert!(ui.native_clipboard_image_enabled());

        for gate in [
            &ui.shared.active,
            &ui.shared.authenticated,
            &ui.shared.receive_clipboard_image,
            &ui.shared.remote_clipboard_enabled,
        ] {
            gate.store(false, Ordering::Release);
            assert!(!ui.native_clipboard_image_enabled());
            gate.store(true, Ordering::Release);
        }
    }

    #[test]
    fn native_viewer_image_clipboard_accepts_owned_bounded_canonical_payloads() {
        let mut rgba = clipboard_fixture(vec![1, 2, 3, 255], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        let image = native_viewer_clipboard_image(std::slice::from_ref(&rgba)).unwrap();
        assert_eq!(
            image.kind,
            NativeViewerClipboardImageKind::Rgba {
                width: 1,
                height: 1,
            }
        );
        rgba.content.clear();
        assert_eq!(image.payload, vec![1, 2, 3, 255]);

        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[7, 8, 9, 255]).unwrap();
        let image = native_viewer_clipboard_image(&[clipboard_fixture(
            png.clone(),
            false,
            ClipboardFormat::ImagePng,
        )])
        .unwrap();
        assert_eq!(image.kind, NativeViewerClipboardImageKind::Png);
        assert_eq!(image.payload, png);

        let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".to_vec();
        let image = native_viewer_clipboard_image(&[clipboard_fixture(
            hbb_common::compress::compress(&svg),
            true,
            ClipboardFormat::ImageSvg,
        )])
        .unwrap();
        assert_eq!(image.kind, NativeViewerClipboardImageKind::Svg);
        assert_eq!(image.payload, svg);
    }

    #[test]
    fn native_viewer_image_clipboard_rejects_ambiguous_or_unbounded_input() {
        let mut rgba = clipboard_fixture(vec![1, 2, 3], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        assert!(native_viewer_clipboard_image(&[rgba]).is_none());

        let mut excessive = clipboard_fixture(vec![0; 4], false, ClipboardFormat::ImageRgba);
        excessive.width = MAX_CLIPBOARD_IMAGE_DIMENSION + 1;
        excessive.height = 1;
        assert!(native_viewer_clipboard_image(&[excessive.clone()]).is_none());
        excessive.width = MAX_CLIPBOARD_IMAGE_DIMENSION;
        excessive.height = MAX_CLIPBOARD_IMAGE_DIMENSION;
        assert!(native_viewer_clipboard_image(&[excessive]).is_none());

        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[0, 0, 0, 255]).unwrap();
        assert!(native_viewer_clipboard_image(&[clipboard_fixture(
            hbb_common::compress::compress(&png),
            true,
            ClipboardFormat::ImagePng,
        )])
        .is_none());
        assert!(native_viewer_clipboard_image(&[clipboard_fixture(
            png[..24].to_vec(),
            false,
            ClipboardFormat::ImagePng,
        )])
        .is_none());

        for invalid_svg in [
            vec![0xff],
            b"before\0after".to_vec(),
            b"<html></html>".to_vec(),
            b"<!DOCTYPE svg><svg></svg>".to_vec(),
        ] {
            assert!(native_viewer_clipboard_image(&[clipboard_fixture(
                invalid_svg,
                false,
                ClipboardFormat::ImageSvg,
            )])
            .is_none());
        }
        assert!(native_viewer_clipboard_image(&[clipboard_fixture(
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_SVG_UTF8_BYTES + 1]),
            true,
            ClipboardFormat::ImageSvg,
        )])
        .is_none());

        let mut special = clipboard_fixture(png, false, ClipboardFormat::ImagePng);
        special.special_name = "public.png".to_owned();
        assert!(native_viewer_clipboard_image(&[special]).is_none());
        assert!(native_viewer_clipboard_image(&[]).is_none());
    }

    fn image_payload(
        format: u32,
        bytes: &[u8],
        width: u32,
        height: u32,
    ) -> RDNClipboardImagePayload {
        RDNClipboardImagePayload {
            abi_version: ABI_VERSION,
            format,
            data: bytes.as_ptr(),
            length: bytes.len(),
            width,
            height,
        }
    }

    #[test]
    fn native_viewer_image_clipboard_builds_canonical_outbound_messages() {
        let rgba = [1, 2, 3, 255];
        let payload = image_payload(CLIPBOARD_IMAGE_FORMAT_RGBA, &rgba, 1, 1);
        let message = unsafe { native_viewer_clipboard_image_message(&payload) }.unwrap();
        let Some(message::Union::Clipboard(clipboard)) = message.union else {
            panic!("one image must use Clipboard");
        };
        assert_eq!(
            clipboard.format.enum_value(),
            Ok(ClipboardFormat::ImageRgba)
        );
        assert_eq!(clipboard.content.as_ref(), rgba);
        assert_eq!((clipboard.width, clipboard.height), (1, 1));
        assert!(!clipboard.compress);

        let svg = b"<svg></svg>";
        let payload = image_payload(CLIPBOARD_IMAGE_FORMAT_SVG, svg, 0, 0);
        let message = unsafe { native_viewer_clipboard_image_message(&payload) }.unwrap();
        let Some(message::Union::Clipboard(clipboard)) = message.union else {
            panic!("one image must use Clipboard");
        };
        assert_eq!(clipboard.format.enum_value(), Ok(ClipboardFormat::ImageSvg));
        assert_eq!(clipboard.content.as_ref(), svg);
        assert_eq!((clipboard.width, clipboard.height), (0, 0));
        assert!(!clipboard.compress);
    }

    #[test]
    fn native_viewer_image_clipboard_rejects_invalid_outbound_payloads() {
        let rgba = [1, 2, 3, 255];
        let mut payload = image_payload(CLIPBOARD_IMAGE_FORMAT_RGBA, &rgba, 1, 1);
        payload.abi_version += 1;
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(CLIPBOARD_IMAGE_FORMAT_RGBA, &rgba, 1, 1);
        payload.data = ptr::null();
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(CLIPBOARD_IMAGE_FORMAT_RGBA, &rgba[..3], 1, 1);
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(CLIPBOARD_IMAGE_FORMAT_PNG, b"not png", 0, 0);
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(CLIPBOARD_IMAGE_FORMAT_SVG, b"<html></html>", 0, 0);
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());

        payload = image_payload(999, &rgba, 0, 0);
        assert!(unsafe { native_viewer_clipboard_image_message(&payload) }.is_none());
    }

    #[test]
    fn native_viewer_image_send_requires_every_lifecycle_and_permission_gate() {
        let ui = BridgeUi::default();
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(None),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let svg = b"<svg></svg>";
        let payload = image_payload(CLIPBOARD_IMAGE_FORMAT_SVG, svg, 0, 0);
        let client_pointer = &mut client as *mut RDNClient;

        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -3
        );
        ui.shared.active.store(true, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -6
        );
        ui.shared.authenticated.store(true, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -7
        );
        ui.shared
            .send_clipboard_image
            .store(true, Ordering::Release);
        ui.shared
            .remote_clipboard_enabled
            .store(false, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -8
        );
        ui.shared
            .remote_clipboard_enabled
            .store(true, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_send_clipboard_image(client_pointer, &payload) },
            -3
        );
    }

    #[test]
    fn viewer_file_transfer_v9_seam_is_exact_pair_and_fail_closed() {
        assert_eq!(viewer_file_transfer_mode_admission(false, 0, false), 0);
        assert_eq!(viewer_file_transfer_mode_admission(false, 1, false), -5);
        assert_eq!(viewer_file_transfer_mode_admission(true, 0, false), -5);
        assert_eq!(viewer_file_transfer_mode_admission(true, 1, false), 0);
        assert_eq!(viewer_file_transfer_mode_admission(true, 1, true), -5);
        assert!(native_viewer_audio_disabled(false));
        assert!(!native_viewer_audio_disabled(true));
        assert!(!native_viewer_audio_is_active(false, false, false));
        assert!(!native_viewer_audio_is_active(false, true, true));
        assert!(!native_viewer_audio_is_active(true, false, true));
        assert!(!native_viewer_audio_is_active(true, true, false));
        assert!(native_viewer_audio_is_active(true, true, true));
        assert!(native_remote_audio_permission_event(0, true).is_none());
        let permission = native_remote_audio_permission_event(9, false).unwrap();
        assert_eq!(permission.abi_version, ABI_VERSION);
        assert_eq!(permission.connection_epoch, 9);
        assert_eq!(permission.permission, REMOTE_PERMISSION_AUDIO);
        assert!(!permission.enabled);

        let ui = BridgeUi::default();
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(None),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let client_pointer = &mut client as *mut RDNClient;
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 1, 1) },
            -3
        );
        ui.shared.active.store(true, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 0, 1) },
            -4
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 1, 0) },
            -4
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 1, 1) },
            -7
        );
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(2, Ordering::Release);
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 1, 1) },
            -10
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 2, 1) },
            -6
        );
    }

    #[test]
    fn viewer_file_transfer_mode_dispatches_exact_epoch_cancel_only_when_ready() {
        let desktop_ui = BridgeUi::default();
        desktop_ui.shared.active.store(true, Ordering::Release);
        desktop_ui.on_connected(ConnType::DEFAULT_CONN);
        assert!(desktop_ui.shared.input_allowed.load(Ordering::Acquire));

        let ui = BridgeUi::default();
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        assert!(ui.shared.authenticated.load(Ordering::Acquire));
        assert!(!ui.shared.input_allowed.load(Ordering::Acquire));

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            server_file_transfer_enabled: Arc::new(RwLock::new(false)),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session.clone())),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let client_pointer = &mut client as *mut RDNClient;

        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 6, 23) },
            -10
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 7, 23) },
            -8
        );
        *session.server_file_transfer_enabled.write().unwrap() = true;
        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 7, 23) },
            0
        );
        assert!(matches!(receiver.try_recv(), Ok(Data::CancelJob(23))));
    }

    #[test]
    fn viewer_file_transfer_waits_for_remote_permission_before_ready() {
        let captured = Mutex::new(Vec::<(u32, i32, String)>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_state = Some(capture_state);
        shared.context = &captured as *const _ as usize;
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);

        ui.on_connected(ConnType::FILE_TRANSFER);
        assert_eq!(
            *captured.lock().unwrap(),
            vec![(
                RDNState::Authenticated as u32,
                0,
                "authenticated".to_owned()
            )],
            "authentication alone must not admit file commands"
        );

        ui.set_permission("file", true);
        assert_eq!(
            *captured.lock().unwrap(),
            vec![
                (
                    RDNState::Authenticated as u32,
                    0,
                    "authenticated".to_owned()
                ),
                (
                    RDNState::Streaming as u32,
                    0,
                    "file-transfer-ready".to_owned()
                )
            ]
        );
        ui.set_permission("file", true);
        assert_eq!(captured.lock().unwrap().len(), 2);
    }
