# H6.3f2b2p Viewer receive/write adapter lifecycle

## Outcome

Viewer download start now binds the exact destination lease to a Swift receive
adapter before the path-free Rust request is admitted. Callback-owned blocks
are written and committed in manifest order through the pinned destination
owner; zero-length files and declared empty directories are materialized before
remote completion is exposed as a locally completed transfer.

## Key evidence

- At most eight exact `(session epoch, transfer ID, destination lease)` routes
  are retained, and a rejected Core start rolls back the Swift route.
- Inbound blocks must match the next manifest file and its remaining byte
  bounds. Reservations, writes and no-replace commits stay descriptor-relative
  inside `ViewerFileTransferDestinationOwner`.
- Zero-length files are committed in manifest order. Empty directories use
  private `mkdirat`/`openat` ownership checks and child plus parent `fsync`.
- Protocol, local I/O, durability-unconfirmed, connection-closed and remote
  failures remain distinct. Local failure removes staging state and requests an
  exact Core cancellation.
- Remote completion is suppressed unless all files and empty directories have
  already reached their local commit boundary. Cancellation, rollback and
  teardown remove only the matching route.
- The shared Viewer ABI remains v13 and App/Agent file-transfer product routes
  remain disabled.

## Verification

- Focused receive-adapter filesystem regressions: 4/4 passed.
- Full ScriptTests: 167/167 passed; the new lifecycle audit and predecessor
  audits passed.
- Fresh arm64 Release Rust Core built successfully.
- Full Swift suite loaded that exact fresh Core: 955/955 passed with no skips.
- Full Rust library suite with `rdn-native-core,rdn-native-host`: 230/230
  passed.
- Fresh arm64 Swift Release build passed.
- Bootstrap replay, tracked patch reverse checks, canonical/Vendor bridge byte
  comparison, targeted rustfmt, Python compilation and `git diff --check`
  passed.
- Product App smoke is not applicable because session orchestration and product
  file-transfer routes are still disabled.
- Two-Mac file transfer remains unverified and does not block this
  development-only milestone.

## Next step

`host-file-transfer-viewer-session-orchestration-lifecycle`: compose one Viewer
session owner that requests the recursive manifest, owns the destination lease,
starts/cancels the bounded download and tears every route down with the exact
connection epoch while keeping the product surface off.
