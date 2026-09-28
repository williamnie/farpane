    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_receive_root_commits_zero_length_before_following_file() {
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
        let mut host = ready_test_host("native-write-root-zero-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            45,
            "",
            0,
            vec![
                NativeHostWriteEntry::new("zero.txt".to_string(), 0, 11),
                NativeHostWriteEntry::new("data.txt".to_string(), 3, 12),
            ],
            3,
            true,
        ) else {
            panic!("receive-root write job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 0, 11, false),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(fs::read(fixture.root.join("zero.txt")).unwrap(), b"");
        assert_eq!(
            job.confirm_file_digest(1, 3, 12, false),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(job.write_block(1, b"abc", false), Ok(()));
        assert_eq!(job.finish(2), Ok(()));
        assert_eq!(fs::read(fixture.root.join("data.txt")).unwrap(), b"abc");
        assert!(!fixture.root.join("zero.txt.farpane-part").exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_new_file_write_job_rejects_bounds_order_and_resume() {
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
        let mut host = ready_test_host("native-write-bounds-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            42,
            "bounded",
            0,
            vec![NativeHostWriteEntry::new("file.txt".to_string(), 3, 3)],
            3,
            true,
        ) else {
            panic!("native write job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 3, 3, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(
            job.write_block(1, b"x", false),
            Err(NativeHostWriteJobError::UnexpectedFileNumber)
        );
        let oversized_wire = vec![0; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES + 1];
        assert_eq!(
            job.write_block(0, &oversized_wire, false),
            Err(NativeHostWriteJobError::WirePayloadTooLarge)
        );
        let oversized_decoded = hbb_common::compress::compress(&vec![
            b'x';
            hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES
                + 1
        ]);
        assert_eq!(
            job.write_block(0, &oversized_decoded, true),
            Err(NativeHostWriteJobError::DecodedPayloadInvalidOrTooLarge)
        );
        assert_eq!(
            job.write_block(0, b"four", false),
            Err(NativeHostWriteJobError::FileSizeExceeded)
        );
        drop(job);
        assert!(!fixture.root.join("bounded/file.txt").exists());
        assert!(!fixture.root.join("bounded/file.txt.farpane-part").exists());

        assert!(matches!(
            native_host_begin_new_file_write_job(
                43,
                "../escape",
                0,
                vec![NativeHostWriteEntry::new("file.txt".to_string(), 0, 0)],
                0,
                false,
            ),
            NativeHostWriteJobAdmission::Rejected(NativeHostWriteJobError::InvalidPath)
        ));
        assert!(matches!(
            native_host_begin_new_file_write_job(
                44,
                "incoming",
                0,
                vec![
                    NativeHostWriteEntry::new("same.txt".to_string(), 0, 0),
                    NativeHostWriteEntry::new("same.txt".to_string(), 0, 0),
                ],
                0,
                false,
            ),
            NativeHostWriteJobAdmission::Rejected(NativeHostWriteJobError::DuplicateDestination)
        ));
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_new_file_write_job_abort_cleans_only_staging() {
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
        let mut host = ready_test_host("native-write-drop-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            45,
            "cancel",
            0,
            vec![
                NativeHostWriteEntry::new("committed.txt".to_string(), 1, 4),
                NativeHostWriteEntry::new("partial.txt".to_string(), 2, 5),
            ],
            3,
            false,
        ) else {
            panic!("native write job must be admitted");
        };
        assert_eq!(job.write_block(0, b"a", false), Ok(()));
        assert_eq!(job.write_block(1, b"b", false), Ok(()));
        assert!(fixture.root.join("cancel/committed.txt").is_file());
        assert!(fixture
            .root
            .join("cancel/partial.txt.farpane-part")
            .is_file());
        job.abort();

        assert_eq!(
            fs::read(fixture.root.join("cancel/committed.txt")).unwrap(),
            b"a"
        );
        assert!(!fixture.root.join("cancel/partial.txt").exists());
        assert!(!fixture
            .root
            .join("cancel/partial.txt.farpane-part")
            .exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_new_file_write_job_rejects_after_unbind() {
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
        let mut host = ready_test_host("native-write-unbind-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            46,
            "unbind/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 2, 6)],
            2,
            false,
        ) else {
            panic!("native write job must be admitted");
        };
        assert_eq!(job.write_block(0, b"a", false), Ok(()));
        unbind_media_host();
        assert_eq!(
            job.write_block(0, b"b", false),
            Err(NativeHostWriteJobError::Unavailable)
        );
        job.abort();
        assert!(!fixture.root.join("unbind/file.txt").exists());
        assert!(!fixture.root.join("unbind/file.txt.farpane-part").exists());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_single_file_resume_reuses_verified_checkpoint() {
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
        let mut host = ready_test_host("native-resume-success-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut first) = native_host_begin_new_file_write_job(
            51,
            "resume/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 6, 10)],
            6,
            true,
        ) else {
            panic!("first native resume job must be admitted");
        };
        assert_eq!(
            first.confirm_file_digest(0, 6, 10, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(first.write_block(0, b"abc", false), Ok(()));
        drop(first);
        assert_eq!(
            fs::read(fixture.root.join("resume/file.txt.farpane-part")).unwrap(),
            b"abc"
        );

        let NativeHostWriteJobAdmission::Admitted(mut resumed) =
            native_host_begin_new_file_write_job(
                52,
                "resume/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 6, 10)],
                6,
                true,
            )
        else {
            panic!("second native resume job must be admitted");
        };
        assert_eq!(
            resumed.confirm_file_digest(0, 6, 10, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(3))
        );
        assert_eq!(resumed.write_block(0, b"def", false), Ok(()));
        assert_eq!(resumed.finish(1), Ok(()));
        assert_eq!(
            fs::read(fixture.root.join("resume/file.txt")).unwrap(),
            b"abcdef"
        );
        assert!(!fixture.root.join("resume/file.txt.farpane-part").exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_existing_target_requires_skip_and_preserves_original() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let destination = fixture.root.join("existing/file.txt");
        fs::create_dir(destination.parent().unwrap()).expect("create existing parent");
        fs::set_permissions(
            destination.parent().unwrap(),
            fs::Permissions::from_mode(0o700),
        )
        .expect("secure existing parent");
        HostStorageFixture::write_private(&destination, b"original");
        HostStorageFixture::write_private(
            &fixture.root.join("existing/file.txt.farpane-part"),
            b"old-partial",
        );
        let existing_modified = fs::metadata(&destination)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-existing-skip-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            63,
            "existing/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 3, 99)],
            3,
            true,
        ) else {
            panic!("existing-target job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 3, 99, false),
            Ok(NativeHostWriteDigestDecision::ExistingTarget {
                file_size: 8,
                last_modified: existing_modified,
                is_identical: false,
            })
        );
        assert_eq!(
            job.write_block(0, b"new", false),
            Err(NativeHostWriteJobError::ExistingTargetDecisionRequired)
        );
        assert_eq!(
            job.confirm_existing_target_decision(0, NativeHostExistingTargetDecision::Skip),
            Ok(())
        );
        assert_eq!(job.finish(1), Ok(()));
        assert_eq!(fs::read(&destination).unwrap(), b"original");
        assert!(!fixture.root.join("existing/file.txt.farpane-part").exists());
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_existing_target_rejects_replace_decisions_and_unsafe_entries() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let destination = fixture.root.join("replace.txt");
        HostStorageFixture::write_private(&destination, b"keep");
        let existing_modified = fs::metadata(&destination)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-existing-replace-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            64,
            "replace.txt",
            0,
            vec![NativeHostWriteEntry::new(
                String::new(),
                4,
                existing_modified,
            )],
            4,
            true,
        ) else {
            panic!("replace-target job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 4, existing_modified, false),
            Ok(NativeHostWriteDigestDecision::ExistingTarget {
                file_size: 4,
                last_modified: existing_modified,
                is_identical: true,
            })
        );
        assert_eq!(
            job.confirm_existing_target_decision(
                0,
                NativeHostExistingTargetDecision::Replace { offset: 0 },
            ),
            Err(NativeHostWriteJobError::ExistingTargetReplacementUnsupported)
        );
        job.abort();
        assert_eq!(fs::read(&destination).unwrap(), b"keep");

        let unsafe_target = fixture.root.join("unsafe.txt");
        HostStorageFixture::write_private(&unsafe_target, b"unsafe");
        fs::set_permissions(&unsafe_target, fs::Permissions::from_mode(0o644)).unwrap();
        let NativeHostWriteJobAdmission::Admitted(mut unsafe_job) =
            native_host_begin_new_file_write_job(
                65,
                "unsafe.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 6, 101)],
                6,
                true,
            )
        else {
            panic!("unsafe-target job must be admitted before descriptor inspection");
        };
        assert_eq!(
            unsafe_job.confirm_file_digest(0, 6, 101, false),
            Err(NativeHostWriteJobError::ExistingTargetUnsafe)
        );
        unsafe_job.abort();
        assert_eq!(fs::read(&unsafe_target).unwrap(), b"unsafe");
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_existing_target_skip_preserves_multifile_accounting() {
        let _lock = MEDIA_BROKER_TEST_LOCK.lock().unwrap();
        unbind_media_host();
        let fixture = HostStorageFixture::new();
        let batch = fixture.root.join("batch");
        fs::create_dir(&batch).expect("create batch directory");
        fs::set_permissions(&batch, fs::Permissions::from_mode(0o700))
            .expect("secure batch directory");
        HostStorageFixture::write_private(&batch.join("keep.txt"), b"keep");
        let receive_root = fs::canonicalize(&fixture.root).expect("canonical receive root");
        let owner = Arc::new(
            rdn_host_file_transfer::NativeHostFileServiceOwner::open_existing(
                receive_root.as_path(),
            )
            .expect("open private receive root"),
        );
        let mut host = ready_test_host("native-existing-multifile-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut job) = native_host_begin_new_file_write_job(
            66,
            "batch",
            0,
            vec![
                NativeHostWriteEntry::new("new.txt".to_string(), 3, 102),
                NativeHostWriteEntry::new("keep.txt".to_string(), 4, 103),
            ],
            7,
            true,
        ) else {
            panic!("multi-file existing-target job must be admitted");
        };
        assert_eq!(
            job.confirm_file_digest(0, 3, 102, false),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(job.write_block(0, b"new", false), Ok(()));
        assert!(matches!(
            job.confirm_file_digest(1, 4, 103, false),
            Ok(NativeHostWriteDigestDecision::ExistingTarget { .. })
        ));
        assert_eq!(
            job.confirm_existing_target_decision(1, NativeHostExistingTargetDecision::Skip),
            Ok(())
        );
        assert_eq!(job.finish(2), Ok(()));
        assert_eq!(fs::read(batch.join("new.txt")).unwrap(), b"new");
        assert_eq!(fs::read(batch.join("keep.txt")).unwrap(), b"keep");
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_write_job_reserves_staging_path_until_drop() {
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
        let mut host = ready_test_host("native-resume-reservation-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(first) = native_host_begin_new_file_write_job(
            60,
            "reserved/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 4, 16)],
            4,
            true,
        ) else {
            panic!("first reserved job must be admitted");
        };
        assert!(matches!(
            native_host_begin_new_file_write_job(
                61,
                "reserved/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 16)],
                4,
                true,
            ),
            NativeHostWriteJobAdmission::Rejected(NativeHostWriteJobError::DuplicateDestination)
        ));
        drop(first);
        assert!(matches!(
            native_host_begin_new_file_write_job(
                62,
                "reserved/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 16)],
                4,
                true,
            ),
            NativeHostWriteJobAdmission::Admitted(_)
        ));
        unbind_media_host();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_host_resume_rejects_tampered_or_mismatched_checkpoint() {
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
        let mut host = ready_test_host("native-resume-tamper-test");
        host.file_service_owner = Some(owner);
        bind_media_host(&host);

        let NativeHostWriteJobAdmission::Admitted(mut first) = native_host_begin_new_file_write_job(
            53,
            "tamper/file.txt",
            0,
            vec![NativeHostWriteEntry::new(String::new(), 6, 11)],
            6,
            true,
        ) else {
            panic!("tamper seed job must be admitted");
        };
        assert_eq!(
            first.confirm_file_digest(0, 6, 11, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(first.write_block(0, b"abc", false), Ok(()));
        drop(first);
        let staging = fixture.root.join("tamper/file.txt.farpane-part");
        let mut tampered = fs::OpenOptions::new()
            .write(true)
            .open(&staging)
            .expect("open staging for tamper fixture");
        std::io::Seek::seek(&mut tampered, std::io::SeekFrom::Start(0))
            .expect("seek tamper fixture");
        std::io::Write::write_all(&mut tampered, b"x").expect("tamper staged prefix");
        tampered.sync_all().expect("sync tamper fixture");
        drop(tampered);

        let NativeHostWriteJobAdmission::Admitted(mut tampered_resume) =
            native_host_begin_new_file_write_job(
                54,
                "tamper/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 6, 11)],
                6,
                true,
            )
        else {
            panic!("tampered resume job must be admitted");
        };
        assert_eq!(
            tampered_resume.confirm_file_digest(0, 6, 11, true),
            Err(NativeHostWriteJobError::ResumeStateInvalid)
        );
        assert!(!staging.exists());

        let NativeHostWriteJobAdmission::Admitted(mut mismatch_seed) =
            native_host_begin_new_file_write_job(
                55,
                "mismatch/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 12)],
                4,
                true,
            )
        else {
            panic!("mismatch seed job must be admitted");
        };
        assert_eq!(
            mismatch_seed.confirm_file_digest(0, 4, 12, true),
            Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0))
        );
        assert_eq!(mismatch_seed.write_block(0, b"ab", false), Ok(()));
        drop(mismatch_seed);
        let NativeHostWriteJobAdmission::Admitted(mut mismatch_resume) =
            native_host_begin_new_file_write_job(
                56,
                "mismatch/file.txt",
                0,
                vec![NativeHostWriteEntry::new(String::new(), 4, 13)],
                4,
                true,
            )
        else {
            panic!("mismatch resume job must be admitted");
        };
        assert_eq!(
            mismatch_resume.confirm_file_digest(0, 4, 13, true),
            Err(NativeHostWriteJobError::ResumeStateInvalid)
        );
        assert!(!fixture.root.join("mismatch/file.txt.farpane-part").exists());
        unbind_media_host();
    }
