    #[test]
    fn viewer_download_start_registers_exact_manifest_and_dispatches_bounded_wire_request() {
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
        *ui.shared.completed_file_manifest_request.lock().unwrap() =
            Some(NativeViewerCompletedManifest {
                session_epoch: 7,
                request_id: 51,
                total_files: 2,
                total_bytes: 42,
                files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
            });

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
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
        let client_pointer = &mut client as *mut RDNClient;
        let mut request = RDNFileTransferDownloadStart {
            abi_version: ABI_VERSION,
            session_epoch: 7,
            manifest_request_id: 51,
            transfer_id: 61,
            total_files: 2,
            total_bytes: 42,
        };

        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            0
        );
        assert_eq!(
            ui.shared
                .active_file_download_jobs
                .lock()
                .unwrap()
                .get(&61)
                .cloned(),
            Some(NativeViewerDownloadJob {
                session_epoch: 7,
                manifest_request_id: 51,
                transfer_id: 61,
                total_files: 2,
                total_bytes: 42,
                manifest_files: viewer_manifest_file_authorities(&[(10, 100), (32, 200)]),
                next_digest_file_number: 0,
                sequence: 0,
                files_completed: 0,
                bytes_completed: 0,
            })
        );
        let Ok(Data::Message(message)) = receiver.try_recv() else {
            panic!("download start must send one wire message");
        };
        let Some(message::Union::FileAction(action)) = message.union else {
            panic!("download start must send FileAction");
        };
        let Some(file_action::Union::Send(send)) = action.union else {
            panic!("download start must send a send-files request");
        };
        assert_eq!(
            (
                send.id,
                send.path.as_str(),
                send.file_num,
                send.include_hidden,
                send.file_type.enum_value(),
            ),
            (
                61,
                "/",
                0,
                false,
                Ok(file_transfer_send_request::FileType::Generic)
            )
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -3
        );

        request.transfer_id = 62;
        request.manifest_request_id = 52;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -3
        );
        request.manifest_request_id = 51;
        request.total_files = 3;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -3
        );
        request.total_files = 2;
        request.session_epoch = 6;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -10
        );
        request.session_epoch = 7;
        request.total_files = (MAX_FILE_TRANSFER_LIST_ENTRIES + 1) as u32;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -4
        );
        request.total_files = 0;
        request.total_bytes = 1;
        assert_eq!(
            unsafe { rdn_client_file_transfer_download_start(client_pointer, &request) },
            -4
        );
        assert!(
            receiver.try_recv().is_err(),
            "rejected or duplicate starts must not dispatch another request"
        );

        assert_eq!(
            unsafe { rdn_client_file_transfer_cancel(client_pointer, 7, 61) },
            0
        );
        assert!(ui
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .is_empty());
        assert!(matches!(receiver.try_recv(), Ok(Data::CancelJob(61))));
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedFileTransferEvent {
                session_epoch: 7,
                transfer_id: 61,
                sequence: 1,
                kind: FILE_TRANSFER_EVENT_CANCELLED,
                failure: FILE_TRANSFER_FAILURE_NONE,
                current_file_number: -1,
                files_completed: 0,
                total_files: 2,
                bytes_completed: 0,
                total_bytes: 42,
                bytes_per_second: 0.0,
            }]
        );
    }

    #[test]
    fn viewer_upload_manifest_revalidates_bounded_files_directories_and_totals() {
        let file_path = b"Folder/file.bin";
        let directory_path = b"Empty/Deep";
        let entries = [
            RDNFileTransferListEntry {
                kind: FILE_TRANSFER_LIST_ENTRY_FILE,
                relative_path_utf8: file_path.as_ptr(),
                relative_path_length: file_path.len(),
                size: 8,
                modified_time: 123,
            },
            RDNFileTransferListEntry {
                kind: FILE_TRANSFER_LIST_ENTRY_DIRECTORY,
                relative_path_utf8: directory_path.as_ptr(),
                relative_path_length: directory_path.len(),
                size: 0,
                modified_time: 0,
            },
        ];
        let mut request = RDNFileTransferUploadStart {
            abi_version: ABI_VERSION,
            session_epoch: 7,
            transfer_id: 71,
            source_token: 81,
            entries: entries.as_ptr(),
            entry_count: entries.len(),
            total_bytes: 8,
        };
        let (files, directories) = unsafe { native_viewer_upload_manifest(&request) }
            .expect("bounded canonical upload manifest");
        assert_eq!(
            files,
            vec![NativeViewerUploadFileAuthority {
                relative_path: "Folder/file.bin".to_owned(),
                size: 8,
                modified_time: 123,
            }]
        );
        assert_eq!(
            directories,
            vec!["Empty".to_owned(), "Empty/Deep".to_owned()]
        );

        request.total_bytes = 7;
        assert!(unsafe { native_viewer_upload_manifest(&request) }.is_none());
        request.total_bytes = 8;
        request.entry_count = 0;
        assert!(unsafe { native_viewer_upload_manifest(&request) }.is_none());

        let ancestor = b"Folder";
        let collision = [
            entries[0],
            RDNFileTransferListEntry {
                kind: FILE_TRANSFER_LIST_ENTRY_DIRECTORY,
                relative_path_utf8: ancestor.as_ptr(),
                relative_path_length: ancestor.len(),
                size: 0,
                modified_time: 0,
            },
        ];
        request.entries = collision.as_ptr();
        request.entry_count = collision.len();
        assert!(unsafe { native_viewer_upload_manifest(&request) }.is_none());
    }

    #[test]
    fn viewer_upload_start_registers_semantic_job_and_reads_exact_callback_range() {
        let capture = Mutex::new(UploadReadCapture {
            source: b"abcdefgh".to_vec(),
            ..Default::default()
        });
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_upload_read = Some(capture_file_upload_read);
        shared.context = &capture as *const _ as usize;
        shared.active.store(true, Ordering::Release);
        shared.file_transfer_enabled.store(true, Ordering::Release);
        shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);

        let (sender, mut receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
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
        let file_path = b"payload.bin";
        let entries = [RDNFileTransferListEntry {
            kind: FILE_TRANSFER_LIST_ENTRY_FILE,
            relative_path_utf8: file_path.as_ptr(),
            relative_path_length: file_path.len(),
            size: 8,
            modified_time: 123,
        }];
        let request = RDNFileTransferUploadStart {
            abi_version: ABI_VERSION,
            session_epoch: 7,
            transfer_id: 71,
            source_token: 81,
            entries: entries.as_ptr(),
            entry_count: entries.len(),
            total_bytes: 8,
        };

        assert_eq!(
            unsafe { rdn_client_file_transfer_upload_start(&mut client, &request) },
            0
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_upload_start(&mut client, &request) },
            -3,
            "duplicate semantic transfer IDs must fail closed"
        );
        let Ok(Data::Message(message)) = receiver.try_recv() else {
            panic!("upload start must send one wire message");
        };
        let Some(message::Union::FileAction(action)) = message.union else {
            panic!("upload start must send FileAction");
        };
        let Some(file_action::Union::Receive(receive)) = action.union else {
            panic!("file upload must declare a receive job");
        };
        assert_eq!(
            (receive.id, receive.path.as_str(), receive.file_num),
            (71, "", 0)
        );
        assert_eq!(receive.files.len(), 1);
        assert_eq!(
            (
                receive.files[0].name.as_str(),
                receive.files[0].size,
                receive.files[0].modified_time,
            ),
            ("payload.bin", 8, 123)
        );
        assert_eq!(
            ui.shared
                .read_file_transfer_upload_source(71, 0, 2, 4)
                .as_deref(),
            Some(&b"cdef"[..])
        );
        assert_eq!(capture.lock().unwrap().requests, vec![(7, 71, 81, 0, 2, 4)]);
        assert!(ui
            .shared
            .read_file_transfer_upload_source(71, 0, 7, 2)
            .is_none());
        capture.lock().unwrap().short_write = true;
        assert!(ui
            .shared
            .read_file_transfer_upload_source(71, 0, 0, 4)
            .is_none());
        capture.lock().unwrap().short_write = false;
        ui.shared
            .file_transfer_session_epoch
            .store(8, Ordering::Release);
        assert!(ui
            .shared
            .read_file_transfer_upload_source(71, 0, 0, 4)
            .is_none());
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);

        let digest_message = ui
            .shared
            .file_transfer_upload_poll()
            .expect("ready upload must emit digest");
        let Some(message::Union::FileResponse(response)) = digest_message.union else {
            panic!("upload poll must emit FileResponse");
        };
        let Some(file_response::Union::Digest(digest)) = response.union else {
            panic!("first upload poll must emit digest");
        };
        assert_eq!(
            (
                digest.id,
                digest.file_num,
                digest.file_size,
                digest.last_modified
            ),
            (71, 0, 8, 123)
        );
        assert_eq!(
            ui.shared
                .file_transfer_upload_confirmation(&FileTransferSendConfirmRequest {
                    id: 71,
                    file_num: 0,
                    union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(0)),
                    ..Default::default()
                }),
            (true, Vec::new())
        );
        let block_message = ui
            .shared
            .file_transfer_upload_poll()
            .expect("confirmed upload must emit one bounded block");
        let Some(message::Union::FileResponse(response)) = block_message.union else {
            panic!("upload block must use FileResponse");
        };
        let Some(file_response::Union::Block(block)) = response.union else {
            panic!("confirmed upload must emit block");
        };
        let payload = if block.compressed {
            hbb_common::compress::decompress_with_limit(
                &block.data,
                hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES,
            )
            .unwrap()
        } else {
            block.data.to_vec()
        };
        assert_eq!(
            (block.id, block.file_num, payload.as_slice()),
            (71, 0, &b"abcdefgh"[..])
        );
        assert!(ui.shared.file_transfer_upload_poll().is_none());
        let done_message = ui
            .shared
            .file_transfer_upload_poll()
            .expect("completed payload must emit Done");
        let Some(message::Union::FileResponse(response)) = done_message.union else {
            panic!("upload Done must use FileResponse");
        };
        let Some(file_response::Union::Done(done)) = response.union else {
            panic!("final upload poll must emit Done");
        };
        assert_eq!((done.id, done.file_num), (71, 1));
        assert_eq!(
            ui.shared.file_transfer_upload_done(&done),
            (true, Vec::new())
        );
        assert!(ui.shared.active_file_upload_jobs.lock().unwrap().is_empty());
    }

    #[test]
    fn viewer_upload_confirmation_rejects_resume_and_skips_existing_without_replace() {
        let ui = BridgeUi::default();
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        let upload_job = |transfer_id| NativeViewerUploadJob {
            session_epoch: 7,
            transfer_id,
            source_token: 81,
            files: vec![NativeViewerUploadFileAuthority {
                relative_path: "payload.bin".to_owned(),
                size: 8,
                modified_time: 123,
            }]
            .into(),
            empty_directories: Vec::new().into(),
            total_bytes: 8,
            stage: NativeViewerUploadStage::AwaitingConfirmation { file_number: 0 },
            stage_started: Instant::now(),
            sequence: 0,
            files_completed: 0,
            bytes_completed: 0,
        };
        ui.shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .insert(71, upload_job(71));
        let (consumed, messages) =
            ui.shared
                .file_transfer_upload_confirmation(&FileTransferSendConfirmRequest {
                    id: 71,
                    file_num: 0,
                    union: Some(file_transfer_send_confirm_request::Union::OffsetBlk(1)),
                    ..Default::default()
                });
        assert!(consumed);
        assert_eq!(messages.len(), 1);
        assert!(matches!(
            messages[0].union.as_ref(),
            Some(message::Union::FileAction(FileAction {
                union: Some(file_action::Union::Cancel(FileTransferCancel {
                    id: 71,
                    ..
                })),
                ..
            }))
        ));
        assert!(!ui
            .shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .contains_key(&71));

        ui.shared
            .active_file_upload_jobs
            .lock()
            .unwrap()
            .insert(72, upload_job(72));
        let (consumed, messages) =
            ui.shared
                .file_transfer_upload_existing_target(&FileTransferDigest {
                    id: 72,
                    file_num: 0,
                    is_upload: true,
                    ..Default::default()
                });
        assert!(consumed);
        assert_eq!(messages.len(), 1);
        let Some(message::Union::FileAction(action)) = messages[0].union.as_ref() else {
            panic!("existing target must emit FileAction");
        };
        let Some(file_action::Union::SendConfirm(confirm)) = action.union.as_ref() else {
            panic!("existing target must emit SendConfirm");
        };
        assert_eq!(
            confirm.union,
            Some(file_transfer_send_confirm_request::Union::Skip(true))
        );
        assert!(matches!(
            ui.shared
                .active_file_upload_jobs
                .lock()
                .unwrap()
                .get(&72)
                .map(|job| job.stage),
            Some(NativeViewerUploadStage::ReadyDone)
        ));
    }

    #[test]
    fn viewer_upload_empty_directories_wait_for_each_exact_done() {
        let ui = BridgeUi::default();
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);
        ui.shared.active_file_upload_jobs.lock().unwrap().insert(
            73,
            NativeViewerUploadJob {
                session_epoch: 7,
                transfer_id: 73,
                source_token: 81,
                files: Vec::new().into(),
                empty_directories: vec!["a".to_owned(), "a/b".to_owned()].into(),
                total_bytes: 0,
                stage: NativeViewerUploadStage::AwaitingCreate {
                    directory_number: 0,
                },
                stage_started: Instant::now(),
                sequence: 0,
                files_completed: 0,
                bytes_completed: 0,
            },
        );
        let (consumed, messages) = ui.shared.file_transfer_upload_done(&FileTransferDone {
            id: 73,
            file_num: 0,
            ..Default::default()
        });
        assert!(consumed);
        assert_eq!(messages.len(), 1);
        let Some(message::Union::FileAction(action)) = messages[0].union.as_ref() else {
            panic!("next empty directory must use FileAction");
        };
        let Some(file_action::Union::Create(create)) = action.union.as_ref() else {
            panic!("next empty directory must use Create");
        };
        assert_eq!(create.path, "a/b");
        assert_eq!(
            ui.shared.file_transfer_upload_done(&FileTransferDone {
                id: 73,
                file_num: 0,
                ..Default::default()
            }),
            (true, Vec::new())
        );
        assert!(ui.shared.active_file_upload_jobs.lock().unwrap().is_empty());
    }
