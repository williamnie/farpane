
    use super::*;
    use std::{
        fs,
        io::{Read, Seek, SeekFrom, Write},
        os::unix::fs::{symlink, MetadataExt, PermissionsExt},
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    struct TestDirectory {
        path: PathBuf,
    }

    impl TestDirectory {
        fn new(label: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "farpane_native_file_root_{}_{}_{}",
                label,
                std::process::id(),
                nonce
            ));
            fs::create_dir(&path).expect("create test directory");
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                .expect("secure test directory");
            Self {
                path: fs::canonicalize(path).expect("canonical test directory"),
            }
        }

        fn child(&self, name: &str) -> PathBuf {
            self.path.join(name)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn create_private_directory(path: &Path) {
        fs::create_dir(path).expect("create private directory");
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .expect("secure private directory");
    }

    #[test]
    fn receive_root_rejects_symlink_and_unsafe_mode() {
        let sandbox = TestDirectory::new("root_admission");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let alias = sandbox.child("alias");
        symlink(&trusted, &alias).expect("create root symlink");

        assert_eq!(
            NativeFileTransferRoot::open_existing(&alias).unwrap_err(),
            NativeFileTransferRootError::OpenRoot
        );

        fs::set_permissions(&trusted, fs::Permissions::from_mode(0o755))
            .expect("make root too broad");
        assert_eq!(
            NativeFileTransferRoot::open_existing(&trusted).unwrap_err(),
            NativeFileTransferRootError::UnsafeRoot
        );
    }

    #[test]
    fn create_is_descriptor_relative_private_and_nested() {
        let sandbox = TestDirectory::new("create");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        let mut file = root
            .create_new_file(Path::new("nested/example.txt.download"))
            .expect("create nested file");
        file.write_all(b"bounded").expect("write fixture");
        file.sync_all().expect("sync fixture");

        assert_eq!(
            fs::read(trusted.join("nested/example.txt.download")).expect("read fixture"),
            b"bounded"
        );
        assert_eq!(
            fs::metadata(trusted.join("nested"))
                .expect("nested metadata")
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(trusted.join("nested/example.txt.download"))
                .expect("file metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn create_rejects_escape_absolute_and_symlink_parent() {
        let sandbox = TestDirectory::new("escape");
        let trusted = sandbox.child("trusted");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        symlink(&outside, trusted.join("link")).expect("create nested symlink");
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        assert_eq!(
            root.create_new_file(Path::new("../outside/escape.txt"))
                .unwrap_err(),
            NativeFileTransferRootError::InvalidRelativePath
        );
        assert_eq!(
            root.create_new_file(outside.join("absolute.txt").as_path())
                .unwrap_err(),
            NativeFileTransferRootError::InvalidRelativePath
        );
        assert!(root.create_new_file(Path::new("link/escape.txt")).is_err());
        assert!(!outside.join("escape.txt").exists());
    }

    #[test]
    fn resume_requires_owned_private_single_link_regular_file() {
        let sandbox = TestDirectory::new("resume");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        let mut created = root
            .create_new_file(Path::new("resume.download"))
            .expect("create resume fixture");
        created.write_all(b"prefix").expect("write prefix");
        drop(created);

        let mut resumed = root
            .open_existing_file_for_resume(Path::new("resume.download"))
            .expect("open resume fixture");
        resumed.seek(SeekFrom::End(0)).expect("seek end");
        resumed.write_all(b"-suffix").expect("write suffix");
        drop(resumed);
        let mut contents = String::new();
        File::open(trusted.join("resume.download"))
            .expect("open result")
            .read_to_string(&mut contents)
            .expect("read result");
        assert_eq!(contents, "prefix-suffix");

        fs::hard_link(
            trusted.join("resume.download"),
            trusted.join("linked.download"),
        )
        .expect("create hard link");
        assert_eq!(
            root.open_existing_file_for_resume(Path::new("linked.download"))
                .unwrap_err(),
            NativeFileTransferRootError::UnsafeFile
        );

        let broad = trusted.join("broad.download");
        fs::write(&broad, b"unsafe").expect("create broad file");
        fs::set_permissions(&broad, fs::Permissions::from_mode(0o644)).expect("set broad mode");
        assert_eq!(
            root.open_existing_file_for_resume(Path::new("broad.download"))
                .unwrap_err(),
            NativeFileTransferRootError::UnsafeFile
        );
    }

    #[test]
    fn write_path_reservations_are_atomic_and_release_on_drop() {
        let sandbox = TestDirectory::new("write_reservations");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = Arc::new(
            NativeHostFileServiceOwner::open_existing(&trusted).expect("open file-service owner"),
        );
        let paths = vec![
            PathBuf::from("first.download"),
            PathBuf::from("nested/second.download"),
        ];

        let reservation = owner
            .reserve_write_paths(&paths)
            .expect("reserve distinct write paths");
        assert_eq!(
            owner
                .reserve_write_paths(&[PathBuf::from("nested/second.download")])
                .unwrap_err(),
            NativeFileTransferRootError::WritePathBusy
        );
        assert_eq!(
            owner
                .reserve_write_paths(&[
                    PathBuf::from("third.download"),
                    PathBuf::from("nested/second.download"),
                ])
                .unwrap_err(),
            NativeFileTransferRootError::WritePathBusy
        );
        let independent = owner
            .reserve_write_paths(&[PathBuf::from("third.download")])
            .expect("failed atomic attempt must not reserve a prefix");
        drop(independent);
        drop(reservation);
        owner
            .reserve_write_paths(&paths)
            .expect("released paths can be reserved again");
    }

    #[test]
    fn open_root_descriptor_survives_path_replacement() {
        let sandbox = TestDirectory::new("replacement");
        let trusted = sandbox.child("trusted");
        let moved = sandbox.child("moved");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        fs::rename(&trusted, &moved).expect("move admitted root");
        symlink(&outside, &trusted).expect("replace original path with symlink");
        let mut file = root
            .create_new_file(Path::new("pinned.download"))
            .expect("create through pinned descriptor");
        file.write_all(b"pinned").expect("write pinned fixture");
        drop(file);

        assert_eq!(
            fs::read(moved.join("pinned.download")).expect("read pinned fixture"),
            b"pinned"
        );
        assert!(!outside.join("pinned.download").exists());
    }

    #[test]
    fn mutations_create_and_remove_only_private_entries() {
        let sandbox = TestDirectory::new("mutations");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        root.create_directory(Path::new("folder"))
            .expect("create directory");
        assert_eq!(
            fs::metadata(trusted.join("folder"))
                .expect("directory metadata")
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        drop(
            root.create_new_file(Path::new("folder/item.download"))
                .expect("create file"),
        );
        root.remove_file(Path::new("folder/item.download"))
            .expect("remove file");
        root.remove_empty_directory(Path::new("folder"))
            .expect("remove empty directory");
        assert!(!trusted.join("folder").exists());
    }

    #[test]
    fn remove_rejects_symlink_hardlink_type_confusion_and_nonempty_directory() {
        let sandbox = TestDirectory::new("remove_guards");
        let trusted = sandbox.child("trusted");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let outside_file = outside.join("outside.txt");
        fs::write(&outside_file, b"outside").expect("create outside file");
        symlink(&outside_file, trusted.join("link.download")).expect("create file symlink");
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");

        assert!(root.remove_file(Path::new("link.download")).is_err());
        assert!(outside_file.exists());
        assert!(fs::symlink_metadata(trusted.join("link.download")).is_ok());

        drop(
            root.create_new_file(Path::new("original.download"))
                .expect("create original"),
        );
        fs::hard_link(
            trusted.join("original.download"),
            trusted.join("alias.download"),
        )
        .expect("create hard link");
        assert_eq!(
            root.remove_file(Path::new("original.download"))
                .unwrap_err(),
            NativeFileTransferRootError::UnsafeFile
        );
        assert!(trusted.join("original.download").exists());

        root.create_directory(Path::new("nonempty"))
            .expect("create nonempty directory");
        drop(
            root.create_new_file(Path::new("nonempty/child.download"))
                .expect("create child"),
        );
        assert_eq!(
            root.remove_empty_directory(Path::new("nonempty"))
                .unwrap_err(),
            NativeFileTransferRootError::RemoveDirectory
        );
        assert!(trusted.join("nonempty/child.download").exists());
        assert!(root.remove_file(Path::new("nonempty")).is_err());
    }

    #[test]
    fn rename_is_no_replace_and_preserves_source_inode_on_success() {
        let sandbox = TestDirectory::new("rename");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");
        let mut source = root
            .create_new_file(Path::new("source.download"))
            .expect("create source");
        source.write_all(b"source").expect("write source");
        drop(source);
        let source_inode = fs::metadata(trusted.join("source.download"))
            .expect("source metadata")
            .ino();
        drop(
            root.create_new_file(Path::new("existing.download"))
                .expect("create destination collision"),
        );

        assert_eq!(
            root.rename_entry(Path::new("source.download"), Path::new("existing.download"),)
                .unwrap_err(),
            NativeFileTransferRootError::RenameEntry
        );
        assert_eq!(
            fs::read(trusted.join("source.download")).expect("source retained"),
            b"source"
        );

        root.create_directory(Path::new("archive"))
            .expect("create archive");
        root.rename_entry(
            Path::new("source.download"),
            Path::new("archive/moved.download"),
        )
        .expect("rename without replacement");
        assert!(!trusted.join("source.download").exists());
        assert_eq!(
            fs::metadata(trusted.join("archive/moved.download"))
                .expect("moved metadata")
                .ino(),
            source_inode
        );
    }

    #[test]
    fn rename_rejects_symlink_broad_mode_and_hardlinked_source() {
        let sandbox = TestDirectory::new("rename_guards");
        let trusted = sandbox.child("trusted");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let outside_file = outside.join("outside.txt");
        fs::write(&outside_file, b"outside").expect("create outside file");
        symlink(&outside_file, trusted.join("link.download")).expect("create symlink");
        let broad = trusted.join("broad.download");
        fs::write(&broad, b"broad").expect("create broad file");
        fs::set_permissions(&broad, fs::Permissions::from_mode(0o644)).expect("set broad mode");
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");
        drop(
            root.create_new_file(Path::new("linked.download"))
                .expect("create linked source"),
        );
        fs::hard_link(
            trusted.join("linked.download"),
            trusted.join("linked-alias.download"),
        )
        .expect("create source hard link");

        assert!(root
            .rename_entry(Path::new("link.download"), Path::new("link-moved.download"))
            .is_err());
        assert!(root
            .rename_entry(
                Path::new("broad.download"),
                Path::new("broad-moved.download"),
            )
            .is_err());
        assert_eq!(
            root.rename_entry(
                Path::new("linked.download"),
                Path::new("linked-moved.download"),
            )
            .unwrap_err(),
            NativeFileTransferRootError::UnsafeFile
        );
        assert!(outside_file.exists());
        assert!(broad.exists());
        assert!(trusted.join("linked.download").exists());
    }

    #[test]
    fn mutations_remain_pinned_after_root_path_replacement() {
        let sandbox = TestDirectory::new("mutation_replacement");
        let trusted = sandbox.child("trusted");
        let moved = sandbox.child("moved");
        let outside = sandbox.child("outside");
        create_private_directory(&trusted);
        create_private_directory(&outside);
        let root = NativeFileTransferRoot::open_existing(&trusted).expect("open root");
        drop(
            root.create_new_file(Path::new("source.download"))
                .expect("create source"),
        );

        fs::rename(&trusted, &moved).expect("move admitted root");
        symlink(&outside, &trusted).expect("replace original path");
        root.create_directory(Path::new("folder"))
            .expect("create in pinned root");
        root.rename_entry(
            Path::new("source.download"),
            Path::new("folder/renamed.download"),
        )
        .expect("rename in pinned root");
        root.remove_file(Path::new("folder/renamed.download"))
            .expect("remove in pinned root");
        root.remove_empty_directory(Path::new("folder"))
            .expect("remove directory in pinned root");

        assert!(!moved.join("source.download").exists());
        assert!(!moved.join("folder").exists());
        assert_eq!(fs::read_dir(&outside).expect("read outside").count(), 0);
    }

    #[test]
    fn native_owner_is_the_single_safe_root_mutation_authority() {
        let sandbox = TestDirectory::new("owner_authority");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");

        owner
            .create_directory(Path::new("folder"))
            .expect("create directory");
        drop(
            owner
                .create_new_file(Path::new("folder/item.download"))
                .expect("create file"),
        );
        drop(
            owner
                .open_existing_file_for_resume(Path::new("folder/item.download"))
                .expect("resume file"),
        );
        owner
            .rename_entry(
                Path::new("folder/item.download"),
                Path::new("folder/renamed.download"),
            )
            .expect("rename file");
        owner
            .remove_file(Path::new("folder/renamed.download"))
            .expect("remove file");
        owner
            .remove_directory(Path::new("folder"), false)
            .expect("remove empty directory");
        assert!(!trusted.join("folder").exists());
    }

    #[test]
    fn native_owner_rejects_recursive_remove_without_touching_tree() {
        let sandbox = TestDirectory::new("owner_recursive_remove");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        owner
            .create_directory(Path::new("folder"))
            .expect("create directory");
        drop(
            owner
                .create_new_file(Path::new("folder/item.download"))
                .expect("create file"),
        );

        assert_eq!(
            owner
                .remove_directory(Path::new("folder"), true)
                .unwrap_err(),
            NativeFileTransferRootError::RecursiveRemovalUnsupported
        );
        assert!(trusted.join("folder/item.download").is_file());
    }

    #[test]
    fn immutable_owner_configuration_requires_exact_policy_root_pair() {
        let sandbox = TestDirectory::new("owner_configuration");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);

        assert!(
            NativeHostFileServiceOwner::from_immutable_configuration(false, None)
                .expect("disabled without root")
                .is_none()
        );
        assert_eq!(
            NativeHostFileServiceOwner::from_immutable_configuration(
                false,
                Some(trusted.as_path()),
            )
            .unwrap_err(),
            NativeFileTransferRootError::InvalidOwnerConfiguration
        );
        assert_eq!(
            NativeHostFileServiceOwner::from_immutable_configuration(true, None).unwrap_err(),
            NativeFileTransferRootError::InvalidOwnerConfiguration
        );
        assert!(NativeHostFileServiceOwner::from_immutable_configuration(
            true,
            Some(trusted.as_path()),
        )
        .expect("enabled with safe root")
        .is_some());
    }

    #[test]
    fn native_owner_lists_only_safe_visible_entries_and_hides_staging() {
        let sandbox = TestDirectory::new("read_list");
        let trusted = sandbox.child("trusted");
        create_private_directory(&trusted);
        let owner = NativeHostFileServiceOwner::open_existing(&trusted).expect("open owner");
        owner
            .create_directory(Path::new("nested"))
            .expect("create nested directory");
        let mut visible = owner
            .create_new_file(Path::new("visible.txt"))
            .expect("create visible file");
        visible.write_all(b"visible").expect("write visible file");
        drop(visible);
        drop(
            owner
                .create_new_file(Path::new(".hidden.txt"))
                .expect("create hidden file"),
        );
        drop(
            owner
                .create_new_file(Path::new("pending.txt.farpane-part"))
                .expect("create private staging file"),
        );

        let visible_entries = owner
            .list_directory(Path::new(""), false)
            .expect("list visible entries");
        assert_eq!(
            visible_entries
                .iter()
                .map(|entry| (entry.wire_name(), entry.kind()))
                .collect::<Vec<_>>(),
            vec![
                ("nested", NativeHostReadEntryKind::Directory),
                ("visible.txt", NativeHostReadEntryKind::File),
            ]
        );
        let all_entries = owner
            .list_directory(Path::new(""), true)
            .expect("list hidden entries");
        assert_eq!(
            all_entries
                .iter()
                .map(|entry| entry.wire_name())
                .collect::<Vec<_>>(),
            vec![".hidden.txt", "nested", "visible.txt"]
        );
    }
