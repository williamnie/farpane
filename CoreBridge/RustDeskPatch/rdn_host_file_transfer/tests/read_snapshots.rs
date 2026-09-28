    #[test]
    fn native_owner_recursively_snapshots_and_reads_pinned_private_files() {
        let sandbox = TestDirectory::new("read_recursive");
        let trusted = sandbox.child("trusted");
        let moved = sandbox.child("moved");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        owner
            .create_directory(Path::new("folder"))
            .expect("create folder");
        let mut first = owner
            .create_new_file(Path::new("folder/first.txt"))
            .expect("create first file");
        first.write_all(b"first").expect("write first file");
        drop(first);
        let mut second = owner
            .create_new_file(Path::new("folder/second.txt"))
            .expect("create second file");
        second.write_all(b"second").expect("write second file");
        drop(second);

        let entries = owner
            .snapshot_files_recursive(Path::new("folder"), false)
            .expect("snapshot folder");
        assert_eq!(
            entries
                .iter()
                .map(|entry| (entry.wire_name(), entry.size()))
                .collect::<Vec<_>>(),
            vec![("first.txt", 5), ("second.txt", 6)]
        );

        fs::rename(&trusted, &moved).expect("move admitted root");
        symlink(&outside, &trusted).expect("replace root path");
        let mut contents = String::new();
        owner
            .open_read_file(&entries[0])
            .expect("open pinned snapshot")
            .read_to_string(&mut contents)
            .expect("read pinned snapshot");
        assert_eq!(contents, "first");
        assert_eq!(fs::read_dir(&outside).expect("read outside").count(), 0);
    }

    #[test]
    fn native_owner_read_snapshot_rejects_replacement_symlink_and_unsafe_mode() {
        let sandbox = TestDirectory::new("read_guards");
        let trusted = sandbox.child("trusted");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        let mut original = owner
            .create_new_file(Path::new("item.txt"))
            .expect("create original");
        original.write_all(b"original").expect("write original");
        drop(original);
        let snapshot = owner
            .snapshot_files_recursive(Path::new("item.txt"), false)
            .expect("snapshot file")
            .pop()
            .expect("single file snapshot");

        fs::rename(trusted.join("item.txt"), trusted.join("old.txt")).expect("move original");
        let mut replacement = owner
            .create_new_file(Path::new("item.txt"))
            .expect("create replacement");
        replacement
            .write_all(b"original")
            .expect("write replacement");
        drop(replacement);
        assert_eq!(
            owner.open_read_file(&snapshot).unwrap_err(),
            NativeFileTransferRootError::ReadSnapshotChanged
        );

        symlink(outside.join("outside.txt"), trusted.join("link.txt")).expect("create symlink");
        assert!(owner.list_directory(Path::new(""), true).is_err());
        let broad = trusted.join("broad.txt");
        fs::write(&broad, b"broad").expect("create broad file");
        fs::set_permissions(&broad, fs::Permissions::from_mode(0o644)).expect("set broad mode");
        assert!(owner
            .snapshot_files_recursive(Path::new("broad.txt"), false)
            .is_err());
        assert!(owner
            .snapshot_files_recursive(Path::new("pending.farpane-part"), false)
            .is_err());
    }

    #[test]
    fn native_owner_read_listing_enforces_entry_limit_before_partial_success() {
        let sandbox = TestDirectory::new("read_limit");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        for index in 0..=NATIVE_HOST_READ_MAX_ENTRIES {
            drop(
                owner
                    .create_new_file(Path::new(&format!("entry-{index:04}.txt")))
                    .expect("create bounded listing fixture"),
            );
        }

        assert_eq!(
            owner.list_directory(Path::new(""), true).unwrap_err(),
            NativeFileTransferRootError::ReadLimitExceeded
        );
    }
