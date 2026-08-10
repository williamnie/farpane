# H6.3f2b2j Viewer safe receive commit lifecycle

## Outcome

Complete Viewer receive reservations can now durably publish one new file with
declared mtime and atomic no-replace semantics. Network dispatch and product
enablement remain disabled.

## Key evidence

- Commit accepts only the exact active opaque handle after tracked bytes equal
  the manifest-declared size and both staging name and open descriptor still
  match the original safe inode and metadata.
- The declared nonnegative Unix-seconds mtime is applied with `futimens`; the
  file is fsynced and revalidated before publication.
- Publication uses `renameatx_np(RENAME_EXCL)` between names under the same
  pinned parent descriptor, so a racing final entry is never replaced.
- The parent directory is fsynced after rename. A failure at that irreversible
  point returns `durabilityUnconfirmed`, preserves the published final and
  prevents unsafe retry under the consumed handle.
- Every pre-rename failure terminates the reservation and unlinks only a
  still-matching staging inode.
- Real-filesystem tests cover exact content, mtime, mode and cleanup after
  success, stale-handle rejection, incomplete-file cleanup and final-name race
  preservation.

## Verification

- Focused `ViewerFileTransferDestinationOwnerTests`: 10/10 passed.
- Full Swift suite: 950 executed, 0 failures, 4 environment-gated skips.
- Focused current/predecessor audits: 3/3 passed; full ScriptTests: 161/161
  passed.
- Fresh arm64 Swift Release build completed successfully.
- Rust/Core build was not repeated because this step changes no Rust, C ABI,
  shim or built-core symbol.
- Product App smoke is not applicable because no product route reaches this
  internal primitive.
- Two-Mac transfer remains unverified and does not block this development-only
  milestone.

## Next step

`host-file-transfer-viewer-download-dispatch-receive-adapter-lifecycle`: bind
the already-frozen manifest/download registration and progress lifecycle to
bounded receive reservations and wire dispatch, while keeping product UI off.
