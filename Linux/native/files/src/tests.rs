use super::*;
use std::{
    fs,
    os::unix::{
        ffi::OsStrExt,
        fs::{symlink, PermissionsExt},
        io::AsRawFd,
    },
    sync::atomic::{AtomicU64, Ordering},
};
static SERIAL: AtomicU64 = AtomicU64::new(1);
struct Sandbox(std::path::PathBuf);
impl Sandbox {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "farpane-files-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }
    fn root(&self) -> Root {
        Root::open(&self.0).unwrap()
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn shared_folder_keeps_private_authority_and_selected_scope() {
    use std::task::Poll;
    let source = Sandbox::new();
    fs::create_dir(source.0.join("shared")).unwrap();
    fs::set_permissions(source.0.join("shared"), fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(source.0.join("shared/inside"), b"content").unwrap();
    fs::write(source.0.join("not-selected"), b"secret").unwrap();
    symlink("../not-selected", source.0.join("shared/escape")).unwrap();
    let root = Arc::new(source.root());
    let mut plan = outgoing::Plan::shared_folder(root.clone(), "shared").unwrap();
    let batch = loop {
        if let Poll::Ready(Some(batch)) = plan.poll_batch().unwrap() {
            break batch;
        }
    };
    assert!(!batch.more);
    assert_eq!(batch.skipped, 1);
    assert_eq!(batch.entries.len(), 2);
    assert_eq!(batch.entries[0].name, "");
    assert_eq!(batch.entries[1].name, "inside");
    assert_eq!(
        plan.open(&batch.entries[1]).unwrap().read_block().unwrap(),
        b"content"
    );
    assert!(outgoing::Plan::shared_folder(root.clone(), "../shared").is_err());
    let mut reader = plan.open(&batch.entries[1]).unwrap();
    let mut pending = outgoing::Plan::shared_folder(root, "shared").unwrap();
    fs::set_permissions(&source.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(reader.read_block().is_err());
    assert!(pending.poll_batch().is_err());
    assert!(plan.open(&batch.entries[1]).is_err());
}
#[test]
fn outgoing_tree_streams_bounded_manifests_and_explicit_empty_root() {
    use std::task::Poll;
    let source = Sandbox::new();
    fs::create_dir(source.0.join("nested")).unwrap();
    fs::create_dir(source.0.join("nested/empty")).unwrap();
    for index in 0..1000 {
        fs::write(
            source.0.join(format!("nested/file-{index:04}")),
            format!("file-{index}"),
        )
        .unwrap();
    }
    fs::write(source.0.join(".hidden"), b"hidden").unwrap();
    symlink("/etc/passwd", source.0.join("outside")).unwrap();
    let mut plan = outgoing::Plan::folder(&source.0).unwrap();
    let mut names = std::collections::HashSet::new();
    let mut batches = 0;
    let mut saw_final = false;
    loop {
        match plan.poll_batch().unwrap() {
            Poll::Pending => {}
            Poll::Ready(None) => break,
            Poll::Ready(Some(batch)) => {
                assert!(!saw_final);
                assert!(batch.entries.len() <= PAGE_ENTRIES);
                assert!(
                    batch
                        .entries
                        .iter()
                        .map(|e| e.name.len() + 64)
                        .sum::<usize>()
                        <= PAGE_BYTES
                );
                if batches == 0 {
                    assert!(batch.entries[0].name.is_empty() && batch.entries[0].directory);
                }
                for entry in batch.entries {
                    assert!(names.insert(entry.name.clone()));
                    if !entry.directory {
                        let mut reader = plan.open(&entry).unwrap();
                        let data = reader.read_block().unwrap();
                        assert_eq!(data, fs::read(source.0.join(&entry.name)).unwrap());
                        assert!(reader.read_block().unwrap().is_empty());
                    }
                }
                if !batch.more {
                    saw_final = true;
                    assert_eq!(batch.skipped, 1);
                }
                batches += 1;
            }
        }
    }
    assert!(saw_final && batches > 1);
    assert_eq!(names.len(), 1004);
    let empty = Sandbox::new();
    let mut plan = outgoing::Plan::folder(&empty.0).unwrap();
    let Poll::Ready(Some(batch)) = plan.poll_batch().unwrap() else {
        panic!("Empty root must still be transferred")
    };
    assert_eq!(batch.entries.len(), 1);
    assert!(!batch.more);
}

#[test]
fn selected_multiple_files_reject_collisions_and_changed_sources() {
    use std::task::Poll;
    let source = Sandbox::new();
    fs::write(source.0.join("a"), b"one").unwrap();
    fs::create_dir(source.0.join("sub")).unwrap();
    fs::write(source.0.join("sub/a"), b"two").unwrap();
    assert!(outgoing::Plan::files(&[source.0.join("a"), source.0.join("sub/a")]).is_err());
    assert!(outgoing::Plan::files(&vec![source.0.join("a"); 129]).is_err());
    let mut plan = outgoing::Plan::files(&[source.0.join("a")]).unwrap();
    let Poll::Ready(Some(batch)) = plan.poll_batch().unwrap() else {
        panic!("Missing selection")
    };
    fs::write(source.0.join("a"), b"changed size").unwrap();
    assert!(plan.open(&batch.entries[0]).is_err());
}

#[test]
fn remote_paths_cannot_escape_or_address_internal_staging() {
    for path in [
        "",
        "/etc/passwd",
        "../sibling",
        "ok/../sibling",
        "a//b",
        "a/",
        "C:/x",
        "x\\y",
        ".farpane-part-hidden",
        "x\0y",
    ] {
        assert!(validate_relative(path, false).is_err(), "{path:?}");
    }
    assert!(validate_relative("书房/照片.png", false).is_ok());
    assert!(validate_relative("", true).is_ok());
}
#[test]
fn symlinks_hardlinks_and_special_files_are_never_followed() {
    let inside = Sandbox::new();
    let outside = Sandbox::new();
    let root = inside.root();
    fs::write(outside.0.join("secret"), b"untouched").unwrap();
    symlink(outside.0.join("secret"), inside.0.join("link")).unwrap();
    symlink(&outside.0, inside.0.join("dir")).unwrap();
    fs::hard_link(outside.0.join("secret"), inside.0.join("hard")).unwrap();
    let fifo = CString::new(inside.0.join("fifo").as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    for name in ["link", "hard", "fifo", "dir/secret"] {
        assert!(root.read(name).is_err(), "{name}");
    }
    assert!(root.receive("link", 1, true).is_err());
    assert!(root.receive("dir/new", 1, false).is_err());
    assert_eq!(fs::read(outside.0.join("secret")).unwrap(), b"untouched");
    let mut list = root.list("", true).unwrap();
    assert!(list.page().unwrap().0.is_empty());
    assert_eq!(list.skipped, 4);
}
#[test]
fn cancelled_or_short_receive_preserves_existing_destination() {
    let sandbox = Sandbox::new();
    let root = sandbox.root();
    fs::write(sandbox.0.join("existing"), b"old").unwrap();
    {
        let mut writer = root.receive("existing", 6, true).unwrap();
        writer.write_block(b"new").unwrap();
    }
    assert_eq!(fs::read(sandbox.0.join("existing")).unwrap(), b"old");
    let mut writer = root.receive("existing", 6, true).unwrap();
    writer.write_block(b"new").unwrap();
    assert!(writer.finish().is_err());
    assert_eq!(fs::read(sandbox.0.join("existing")).unwrap(), b"old");
    assert_eq!(fs::read_dir(&sandbox.0).unwrap().count(), 1);
}
#[test]
fn complete_transfer_is_atomic_and_noreplace_checks_again_at_commit() {
    let sandbox = Sandbox::new();
    let root = sandbox.root();
    let mut writer = root.receive("sub/中文.txt", 3, false).unwrap();
    writer.write_block(b"new").unwrap();
    assert!(!sandbox.0.join("sub/中文.txt").exists());
    writer.finish().unwrap();
    assert_eq!(fs::read(sandbox.0.join("sub/中文.txt")).unwrap(), b"new");
    assert_eq!(
        fs::metadata(sandbox.0.join("sub/中文.txt")).unwrap().mode() & 0o777,
        0o600
    );
    let mut writer = root.receive("raced", 3, false).unwrap();
    writer.write_block(b"new").unwrap();
    fs::write(sandbox.0.join("raced"), b"another owner").unwrap();
    assert!(writer.finish().is_err());
    assert_eq!(fs::read(sandbox.0.join("raced")).unwrap(), b"another owner");
    let mut writer = root.receive("sub/中文.txt", 3, true).unwrap();
    writer.write_block(b"end").unwrap();
    writer.finish().unwrap();
    assert_eq!(fs::read(sandbox.0.join("sub/中文.txt")).unwrap(), b"end");
}
#[test]
fn block_bounds_and_source_changes_are_enforced() {
    let sandbox = Sandbox::new();
    let root = sandbox.root();
    let mut writer = root.receive("small", 2, false).unwrap();
    assert!(writer.write_block(b"large").is_err());
    assert_eq!(writer.written(), 0);
    assert!(writer.write_block(&vec![0; BLOCK_BYTES + 1]).is_err());
    fs::write(sandbox.0.join("source"), vec![7u8; BLOCK_BYTES + 1]).unwrap();
    let mut reader = root.read("source").unwrap();
    assert_eq!(reader.read_block().unwrap().len(), BLOCK_BYTES);
    fs::write(sandbox.0.join("source"), b"changed").unwrap();
    assert!(reader.read_block().is_err());
}
#[test]
fn enumeration_is_incremental_bounded_and_hides_partial_files() {
    let sandbox = Sandbox::new();
    let root = sandbox.root();
    for n in 0..1000 {
        fs::write(sandbox.0.join(format!("entry-{n:04}")), []).unwrap();
    }
    let _pending = root.receive("not-committed", 1, false).unwrap();
    let mut directory = root.list("", true).unwrap();
    let mut names = std::collections::HashSet::new();
    let mut pages = 0;
    loop {
        let (page, more) = directory.page().unwrap();
        assert!(page.len() <= PAGE_ENTRIES);
        assert!(page.iter().map(|e| e.name.len() + 64).sum::<usize>() <= PAGE_BYTES);
        for entry in page {
            assert!(!entry.name.starts_with(STAGING));
            assert!(names.insert(entry.name));
        }
        pages += 1;
        if !more {
            break;
        }
    }
    assert_eq!(names.len(), 1000);
    assert!(pages > 1);
}
#[test]
fn root_permission_checks_do_not_chmod_or_follow_ancestors() {
    let sandbox = Sandbox::new();
    let mode = fs::metadata(&sandbox.0).unwrap().mode();
    fs::set_permissions(&sandbox.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(Root::open(&sandbox.0).is_err());
    assert_eq!(fs::metadata(&sandbox.0).unwrap().mode() & 0o777, 0o755);
    fs::set_permissions(&sandbox.0, fs::Permissions::from_mode(mode)).unwrap();
    let other = Sandbox::new();
    symlink(&sandbox.0, other.0.join("alias")).unwrap();
    assert!(Root::open(&other.0.join("alias")).is_err());
    assert!(
        unsafe { libc::fcntl(sandbox.root().directory.as_raw_fd(), libc::F_GETFD) }
            & libc::FD_CLOEXEC
            != 0
    );
}

#[test]
fn replaced_staging_name_is_never_committed_or_unlinked() {
    let sandbox = Sandbox::new();
    let root = sandbox.root();
    let mut writer = root.receive("final", 3, false).unwrap();
    writer.write_block(b"new").unwrap();
    let path = sandbox.0.join(writer.temporary.to_str().unwrap());
    fs::remove_file(&path).unwrap();
    fs::write(&path, b"unrelated").unwrap();
    assert!(writer.finish().is_err());
    assert!(!sandbox.0.join("final").exists());
    assert_eq!(fs::read(path).unwrap(), b"unrelated");
}
#[test]
fn provision_creates_private_leaf_and_supports_ordinary_owned_subdirectories() {
    let sandbox = Sandbox::new();
    let path = sandbox.0.join("FarPane");
    let root = Root::provision(&path).unwrap();
    assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o700);
    fs::create_dir(path.join("existing")).unwrap();
    fs::set_permissions(path.join("existing"), fs::Permissions::from_mode(0o755)).unwrap();
    let writer = root.receive("existing/empty", 0, false).unwrap();
    writer.finish().unwrap();
    assert_eq!(root.read("existing/empty").unwrap().size(), 0);
    assert_eq!(
        root.list("existing", true).unwrap().page().unwrap().0.len(),
        1
    );
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(Root::provision(&path).is_err());
    assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o755);
}

#[test]
fn explicit_upload_directory_is_read_only_and_need_not_be_private() {
    let sandbox = Sandbox::new();
    fs::set_permissions(&sandbox.0, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(sandbox.0.join("a"), b"chosen").unwrap();
    fs::hard_link(sandbox.0.join("a"), sandbox.0.join("b")).unwrap();
    assert!(Root::open(&sandbox.0).is_err());
    let source = Source::selected(&sandbox.0).unwrap();
    assert_eq!(source.read("a").unwrap().read_block().unwrap(), b"chosen");
    assert_eq!(
        Reader::selected(&sandbox.0.join("b"))
            .unwrap()
            .read_block()
            .unwrap(),
        b"chosen"
    );
    assert_eq!(source.list("", true).unwrap().page().unwrap().0.len(), 2);
    assert!(source.root.receive("not-allowed", 1, false).is_err());
    assert!(source.root.create_directories("not-allowed").is_err());
}

#[test]
fn streaming_walk_visits_nested_and_empty_directories_without_following_links() {
    let sandbox = Sandbox::new();
    fs::create_dir_all(sandbox.0.join("folder/empty")).unwrap();
    for n in 0..1000 {
        fs::write(sandbox.0.join(format!("folder/f-{n}")), b"x").unwrap();
    }
    symlink("/", sandbox.0.join("outside")).unwrap();
    let source = std::sync::Arc::new(Source::selected(&sandbox.0).unwrap());
    let mut walk = source.walk(true).unwrap();
    let mut count = 0;
    let mut empty = false;
    loop {
        match walk.step().unwrap() {
            batch::Step::Entry(entry) => {
                count += 1;
                empty |= entry.name == "folder/empty" && entry.directory;
            }
            batch::Step::Yield => {}
            batch::Step::Done => break,
        }
    }
    assert_eq!(count, 1002);
    assert!(empty);
    assert_eq!(walk.skipped, 1);
}
#[test]
fn receive_batch_validates_manifest_order_and_preserves_committed_prefix_on_cancel() {
    let sandbox = Sandbox::new();
    let root = std::sync::Arc::new(sandbox.root());
    let entry = |name: &str, size: u64| Entry {
        name: name.into(),
        size,
        modified: 0,
        directory: false,
    };
    assert!(batch::Incoming::new(root.clone(), vec![entry("a", 1), entry("a", 2)]).is_err());
    assert!(batch::Incoming::new(root.clone(), vec![entry("a", 1), entry("a/b", 2)]).is_err());
    let mut receive = batch::Incoming::new(root, vec![entry("a", 3), entry("b", 4)]).unwrap();
    assert!(receive.write(0, b"x").is_err());
    assert!(receive.begin(1, false).is_err());
    receive.begin(0, false).unwrap();
    receive.write(0, b"one").unwrap();
    receive.commit(0).unwrap();
    assert_eq!(receive.progress(), (3, 7));
    assert!(!receive.complete());
    receive.begin(1, false).unwrap();
    receive.write(1, b"xx").unwrap();
    drop(receive);
    assert_eq!(fs::read(sandbox.0.join("a")).unwrap(), b"one");
    assert!(!sandbox.0.join("b").exists());
    assert_eq!(fs::read_dir(&sandbox.0).unwrap().count(), 1);
}

#[test]
fn changed_root_or_directory_permissions_stop_already_open_handles() {
    let sandbox = Sandbox::new();
    fs::write(sandbox.0.join("source"), b"content").unwrap();
    fs::create_dir(sandbox.0.join("sub")).unwrap();
    let root = sandbox.root();
    let mut reader = root.read("source").unwrap();
    let mut writer = root.receive("new", 3, false).unwrap();
    let mut listing = root.list("", true).unwrap();
    fs::set_permissions(&sandbox.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(reader.read_block().is_err());
    assert!(writer.write_block(b"new").is_err());
    assert!(listing.page().is_err());
    assert!(writer.finish().is_err());
    assert!(!sandbox.0.join("new").exists());
    fs::set_permissions(&sandbox.0, fs::Permissions::from_mode(0o700)).unwrap();
    let mut listing = root.list("sub", true).unwrap();
    let mut writer = root.receive("sub/new", 3, false).unwrap();
    fs::set_permissions(sandbox.0.join("sub"), fs::Permissions::from_mode(0o777)).unwrap();
    assert!(listing.page().is_err());
    assert!(writer.write_block(b"new").is_err());
    assert!(writer.finish().is_err());
    assert_eq!(fs::read_dir(sandbox.0.join("sub")).unwrap().count(), 0);
}

fn entry(name: &str, size: u64) -> Entry {
    Entry {
        name: name.into(),
        size,
        directory: false,
        modified: 0,
    }
}
#[test]
fn owner_confirmation_is_one_use_and_never_creates_files_in_advance() {
    use owner::Owner;
    let sandbox = Sandbox::new();
    let mut owner = Owner::new(std::sync::Arc::new(sandbox.root()), 77).unwrap();
    let (denied, _) = owner.offer_receive(vec![entry("rejected/sub", 3)]).unwrap();
    assert!(owner.begin_receive(denied, 0).is_err());
    assert!(!sandbox.0.join("rejected").exists());
    assert!(owner.confirm_receive(denied, true, false).is_err());
    let (key, total) = owner
        .offer_receive(vec![entry("destination/sub", 3)])
        .unwrap();
    assert_eq!(total, 3);
    assert!(!sandbox.0.join("destination").exists());
    owner.confirm_receive(key, true, false).unwrap();
    assert!(owner.confirm_receive(key, true, true).is_err());
    owner.begin_receive(key, 0).unwrap();
    let progress = owner.write(key, 0, b"new").unwrap();
    assert_eq!(
        (progress.done, progress.total, progress.complete),
        (3, 3, false)
    );
    assert!(!sandbox.0.join("destination/sub").exists());
    assert!(owner.commit(key, 0).unwrap().complete);
    assert_eq!(owner.active_jobs(), 0);
    assert!(owner.commit(key, 0).is_err());
    assert_eq!(fs::read(sandbox.0.join("destination/sub")).unwrap(), b"new");
    let (key, _) = owner
        .offer_receive(vec![entry("destination/sub", 3)])
        .unwrap();
    owner.confirm_receive(key, true, false).unwrap();
    assert!(owner.begin_receive(key, 0).is_err());
    assert_eq!(fs::read(sandbox.0.join("destination/sub")).unwrap(), b"new");
}
#[test]
fn owner_cancel_revoke_and_new_generation_cannot_reuse_old_decisions() {
    use owner::Owner;
    let sandbox = Sandbox::new();
    fs::write(sandbox.0.join("old"), b"original").unwrap();
    let root = std::sync::Arc::new(sandbox.root());
    let mut owner = Owner::new(root.clone(), 80).unwrap();
    let (key, _) = owner.offer_receive(vec![entry("old", 9)]).unwrap();
    owner.confirm_receive(key, true, true).unwrap();
    owner.begin_receive(key, 0).unwrap();
    owner.write(key, 0, b"partial").unwrap();
    owner.cancel(key).unwrap();
    assert_eq!(fs::read(sandbox.0.join("old")).unwrap(), b"original");
    assert_eq!(fs::read_dir(&sandbox.0).unwrap().count(), 1);
    let (key, _) = owner.offer_receive(vec![entry("old", 9)]).unwrap();
    owner.confirm_receive(key, true, true).unwrap();
    owner.begin_receive(key, 0).unwrap();
    owner.write(key, 0, b"partial").unwrap();
    owner.revoke();
    assert_eq!(owner.active_jobs(), 0);
    assert!(owner.write(key, 0, b"xx").is_err());
    assert!(owner.offer_receive(vec![entry("new", 1)]).is_err());
    assert!(owner.list("", true, None).is_err());
    assert_eq!(fs::read_dir(&sandbox.0).unwrap().count(), 1);
    let mut next = Owner::new(root, 81).unwrap();
    assert!(next.confirm_receive(key, true, true).is_err());
    let (new, _) = next.offer_receive(vec![entry("old", 1)]).unwrap();
    assert_ne!(key, new);
    next.confirm_receive(new, false, false).unwrap();
    assert_eq!(next.active_jobs(), 0);
}
#[test]
fn owner_directory_continuations_are_bounded_and_bound_to_exact_request() {
    use owner::Owner;
    let sandbox = Sandbox::new();
    for i in 0..1000 {
        fs::write(sandbox.0.join(format!("file-{i:04}")), []).unwrap();
    }
    fs::create_dir(sandbox.0.join("sub")).unwrap();
    let mut owner = Owner::new(std::sync::Arc::new(sandbox.root()), 45).unwrap();
    let page = owner.list("", false, None).unwrap();
    assert!(page.entries.len() <= PAGE_ENTRIES);
    let first = page.next.unwrap();
    assert!(owner.list("sub", false, Some(first)).is_err());
    assert!(owner.list("", true, Some(first)).is_err());
    let mut wrong = first;
    wrong.key.generation += 1;
    assert!(owner.list("", false, Some(wrong)).is_err());
    let page2 = owner.list("", false, Some(first)).unwrap();
    assert!(owner.list("", false, Some(first)).is_err());
    let old = page2.next.unwrap();
    let reset = owner.list("", false, None).unwrap();
    assert_ne!(reset.next.unwrap().key, old.key);
    assert!(owner.list("", false, Some(old)).is_err());
    let mut names = std::collections::HashSet::new();
    let mut page = reset;
    loop {
        assert!(page.entries.len() <= PAGE_ENTRIES);
        for e in page.entries {
            assert!(names.insert(e.name));
        }
        let Some(cursor) = page.next else {
            break;
        };
        page = owner.list("", false, Some(cursor)).unwrap();
    }
    assert_eq!(names.len(), 1001);
}
#[test]
fn owner_limits_pending_work_and_expires_unanswered_or_stalled_jobs() {
    use owner::{Owner, MAX_JOBS};
    use std::time::{Duration, Instant};
    let sandbox = Sandbox::new();
    let mut owner = Owner::new(std::sync::Arc::new(sandbox.root()), 22).unwrap();
    let mut keys = Vec::new();
    for n in 0..MAX_JOBS {
        keys.push(
            owner
                .offer_receive(vec![entry(&format!("file-{n}"), 5)])
                .unwrap()
                .0,
        );
    }
    assert!(owner.offer_receive(vec![entry("overflow", 1)]).is_err());
    owner.confirm_receive(keys[0], true, false).unwrap();
    owner.begin_receive(keys[0], 0).unwrap();
    owner.write(keys[0], 0, b"part").unwrap();
    let now = Instant::now();
    assert_eq!(
        owner.expire(now + Duration::from_secs(61)).len(),
        MAX_JOBS - 1
    );
    assert_eq!(owner.active_jobs(), 1);
    assert_eq!(owner.expire(now + Duration::from_secs(121)), [keys[0]]);
    assert_eq!(owner.active_jobs(), 0);
    assert_eq!(fs::read_dir(&sandbox.0).unwrap().count(), 0);
}
#[test]
fn owner_read_requires_consent_and_never_buffers_a_whole_large_file() {
    use owner::{Owner, Read};
    let sandbox = Sandbox::new();
    let content = (0..BLOCK_BYTES * 3 + 17)
        .map(|i| (i % 251) as u8)
        .collect::<Vec<_>>();
    fs::write(sandbox.0.join("source"), &content).unwrap();
    let mut owner = Owner::new(std::sync::Arc::new(sandbox.root()), 5).unwrap();
    let (key, _) = owner.offer_send("source").unwrap();
    assert!(owner.read(key).is_err());
    let (key, size) = owner.offer_send("source").unwrap();
    assert_eq!(size, content.len() as u64);
    owner.confirm_send(key, true).unwrap();
    let mut result = Vec::new();
    loop {
        match owner.read(key).unwrap() {
            Read::Block(block) => {
                assert!(block.len() <= BLOCK_BYTES);
                result.extend(block);
            }
            Read::End => break,
        }
    }
    assert_eq!(result, content);
    assert_eq!(owner.active_jobs(), 0);
    assert!(owner.read(key).is_err());
    let (key, _) = owner.offer_send("source").unwrap();
    owner.confirm_send(key, true).unwrap();
    fs::write(sandbox.0.join("source"), b"changed").unwrap();
    assert!(owner.read(key).is_err());
    assert_eq!(owner.active_jobs(), 0);
}
