# H6.3f2b2h Viewer safe staging reservation lifecycle

## Outcome

The Swift destination owner can reserve bounded, descriptor-relative private
staging files for validated manifest entries. No payload write, final commit,
wire request or product enablement is included.

## Key evidence

- Admission requires the exact destination lease, positive transfer ID,
  bounded file number, canonical manifest path and unique nonzero token; at most
  eight active transfer reservations are retained.
- Parent traversal starts from a duplicated pinned root descriptor and uses only
  `mkdirat/openat(O_DIRECTORY|O_NOFOLLOW)`. Existing or created parents must be
  current-euid, exact `0700` directories.
- The final name must be absent. The reserved `*.farpane-part` is created with
  `O_EXCL|O_NOFOLLOW`, forced to `0600`, then checked as a current-euid,
  single-link, empty regular file.
- The returned handle contains only epoch, transfer ID, file number and opaque
  token. Paths and descriptors stay inside the owner.
- Cancel, exact teardown and deinit close owned descriptors and unlink only when
  the staging name still resolves to the original device/inode with safe
  metadata. Replacement or hard-link drift is left untouched.
- Real-filesystem tests cover nested reservation/cancel, existing final and
  duplicate rejection, eight-job cap, teardown cleanup, replacement-safe abort,
  and pinned-root behavior after the selected path becomes an external symlink.

## Verification

- Focused `ViewerFileTransferDestinationOwnerTests`: 6/6 passed.
- Full Swift suite: 946 executed, 0 failures, 4 environment-gated skips.
- Focused current/predecessor audit set: 4/4 passed; full ScriptTests: 159/159
  passed.
- Fresh arm64 Swift Release build completed successfully.
- Rust/Core build was not repeated because this step changes no Rust, C ABI,
  shim or built-core symbol.
- Product App smoke is not applicable because no product route reaches this
  internal primitive.
- Two-Mac transfer remains unverified and does not block this development-only
  milestone.

## Next step

`host-file-transfer-viewer-safe-receive-write-lifecycle`: first bind bounded
payload writes and exact declared-size accounting to the reservation; fsync,
mtime and descriptor-relative no-replace commit remain a separate later gate.
