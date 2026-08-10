# H6.3f1 Viewer file-transfer destination/progress API contract

## Outcome

CoreBridge now owns a pure, product-disabled contract for a future Viewer
download adapter: opaque destination admission, bounded untrusted manifests,
monotonic progress, cancellation and teardown. No file I/O or Viewer Core ABI
surface is enabled by this checkpoint.

## Contract

- A local destination crosses the UI/CoreBridge boundary only as a nonzero
  opaque lease bound to the exact Viewer session epoch. Progress snapshots do
  not expose the local path, descriptor or a raw protocol error.
- Remote manifest paths reject absolute, empty, NUL, repeated separators,
  `.`/`..`, non-NFC names, case-insensitive canonical aliases, ancestor/type
  collisions and private `*.farpane-part` staging names.
- One manifest is limited to 1,024 entries and 1 MiB of UTF-8 path metadata;
  declared sizes use checked `UInt64` accumulation.
- One authority owns at most eight positive transfer IDs. Updates must match
  the session and ID, use a strictly increasing sequence, keep file/byte
  progress monotonic and bounded, and report finite nonnegative speed.
- Conflict waits require a valid file number. Completion requires exact total
  file and byte counts; terminal updates remove the job immediately.
- Local cancellation changes the phase to `cancelling`; only completion,
  cancellation or a stable typed failure may then terminate the job. Session
  teardown removes only exact-epoch jobs and returns their IDs to the adapter.

## Focused evidence

- Six Swift tests cover canonical manifests, entry/metadata/size overflow,
  session-bound destinations, monotonic terminal progress, conflict/cancel/
  stale-session teardown and the eight-job/duplicate-ID limit.
- The machine audit reports all 10 evidence checks and all 10 source anchors
  present.
- Historical H6.3 audits now acknowledge this contract while preserving the
  remaining product, ABI, UI, replacement and dual-Mac gaps.

## Verification

- Focused `ViewerFileTransferContractTests`: 6/6 passed.
- Full Swift suite loading the existing exact arm64 Core: 930/930 passed.
- Full ScriptTests: 149/149 passed.
- Swift Release build, Python compilation, machine audits, `git diff --check`
  and secret-candidate scan passed.

## Non-claims

- Viewer ABI remains v8. There is no file-transfer callback/command, local
  descriptor owner, Rust client lifecycle, real download/upload I/O or UI.
- App and Agent still do not opt into file transfer. Product capability remains
  off, so an installed-app GUI smoke would not exercise this contract.
- Multi-file upload resume and existing-target replacement remain unsupported.
- No real user file, Hermes/server, CI, dependency, database, push or deploy
  state changed. Two-Mac file-transfer acceptance remains unverified and
  non-blocking under the current development-only target.

## Next step

`host-file-transfer-viewer-core-abi-event-command-lifecycle`: add the bounded,
default-off Viewer C ABI callbacks and commands that map Rust file-transfer
events into this contract without exposing raw paths or errors.
