    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_resume_abort_removes_checkpointed_staging() {
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
        let mut host = ready_test_host("native-resume-abort-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            57,
            "abort/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 4, 14)],
            4,
            true,
        ) else {
            panic!("abort job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 4, 14, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(job.write_block(0, b"ab", false), Ok(()));
        job.abort();
        assert!(!fixture.root.join("abort/file.txt.farpane-part").exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_resume_rejects_after_unbind() {
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
        let mut host = ready_test_host("native-resume-unbind-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut first) = native_host_begin_new_file_write_job(
            58,
            "resume-unbind/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 4, 15)],
            4,
            true,
        ) else {
            panic!("resume unbind seed must be admitted");
        };
        assert_eq!(
            first.confirm_file_digest(0, 4, 15, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(first.write_block(0, b"ab", false), Ok(()));
        drop(first);

        let NativeHostWriteJobAdmission::Admitted(mut resumed) =
            native_host_begin_new_file_write_job(
                59,
                "resume-unbind/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 15)],
                4,
                true,
            )
        else {
            panic!("resume unbind job must be admitted");
        };
        unbind_media_host();
        assert_eq!(
            resumed.confirm_file_digest(0, 4, 15, true),
            Err(NativeHostWriteJobError::Unavailable)
        );
        resumed.abort();
        assert!(fixture
            .root
            .join("resume-unbind/file.txt.farpane-part")
            .exists());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_read_lists_virtual_root_recursive_files_and_empty_directories() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(&receive_root)
                .expect("open read owner"),
        );
        owner
            .create_directory(Path::new("folder"))
            .expect("create folder");
        owner
            .create_directory(Path::new("empty"))
            .expect("create empty folder");
        let mut file = owner
            .create_new_file(Path::new("folder/item.txt"))
            .expect("create read file");
        file.write_all(b"payload").expect("write read file");
        drop(file);
        let mut host = ready_test_host("native-read-list-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostFileReadOutcome::Succeeded((path, entries)) =
            native_host_list_directory("/", false)
        else {
            panic!("virtual root listing must succeed");
        };
        assert_eq!(path, "/");
        assert_eq!(
            entries
                .iter()
                .map(|entry| (entry.name(), entry.kind()))
                .collect::<Vec<_>>(),
            vec![
                ("empty", NativeHostReadEntryKind::Directory),
                ("folder", NativeHostReadEntryKind::Directory),
            ]
        );

        let NativeHostFileReadOutcome::Succeeded((path, entries)) =
            native_host_list_files_recursive("/folder", false)
        else {
            panic!("recursive file listing must succeed");
        };
        assert_eq!(path, "/folder");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name(), "item.txt");
        assert_eq!(entries[0].kind(), NativeHostReadEntryKind::File);
        assert_eq!(entries[0].size(), 7);

        let NativeHostFileReadOutcome::Succeeded((path, empty_directories)) =
            native_host_list_empty_directories("/", false)
        else {
            panic!("empty-directory listing must succeed");
        };
        assert_eq!(path, "/");
        assert_eq!(empty_directories, vec!["/empty"]);
        assert!(matches!(
            native_host_list_directory("/../escape", false),
            NativeHostFileReadOutcome::Rejected(NativeHostReadJobError::InvalidPath)
        ));
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_read_job_requires_confirmation_and_streams_exact_bounded_suffix() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(&receive_root)
                .expect("open read owner"),
        );
        let payload = vec![b'A'; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES + 37];
        let mut file = owner
            .create_new_file(Path::new("payload.bin"))
            .expect("create payload");
        file.write_all(&payload).expect("write payload");
        drop(file);
        let mut host = ready_test_host("native-read-job-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostReadJobAdmission::Admitted(mut job) =
            native_host_begin_read_job(81, "/payload.bin", 0, false, true)
        else {
            panic!("read job must be admitted");
        };
        assert_eq!(job.id(), 81);
        assert_eq!(job.wire_path(), "/payload.bin");
        assert_eq!(job.entries().len(), 1);
        assert!(matches!(
            job.poll(),
            Ok(NativeHostReadJobStep::Digest {
                file_num: 0,
                file_size,
                ..
            }) if file_size == payload.len() as u64
        ));
        assert_eq!(
            job.poll(),
            Ok(NativeHostReadJobStep::WaitingForConfirmation)
        );
        assert_eq!(
            job.confirm(
                0,
                NativeHostReadConfirmation::ContinueAt { offset: u32::MAX },
            ),
            Err(NativeHostReadJobError::OffsetOutOfRange)
        );
        job.confirm(0, NativeHostReadConfirmation::ContinueAt { offset: 7 })
            .expect("confirm bounded resume offset");

        let mut received = Vec::new();
        loop {
            match job.poll().expect("poll read job") {
                NativeHostReadJobStep::Block {
                    file_num,
                    data,
                    compressed,
                } => {
                    assert_eq!(file_num, 0);
                    let data = if compressed {
                        hbb_common::compress::decompress_with_limit(
                            &data,
                            hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES,
                        )
                        .expect("decode bounded block")
                    } else {
                        data
                    };
                    assert!(data.len() <= hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES);
                    received.extend_from_slice(&data);
                }
                NativeHostReadJobStep::Done { file_num } => {
                    assert_eq!(file_num, 1);
                    break;
                }
                other => panic!("unexpected read step: {other:?}"),
            }
        }
        assert_eq!(received, payload[7..]);
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_read_job_skip_snapshot_replacement_and_unbind_fail_closed() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(&receive_root)
                .expect("open read owner"),
        );
        owner
            .create_directory(Path::new("folder"))
            .expect("create folder");
        for (name, bytes) in [("a.txt", b"aaa".as_slice()), ("b.txt", b"bbb".as_slice())] {
            let mut file = owner
                .create_new_file(Path::new(&format!("folder/{name}")))
                .expect("create read fixture");
            file.write_all(bytes).expect("write read fixture");
        }
        let mut host = ready_test_host("native-read-fail-closed-test");
        host.file_service_owner = Some(owner.clone());
        bind_media_host(&host);

        let NativeHostReadJobAdmission::Admitted(mut job) =
            native_host_begin_read_job(82, "/folder", 0, false, true)
        else {
            panic!("multi-file read job must be admitted");
        };
        assert!(matches!(
            job.poll(),
            Ok(NativeHostReadJobStep::Digest { file_num: 0, .. })
        ));
        job.confirm(0, NativeHostReadConfirmation::Skip)
            .expect("skip first file");
        assert!(matches!(
            job.poll(),
            Ok(NativeHostReadJobStep::Digest { file_num: 1, .. })
        ));
        owner
            .rename_entry(Path::new("folder/b.txt"), Path::new("folder/b-old.txt"))
            .expect("replace snapshotted file");
        let mut replacement = owner
            .create_new_file(Path::new("folder/b.txt"))
            .expect("create replacement");
        replacement.write_all(b"bbb").expect("write replacement");
        drop(replacement);
        assert_eq!(
            job.confirm(1, NativeHostReadConfirmation::ContinueAt { offset: 0 },),
            Err(NativeHostReadJobError::SnapshotChanged)
        );

        let NativeHostReadJobAdmission::Admitted(mut unbound) =
            native_host_begin_read_job(83, "/folder/b.txt", 0, false, false)
        else {
            panic!("unbind read job must be admitted");
        };
        unbind_media_host();
        assert_eq!(unbound.poll(), Err(NativeHostReadJobError::Unavailable));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_file_mutation_adapter_is_relative_bounded_and_no_replace() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
            receive_root.as_path(),
        )
        .expect("open private receive root");

        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::CreateDirectory { path: "folder" },
        )
        .is_ok());
        drop(
            owner
                .create_new_file(Path::new("folder/source.txt"))
                .expect("create private source"),
        );
        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::Rename {
                path: "folder/source.txt",
                new_name: "renamed.txt",
            },
        )
        .is_ok());
        assert!(fixture.root.join("folder/renamed.txt").is_file());

        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::Rename {
                path: "folder/renamed.txt",
                new_name: "../escape.txt",
            },
        )
        .is_err());
        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::RemoveDirectory {
                path: "folder",
                recursive: true,
            },
        )
        .is_err());
        assert!(fixture.root.join("folder/renamed.txt").is_file());

        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::RemoveFile {
                path: "folder/renamed.txt",
            },
        )
        .is_ok());
        assert!(apply_native_host_file_mutation(
            &owner,
            NativeHostFileMutation::RemoveDirectory {
                path: "folder",
                recursive: false,
            },
        )
        .is_ok());

        let mut host = ready_test_host("file-mutation-test");
        host.file_service_owner = Some(Arc::new(owner));
        bind_media_host(&host);
        assert_eq!(
            native_host_dispatch_file_mutation(NativeHostFileMutation::CreateDirectory {
                path: "bound",
            }),
            NativeHostFileMutationOutcome::Succeeded
        );
        assert_eq!(
            native_host_dispatch_file_mutation(NativeHostFileMutation::CreateDirectory {
                path: "../escape",
            }),
            NativeHostFileMutationOutcome::Rejected
        );
        MEDIA_BROKER.lock().unwrap().file_service_owner = None;
        assert_eq!(
            native_host_dispatch_file_mutation(NativeHostFileMutation::CreateDirectory {
                path: "unavailable",
            }),
            NativeHostFileMutationOutcome::Unavailable
        );
        unbind_media_host();
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_accepts_explicit_audio_opt_in_only() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "";
        let server_public_key = "synthetic-public-key";
        let (identity, options) = fixture.write_startup_documents(
            rendezvous_server,
            relay_server,
            server_public_key,
            true,
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
                true,
                "",
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
                false,
                "",
                false,
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_storage_readback_accepts_explicit_file_transfer_opt_in_only() {
        let fixture = HostStorageFixture::new();
        let rendezvous_server = "127.0.0.1:21116";
        let relay_server = "";
        let server_public_key = "synthetic-public-key";
        let (identity, options) = fixture.write_startup_documents(
            rendezvous_server,
            relay_server,
            server_public_key,
            false,
            true,
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
                true,
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
                false,
                "",
                false,
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }

    #[cfg(unix)]
    #[test]
    fn host_password_storage_readback_accepts_exact_set_and_clear_without_mutation() {
        let fixture = HostStorageFixture::new();
        let storage = "synthetic-verifier";
        let salt = "synthetic-salt";
        let (identity, options) = fixture.write_password_documents(storage, salt);

        assert_eq!(
            verify_host_password_storage_paths(&fixture.identity, &fixture.options, storage, salt,),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);

        let (cleared_identity, cleared_options) = fixture.write_password_documents("", salt);
        assert_eq!(
            verify_host_password_storage_paths(&fixture.identity, &fixture.options, "", salt,),
            Ok(())
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), cleared_identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), cleared_options);
    }

    #[cfg(unix)]
    #[test]
    fn host_password_storage_readback_rejects_stale_verifier_or_salt_without_mutation() {
        let fixture = HostStorageFixture::new();
        let (identity, options) =
            fixture.write_password_documents("persisted-verifier", "persisted-salt");

        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "new-verifier",
                "persisted-salt",
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "persisted-verifier",
                "new-salt",
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(
            verify_host_password_storage_paths(
                &fixture.identity,
                &fixture.options,
                "",
                "persisted-salt",
            ),
            Err(HostStoragePreflightError::PersistenceMismatch)
        );
        assert_eq!(fs::read(&fixture.identity).unwrap(), identity);
        assert_eq!(fs::read(&fixture.options).unwrap(), options);
    }
