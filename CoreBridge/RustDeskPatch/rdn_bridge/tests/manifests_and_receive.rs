    #[test]
    fn viewer_file_transfer_list_root_is_exact_single_flight_and_callback_scoped() {
        let captured = Mutex::new(Vec::<CapturedFileListEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_list = Some(capture_file_list_event);
        shared.context = &captured as *const _ as usize;
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        ui.on_connected(ConnType::FILE_TRANSFER);

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
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 6, 41) },
            -10
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 41) },
            -8
        );
        *session.server_file_transfer_enabled.write().unwrap() = true;
        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 41) },
            0
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 42) },
            -3
        );
        let Ok(Data::Message(message)) = receiver.try_recv() else {
            panic!("list request must send one message");
        };
        let Some(message::Union::FileAction(action)) = message.union else {
            panic!("list request must send FileAction");
        };
        let Some(file_action::Union::ReadDir(read)) = action.union else {
            panic!("list request must send ReadDir");
        };
        assert_eq!(read.path, "/");
        assert!(!read.include_hidden);

        ui.update_folder_files(
            0,
            &vec![
                remote_list_entry(FileType::Dir, "资料", 0),
                remote_list_entry(FileType::File, "report.txt", 42),
            ],
            "/".to_owned(),
            false,
            false,
        );
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedFileListEvent {
                session_epoch: 7,
                request_id: 41,
                status: FILE_TRANSFER_LIST_SUCCESS,
                entries: vec![
                    (
                        FILE_TRANSFER_LIST_ENTRY_DIRECTORY,
                        "资料".to_owned(),
                        0,
                        123
                    ),
                    (
                        FILE_TRANSFER_LIST_ENTRY_FILE,
                        "report.txt".to_owned(),
                        42,
                        123
                    ),
                ],
            }]
        );
        assert!(ui
            .shared
            .pending_file_list_request
            .lock()
            .unwrap()
            .is_none());

        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 42) },
            0
        );
        let _ = receiver.try_recv();
        ui.update_folder_files(
            0,
            &vec![
                remote_list_entry(FileType::File, "Alias", 1),
                remote_list_entry(FileType::File, "alias", 1),
            ],
            "/".to_owned(),
            false,
            false,
        );
        assert_eq!(
            captured.lock().unwrap()[1].status,
            FILE_TRANSFER_LIST_REJECTED
        );
        assert!(captured.lock().unwrap()[1].entries.is_empty());

        assert_eq!(
            unsafe { rdn_client_file_transfer_list_root(client_pointer, 7, 43) },
            0
        );
        let _ = receiver.try_recv();
        ui.job_error(0, "remote detail must not cross ABI".to_owned(), -1);
        assert_eq!(
            captured.lock().unwrap()[2].status,
            FILE_TRANSFER_LIST_UNAVAILABLE
        );
        assert!(captured.lock().unwrap()[2].entries.is_empty());
    }

    #[test]
    fn viewer_recursive_manifest_command_delivers_two_exact_parts_and_clears() {
        let captured = Mutex::new(Vec::<CapturedFileManifestEvent>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_manifest = Some(capture_file_manifest_event);
        shared.context = &captured as *const _ as usize;
        ui.shared.active.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
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
        let client_pointer = &mut client as *mut RDNClient;

        assert_eq!(
            unsafe { rdn_client_file_transfer_manifest_root(client_pointer, 6, 51) },
            -10
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_manifest_root(client_pointer, 7, 51) },
            0
        );
        assert_eq!(
            unsafe { rdn_client_file_transfer_manifest_root(client_pointer, 7, 52) },
            -3
        );

        let Ok(Data::Message(files_message)) = receiver.try_recv() else {
            panic!("manifest request must send recursive files message");
        };
        let Some(message::Union::FileAction(files_action)) = files_message.union else {
            panic!("recursive files message must be FileAction");
        };
        let Some(file_action::Union::AllFiles(files)) = files_action.union else {
            panic!("recursive files message must be AllFiles");
        };
        assert_eq!(
            (files.id, files.path.as_str(), files.include_hidden),
            (51, "/", false)
        );

        let Ok(Data::Message(directories_message)) = receiver.try_recv() else {
            panic!("manifest request must send empty-directories message");
        };
        let Some(message::Union::FileAction(directories_action)) = directories_message.union else {
            panic!("empty-directories message must be FileAction");
        };
        let Some(file_action::Union::ReadEmptyDirs(directories)) = directories_action.union else {
            panic!("empty-directories message must be ReadEmptyDirs");
        };
        assert_eq!(
            (directories.path.as_str(), directories.include_hidden),
            ("/", false)
        );

        ui.update_empty_dirs(ReadEmptyDirsResponse {
            path: "/".to_owned(),
            empty_dirs: vec![FileDirectory {
                path: "/资料/empty".to_owned(),
                ..Default::default()
            }],
            ..Default::default()
        });
        ui.update_folder_files(
            51,
            &vec![remote_list_entry(FileType::File, "资料/report.txt", 42)],
            "/".to_owned(),
            false,
            false,
        );
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[
                CapturedFileManifestEvent {
                    session_epoch: 7,
                    request_id: 51,
                    status: FILE_TRANSFER_LIST_SUCCESS,
                    part: FILE_TRANSFER_MANIFEST_PART_EMPTY_DIRECTORIES,
                    entries: vec![(
                        FILE_TRANSFER_LIST_ENTRY_DIRECTORY,
                        "资料/empty".to_owned(),
                        0,
                        0,
                    )],
                },
                CapturedFileManifestEvent {
                    session_epoch: 7,
                    request_id: 51,
                    status: FILE_TRANSFER_LIST_SUCCESS,
                    part: FILE_TRANSFER_MANIFEST_PART_FILES,
                    entries: vec![(
                        FILE_TRANSFER_LIST_ENTRY_FILE,
                        "资料/report.txt".to_owned(),
                        42,
                        123,
                    )],
                },
            ]
        );
        assert!(ui
            .shared
            .pending_file_manifest_request
            .lock()
            .unwrap()
            .is_none());

        assert_eq!(
            unsafe { rdn_client_file_transfer_manifest_root(client_pointer, 7, 52) },
            -3,
            "an untagged empty-directory response makes manifest single-use per epoch"
        );
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn viewer_receive_block_owns_raw_and_bounded_decompressed_payloads() {
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
        let raw = FileTransferBlock {
            id: 61,
            file_num: 0,
            data: b"raw".to_vec().into(),
            ..Default::default()
        };
        assert_eq!(
            job.receive_block(&raw),
            Some(NativeViewerReceiveBlock {
                session_epoch: 7,
                transfer_id: 61,
                file_number: 0,
                payload: b"raw".to_vec(),
            })
        );

        let plain = vec![b'a'; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES];
        let compressed = FileTransferBlock {
            id: 61,
            file_num: 1,
            data: hbb_common::compress::compress(&plain).into(),
            compressed: true,
            ..Default::default()
        };
        assert_eq!(
            job.receive_block(&compressed),
            Some(NativeViewerReceiveBlock {
                session_epoch: 7,
                transfer_id: 61,
                file_number: 1,
                payload: plain,
            })
        );
    }

    #[test]
    fn viewer_receive_block_rejects_wrong_job_file_and_payload_bounds() {
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
        let block = |id, file_num, data: Vec<u8>, compressed| FileTransferBlock {
            id,
            file_num,
            data: data.into(),
            compressed,
            ..Default::default()
        };

        assert!(job
            .receive_block(&block(60, 0, b"x".to_vec(), false))
            .is_none());
        assert!(job
            .receive_block(&block(61, -1, b"x".to_vec(), false))
            .is_none());
        assert!(job
            .receive_block(&block(61, 2, b"x".to_vec(), false))
            .is_none());
        assert!(job
            .receive_block(&block(61, 0, Vec::new(), false))
            .is_none());
        assert!(job
            .receive_block(&block(
                61,
                0,
                vec![0; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES + 1],
                false,
            ))
            .is_none());
        assert!(job
            .receive_block(&block(61, 0, b"not-zstd".to_vec(), true))
            .is_none());
        assert!(job
            .receive_block(&block(
                61,
                0,
                hbb_common::compress::compress(&vec![
                    b'a';
                    hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES
                        + 1
                ]),
                true,
            ))
            .is_none());
    }

    #[test]
    fn viewer_receive_block_callback_is_exact_session_and_callback_scoped() {
        let captured = Mutex::new(Vec::<CapturedFileReceiveBlock>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_receive_block = Some(capture_file_receive_block);
        shared.context = &captured as *const _ as usize;
        let mut block = NativeViewerReceiveBlock {
            session_epoch: 7,
            transfer_id: 61,
            file_number: 1,
            payload: b"owned".to_vec(),
        };

        assert!(!ui.shared.emit_file_transfer_receive_block(&block));
        ui.shared.active.store(true, Ordering::Release);
        ui.shared.authenticated.store(true, Ordering::Release);
        ui.shared
            .file_transfer_enabled
            .store(true, Ordering::Release);
        ui.shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        assert!(ui.shared.emit_file_transfer_receive_block(&block));
        block.payload.fill(b'x');
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedFileReceiveBlock {
                abi_version: ABI_VERSION,
                session_epoch: 7,
                transfer_id: 61,
                file_number: 1,
                payload: b"owned".to_vec(),
            }]
        );

        block.session_epoch = 8;
        assert!(!ui.shared.emit_file_transfer_receive_block(&block));
        ui.shared.authenticated.store(false, Ordering::Release);
        block.session_epoch = 7;
        assert!(!ui.shared.emit_file_transfer_receive_block(&block));
        assert_eq!(captured.lock().unwrap().len(), 1);
    }

    #[test]
    fn viewer_io_loop_hook_consumes_only_registered_download_blocks() {
        let captured = Mutex::new(Vec::<CapturedFileReceiveBlock>::new());
        let mut ui = BridgeUi::default();
        let shared = Arc::get_mut(&mut ui.shared).unwrap();
        shared.callbacks.on_file_transfer_receive_block = Some(capture_file_receive_block);
        shared.context = &captured as *const _ as usize;
        shared.active.store(true, Ordering::Release);
        shared.authenticated.store(true, Ordering::Release);
        shared.file_transfer_enabled.store(true, Ordering::Release);
        shared
            .file_transfer_session_epoch
            .store(7, Ordering::Release);
        shared.active_file_download_jobs.lock().unwrap().insert(
            61,
            NativeViewerDownloadJob {
                session_epoch: 7,
                manifest_request_id: 51,
                transfer_id: 61,
                total_files: 2,
                total_bytes: 10,
                manifest_files: viewer_manifest_file_authorities(&[(5, 100), (5, 200)]),
                next_digest_file_number: 2,
                sequence: 0,
                files_completed: 0,
                bytes_completed: 0,
            },
        );

        let block = |id, file_num, data: Vec<u8>| FileTransferBlock {
            id,
            file_num,
            data: data.into(),
            compressed: false,
            ..Default::default()
        };
        assert!(!ui.native_file_transfer_receive_block(&block(60, 0, b"foreign".to_vec())));
        assert!(ui.native_file_transfer_receive_block(&block(61, 0, b"owned".to_vec())));
        assert!(ui.native_file_transfer_receive_block(&block(61, 2, b"invalid".to_vec())));
        assert_eq!(
            captured.lock().unwrap().as_slice(),
            &[CapturedFileReceiveBlock {
                abi_version: ABI_VERSION,
                session_epoch: 7,
                transfer_id: 61,
                file_number: 0,
                payload: b"owned".to_vec(),
            }]
        );

        ui.shared.active_file_download_jobs.lock().unwrap().clear();
        assert!(!ui.native_file_transfer_receive_block(&block(61, 0, b"stale".to_vec())));
    }

    #[test]
    fn viewer_digest_hook_confirms_only_exact_manifest_file_sequence() {
        let ui = BridgeUi::default();
        ui.shared.active_file_download_jobs.lock().unwrap().insert(
            61,
            NativeViewerDownloadJob {
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
            },
        );
        let digest = |id, file_num, size, modified_time| FileTransferDigest {
            id,
            file_num,
            file_size: size,
            last_modified: modified_time,
            ..Default::default()
        };
        let block = |file_num| FileTransferBlock {
            id: 61,
            file_num,
            data: b"owned".to_vec().into(),
            ..Default::default()
        };

        assert!(ui
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .get(&61)
            .unwrap()
            .receive_block(&block(0))
            .is_none());

        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(60, 0, 10, 100)),
            (false, None)
        );
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 1, 32, 200)),
            (true, None),
            "out-of-order digest must be consumed without confirmation"
        );
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 0, 11, 100)),
            (true, None),
            "manifest size drift must fail closed"
        );
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 0, 10, 101)),
            (true, None),
            "manifest mtime drift must fail closed"
        );

        let (consumed, confirmation) =
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 0, 10, 100));
        assert!(consumed);
        let confirmation = confirmation.expect("exact first digest must be confirmed");
        assert_eq!((confirmation.id, confirmation.file_num), (61, 0));
        assert_eq!(
            confirmation.union,
            Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
        );
        {
            let jobs = ui.shared.active_file_download_jobs.lock().unwrap();
            let job = jobs.get(&61).unwrap();
            assert!(job.receive_block(&block(0)).is_some());
            assert!(job.receive_block(&block(1)).is_none());
        }
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 0, 10, 100)),
            (true, None),
            "duplicate digest must fail closed"
        );

        let mut resume = digest(61, 1, 32, 200);
        resume.is_resume = true;
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&resume),
            (true, None)
        );
        resume.is_resume = false;
        resume.transferred_size = 1;
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&resume),
            (true, None)
        );
        resume.transferred_size = 0;
        resume.is_upload = true;
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&resume),
            (true, None)
        );
        resume.is_upload = false;
        resume.is_identical = true;
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&resume),
            (true, None)
        );

        let (consumed, confirmation) =
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 1, 32, 200));
        assert!(consumed);
        assert_eq!(
            confirmation.and_then(|request| request.union),
            Some(file_transfer_send_confirm_request::Union::OffsetBlk(0))
        );
        assert!(ui
            .shared
            .active_file_download_jobs
            .lock()
            .unwrap()
            .get(&61)
            .unwrap()
            .receive_block(&block(1))
            .is_some());
        ui.shared.active_file_download_jobs.lock().unwrap().clear();
        assert_eq!(
            ui.native_file_transfer_download_digest_confirmation(&digest(61, 1, 32, 200)),
            (false, None)
        );
    }
