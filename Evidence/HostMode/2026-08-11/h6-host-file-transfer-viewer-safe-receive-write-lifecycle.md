# H6.3f2b2i Viewer safe receive write lifecycle

## Outcome

Exact Viewer receive reservations now accept bounded descriptor-owned payload
writes with checked manifest-size accounting. Final publication and network
dispatch remain disabled.

## Key evidence

- Reservation admission is bound to a complete validated download request and
  exact manifest file index; declared size must fit local signed `off_t`.
- Each payload is nonempty and at most 128 KiB. `pwrite` starts at the owner's
  tracked offset, retries `EINTR`, completes partial writes, and advances only
  by bytes actually persisted.
- Checked `UInt64` accounting rejects any block that would exceed the manifest
  declaration.
- Before and after every write, `fstatat(AT_SYMLINK_NOFOLLOW)` and `fstat`
  require the staging name and descriptor to retain the original device/inode,
  current-euid `0600` single-link regular-file shape and exact tracked size.
- Invalid bounds, metadata/name drift or partial/system failure terminate the
  active reservation. Cleanup unlinks only a still-matching partial; a replaced
  name remains untouched.
- Real-filesystem tests cover exact multi-block concatenation, declared-size
  overflow, empty/oversize chunks, replacement drift, partial teardown and
  unrepresentable declared sizes.

## Verification

- Focused `ViewerFileTransferDestinationOwnerTests`: 8/8 passed.
- Full Swift suite: 948 executed, 0 failures, 4 environment-gated skips.
- Focused current/predecessor audits: 2/2 passed; full ScriptTests: 160/160
  passed.
- Fresh arm64 Swift Release build completed successfully.
- Rust/Core build was not repeated because this step changes no Rust, C ABI,
  shim or built-core symbol.
- Product App smoke is not applicable because no product route reaches this
  internal primitive.
- Two-Mac transfer remains unverified and does not block this development-only
  milestone.

## Next step

`host-file-transfer-viewer-safe-receive-commit-lifecycle`: require exact final
size, apply declared mtime, fsync and publish with descriptor-relative
no-replace rename, still without network dispatch or product UI.
