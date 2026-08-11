# H6.3f2b2n Viewer download wire-request lifecycle

## Outcome

Viewer download start now dispatches one canonical root file-transfer request
only after exact completed-manifest registration succeeds. It queues a generic
`FileAction::Send` with the registered transfer ID, root path `/`, file number
zero and hidden files disabled. The bridge does not use `Data::SendFiles`, so
RustDesk creates no path-based local write job. Queue failure atomically rolls
registration back; rejected or duplicate starts send nothing.

## Key evidence

- Existing active/authenticated/dedicated-session, exact-epoch, remote-policy,
  sender, completed-manifest, unique-ID and eight-job bounds still gate start.
- Registration and the nonblocking queue send share the job mutex, preventing
  cancel or retry from observing a half-dispatched transfer ID.
- The regression decodes the actual protobuf union and checks ID, `/`, file 0,
  hidden=false and generic type rather than only checking that a message exists.
- A closed-channel regression proves start returns stable failure and leaves no
  active registration; duplicate and malformed requests cannot enqueue again.
- Overwrite-digest confirmation and the Swift destination
  reservation/write/commit adapter remain disconnected, so the remote sender
  cannot advance into payload blocks and product file transfer remains off.

## Verification

- Focused Rust wire-request and rollback regressions: 2/2 passed.
- Full Rust library suite with `rdn-native-core,rdn-native-host`: 229/229
  passed.
- New and predecessor machine audits passed; full ScriptTests: 165/165 passed.
- Fresh arm64 Release Rust Core built successfully.
- Full Swift suite loaded that exact fresh Core: 951/951 passed with no skips.
- Bootstrap source replay, tracked/vendor bridge byte comparison, rustfmt,
  static contract and diff checks passed; fresh arm64 Swift Release build
  passed.
- Product App smoke is not applicable because overwrite-digest confirmation,
  destination adaptation and product routes remain disabled.
- Two-Mac file transfer remains unverified and does not block this
  development-only milestone.

## Next step

`host-file-transfer-viewer-download-digest-confirmation-lifecycle`: consume only
the exact registered download digest and send a bounded offset-zero confirmation
without borrowing a destination path or enabling product file transfer.
