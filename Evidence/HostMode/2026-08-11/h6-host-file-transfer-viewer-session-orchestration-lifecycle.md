# H6.3f2b2q Viewer session orchestration lifecycle

## Outcome

The package-scoped Viewer file-transfer session owner now binds recursive
manifest admission, safe destination ownership, download start, local receive
proof, progress, cancellation and connection teardown to one exact Core
connection epoch. It serializes the wire manifest request that has no
independent empty-directory response ID while allowing at most eight completed
manifest downloads to run concurrently. Product file transfer remains off and
the shared ABI remains version 13.

## Key evidence

- One pending manifest request and every active download are owned by a single
  `ViewerFileTransferSessionOwner`; stale epochs, duplicate identifiers and a
  ninth concurrent download fail closed without consuming the caller's
  destination owner.
- A destination lifetime is consumed only after manifest admission. Manifest
  rejection closes that exact destination, a rejected initial Core command
  leaves it with the caller, and a rejected download start closes the already
  consumed owner.
- Remote completed, cancelled and failed terminal events require the matching
  local receive adapter proof before progress can finish. Premature or
  contradictory terminal state cancels and discards only the exact receive
  route.
- Connection teardown waits for synchronous manifest/start/cancel commands,
  then cancels and discards active downloads before closing every active and
  pending destination descriptor. A dedicated concurrent regression blocks a
  manifest command and proves the descriptor stays live until that command
  returns.
- The progress authority can now remove one exact epoch/transfer pair, so one
  failure cannot erase unrelated active progress.
- The machine audit reports
  `viewer-session-orchestration-implemented-product-off` and names
  `host-file-transfer-viewer-product-composition-lifecycle` as the next bounded
  implementation step.

## Verification

- RED: the initial focused test compile failed because the session owner,
  protocol and events did not exist.
- Focused Viewer session-owner regressions: 10/10 passed; the broader Viewer
  file-transfer group passed 41/41.
- Full ScriptTests: 168/168 passed, including the new session audit and the
  updated predecessor audit.
- Fresh arm64 Rust Core built successfully; the full Swift suite loaded that
  exact Core and passed 965/965 with no skips.
- Full Rust library suite with `rdn-native-core,rdn-native-host`: 230/230
  passed. Fresh arm64 Swift Release build passed.
- Idempotent Core bootstrap, canonical/vendor bridge equality, tracked receive
  and digest patch reverse checks, owned-source rustfmt, Python compilation and
  repository diff checks passed.
- Product App smoke is not applicable because App/Agent still construct no
  file-transfer session owner and expose no picker or enablement route.
- Two-Mac file transfer remains unverified and does not block this
  development-only milestone.

## Next step

`host-file-transfer-viewer-product-composition-lifecycle`: compose the session
owner into the Viewer connection lifetime and add an explicit product entry
without changing Hermes, CI, root dependencies or the shared ABI unless the
existing product boundary proves that an ABI change is necessary.
