    #[test]
    fn viewer_download_start_rolls_back_registration_when_wire_queue_is_closed() {
        let ui = BridgeUi::default();
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        *ui.shared.completed_file_manifest_request.lock().unwrap() =
            Some(NativeViewerCompletedManifest {
                session_epoch: 7,
                request_id: 51,
                total_files: 2,
                total_bytes: 42,
                files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
            });

        let (sender, receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        drop(receiver);
        let session = Session {
            sender: Arc::new(RwLock::new(Some(sender))),
            ui_handler: ui.clone(),
            server_file_transfer_enabled: Arc::new(RwLock::new(true)),
            ..Default::default()
        };
        let mut client = RDNClient {
            shared: ui.shared.clone(),
            session: Mutex::new(Some(session)),
            worker: Mutex::new(None),
            housekeeping: Mutex::new(None),
        };
        let request = RDNFileTransferDownloadStart {
            abi_version: ABI_VERSION,
            session_epoch: 7,
            manifest_request_id: 51,
            transfer_id: 61,
            total_files: 2,
            total_bytes: 42,
        };

        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(&mut client, &request) },
            -3
        );
        assert!(ui
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn viewer_download_progress_and_terminal_callbacks_are_monotonic_and_stable() {
        let captured = Mutex::new(Vec::<CapturedFileTransferEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_event = Some(capture_file_transfer_event);
        shared.context = &captured as *const _ as usize;
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        let job = NativeViewerDownloadJob {
            session_epoch: 7,
            manifest_request_id: 51,
            transfer_id: 61,
            total_files: 2,
            total_bytes: 42,
            manifest_files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
            next_digest_file_number: 2,
            sequence: 0,
            files_completed: 0,
            bytes_completed: 0,
        };
        ui.shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .insert(61, job.clone());

        ui.job_progress(61, -1, 7.5, 10.0);
        ui.job_progress(61, -1, 7.5, 9.0);
        ui.job_progress(61, 0, 8.0, 40.0);
        ui.job_done(61, 1);
        ui.job_progress(61, 1, 1.0, 42.0);
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[
                CapturedFileTransferEvent {
                    session_epoch: 7,
                    transfer_id: 61,
                    sequence: 1,
                    kind: FILE_TRANSFER_EVENT_PROGRESS,
                    failure: FILE_TRANSFER_FAILURE_NONE,
                    current_file_number: 0,
                    files_completed: 0,
                    total_files: 2,
                    bytes_completed: 10,
                    total_bytes: 42,
                    bytes_per_second: 7.5,
                },
                CapturedFileTransferEvent {
                    session_epoch: 7,
                    transfer_id: 61,
                    sequence: 2,
                    kind: FILE_TRANSFER_EVENT_PROGRESS,
                    failure: FILE_TRANSFER_FAILURE_NONE,
                    current_file_number: 1,
                    files_completed: 1,
                    total_files: 2,
                    bytes_completed: 40,
                    total_bytes: 42,
                    bytes_per_second: 8.0,
                },
                CapturedFileTransferEvent {
                    session_epoch: 7,
                    transfer_id: 61,
                    sequence: 3,
                    kind: FILE_TRANSFER_EVENT_COMPLETED,
                    failure: FILE_TRANSFER_FAILURE_NONE,
                    current_file_number: -1,
                    files_completed: 2,
                    total_files: 2,
                    bytes_completed: 42,
                    total_bytes: 42,
                    bytes_per_second: 0.0,
                },
            ]
        );

        ui.shared.active_file_download_jobs.lock().unwrap().insert(
            62,
            NativeViewerDownloadJob {
                transfer_id: 62,
                ..job.clone()
            },
        );
        ui.job_error(62, "raw remote detail".to_owned(), 0);
        assert_eq!(
            captured.lock().unwrap().last().copied(),
            Some(CapturedFileTransferEvent {
                session_epoch: 7,
                transfer_id: 62,
                sequence: 1,
                kind: FILE_TRANSFER_EVENT_FAILED,
                failure: FILE_TRANSFER_FAILURE_UNAVAILABLE,
                current_file_number: -1,
                files_completed: 0,
                total_files: 2,
                bytes_completed: 0,
                total_bytes: 42,
                bytes_per_second: 0.0,
            })
        );

        let mut precision_boundary_job = NativeViewerDownloadJob {
            transfer_id: 63,
            total_bytes: 9_007_199_254_740_995,
            ..job
        };
        assert_eq!(
            precision_boundary_job.progress(-1, 1.0, precision_boundary_job.total_bytes as f64,),
            None
        );
        assert_eq!(precision_boundary_job.sequence, 0);
        assert_eq!(precision_boundary_job.bytes_completed, 0);
    }

    fn optional_payload_bytes(bytes: Option<&[u8]>) -> (*const u8, usize) {
        bytes.map_or((ptr::null(), 0), |bytes| (bytes.as_ptr(), bytes.len()))
    }

    fn rich_payload(
        plain: Option<&[u8]>,
        rtf: Option<&[u8]>,
        html: Option<&[u8]>,
    ) -> RDNClipboardRichTextPayload {
        let (plain_utf8, plain_length) = optional_payload_bytes(plain);
        let (rtf_utf8, rtf_length) = optional_payload_bytes(rtf);
        let (html_utf8, html_length) = optional_payload_bytes(html);
        RDNClipboardRichTextPayload {
            abi_version: ABI_VERSION,
            plain_utf8,
            plain_length,
            rtf_utf8,
            rtf_length,
            html_utf8,
            html_length,
        }
    }

    #[test]
    fn native_viewer_rich_clipboard_builds_canonical_outbound_messages() {
        let rtf = b"{\\rtf1 outbound}";
        let payload = rich_payload(None, Some(rtf), None);
        let message = unsafe { native_viewer_clipboard_rich_text_message(&payload) }
            .expect("single rich payload");
        let Some(message::Union::Clipboard(clipboard)) = message.union else {
            panic!("one rich entry must use Clipboard");
        };
        assert_eq!(clipboard.format.enum_value(), Ok(ClipboardFormat::Rtf));
        assert_eq!(clipboard.content.as_ref(), rtf);
        assert!(!clipboard.compress);
        assert!(clipboard.special_name.is_empty());
        assert_eq!((clipboard.width, clipboard.height), (0, 0));

        let plain = "回退文本".as_bytes();
        let html = b"<b>outbound</b>";
        let payload = rich_payload(Some(plain), Some(rtf), Some(html));
        let message = unsafe { native_viewer_clipboard_rich_text_message(&payload) }
            .expect("multi rich payload");
        let Some(message::Union::MultiClipboards(multi)) = message.union else {
            panic!("multiple rich entries must use MultiClipboards");
        };
        assert_eq!(multi.clipboards.len(), 3);
        for (clipboard, expected_format, expected_content) in [
            (&multi.clipboards[0], ClipboardFormat::Text, plain),
            (&multi.clipboards[1], ClipboardFormat::Rtf, rtf.as_slice()),
            (&multi.clipboards[2], ClipboardFormat::Html, html.as_slice()),
        ] {
            assert_eq!(clipboard.format.enum_value(), Ok(expected_format));
            assert_eq!(clipboard.content.as_ref(), expected_content);
            assert!(!clipboard.compress);
            assert!(clipboard.special_name.is_empty());
            assert_eq!((clipboard.width, clipboard.height), (0, 0));
        }
    }

    #[test]
    fn native_viewer_rich_clipboard_rejects_invalid_outbound_payloads() {
        let plain = b"plain";
        let rtf = b"{\\rtf1}";
        let mut payload = rich_payload(Some(plain), None, None);
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        payload = rich_payload(None, Some(rtf), None);
        payload.abi_version += 1;
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        payload = rich_payload(None, Some(rtf), None);
        payload.rtf_utf8 = ptr::null();
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        payload = rich_payload(None, Some(rtf), None);
        payload.rtf_length = 0;
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        payload = rich_payload(None, Some(rtf), None);
        payload.rtf_length = MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES + 1;
        assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());

        for invalid in [&[0xff][..], &b"before\0after"[..]] {
            payload = rich_payload(None, None, Some(invalid));
            assert!(unsafe { native_viewer_clipboard_rich_text_message(&payload) }.is_none());
        }
    }
