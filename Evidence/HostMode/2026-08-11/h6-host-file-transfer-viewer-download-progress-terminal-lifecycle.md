# H6.3f2b2g Viewer download progress/terminal lifecycle

## Outcome

Registered Viewer download jobs now produce strict, typed progress and terminal
callbacks. This remains an internal lifecycle: no download wire request or local
receive I/O is active, and product file transfer remains default-off.

## Key evidence

- Rust translates upstream `job_progress` into exact-session callbacks only when
  sequence, completed-file count, integer completed bytes and finite speed are
  monotonic and within the registered manifest totals.
- `job_done` removes the registration and reports exact file/byte totals;
  successful cancel removes it and preserves the last accepted progress;
  `job_error` removes it and reports stable `unavailable` without raw text.
- Callback emission remains gated by active, authenticated, dedicated file mode
  and exact epoch, and happens after the job mutex is released.
- Swift uses one failable semantic initializer for ABI callback validation, then
  projects only typed phases/failures into `ViewerFileTransferProgressUpdate`.
- Rust regressions cover accepted and regressive progress, exact completion,
  post-terminal suppression, stable error and cancel. Swift regressions cover
  projection plus malformed sequence, bounds and terminal shapes.
- The machine audit reports
  `viewer-download-progress-terminal-lifecycle-implemented-product-off`, with
  download wire dispatch, local I/O, product enablement and two-Mac acceptance
  all explicitly false.

## Verification

- Focused Rust download lifecycle regressions: 2/2 passed.
- Focused Swift `ViewerFileTransferContractTests`: 10/10 passed.
- Full Rust library suite with `rdn-native-core,rdn-native-host`: 224/224 passed.
- Fresh arm64 Release Rust core built successfully; built-core
  `HostBridgeContractTests`: 3/3 passed.
- Full Swift suite: 944 executed, 0 failures, 4 environment-gated skips.
- Focused machine audit and its predecessor audit: 2/2 passed; full ScriptTests:
  158/158 passed.
- Fresh arm64 Swift Release build completed successfully.
- Product App smoke is not applicable because no App/Agent opt-in or product call
  route can exercise this internal callback lifecycle.
- Two-Mac transfer/progress remains unverified and does not block this
  development-only milestone.

## Next step

`host-file-transfer-viewer-safe-staging-reservation-lifecycle`: first reserve
descriptor-owned private staging files without exposing a path or descriptor;
payload write, final commit and actual wire dispatch remain later gates.
