# H6.3f2b2l Viewer receive-block ABI lifecycle

## Outcome

Viewer ABI v13 now exposes one callback-scoped, path-free receive-block seam.
Rust admits only an active, authenticated, exact-epoch file session and Swift
copies and revalidates the decoded bytes before queued delivery. The io-loop
does not call the seam yet, so no wire request, destination write or product
file-transfer route is enabled.

## Key evidence

- `RDNFileTransferReceiveBlock` carries only ABI version, session epoch,
  positive transfer ID, bounded file number and callback-scoped bytes.
- Rust rechecks active/authenticated/file-mode state, exact current epoch and
  the canonical nonempty 128 KiB block bound immediately before synchronous
  callback invocation.
- Swift copies the callback bytes into owned `Data`, then a single semantic
  initializer revalidates epoch, ID, file-number and payload bounds before the
  existing file-transfer lifecycle queue accepts delivery.
- Disconnect and teardown keep using the same delivery gate, so already queued
  receive blocks cannot outlive file-transfer callback delivery.
- Static audit proves the upstream io-loop has no production caller for the new
  emitter and that neither `Data::SendFiles`, destination writes nor App/Agent
  file-transfer opt-in were added.

## Verification

- Focused Rust receive-block regressions: 3/3 passed.
- Focused Swift Viewer file-transfer contract: 11/11 passed.
- Full Rust library suite with `rdn-native-core,rdn-native-host`: 227/227
  passed.
- New and predecessor machine audits passed; full ScriptTests: 163/163 passed.
- Fresh arm64 Release Rust Core built successfully.
- Full Swift suite loaded that exact fresh Core: 951/951 passed with no skips.
- Bootstrap source replay, tracked/vendor bridge byte comparison, rustfmt and
  diff checks passed; fresh arm64 Swift Release build passed.
- Product App smoke is not applicable because the default-off callback has no
  production io-loop or App/Agent route.
- Two-Mac file transfer remains unverified and does not block this
  development-only milestone.

## Next step

`host-file-transfer-viewer-io-loop-receive-interception-lifecycle`: intercept
only the exact registered download block in the Viewer io-loop and emit the
owned semantic callback, while still withholding destination writes and
product enablement.
