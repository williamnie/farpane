# H6.3f2b2m Viewer io-loop receive interception lifecycle

## Outcome

The feature-gated Viewer io-loop now offers inbound file blocks to FarPane
before RustDesk's upstream file writer. Only a bridge-registered download ID is
consumed: valid blocks emit the existing ABI v13 callback after releasing the
job-map lock, matching malformed blocks fail closed, and unmatched blocks keep
the upstream RustDesk write-job path. No download request, destination write or
product file-transfer route is enabled.

## Key evidence

- `InvokeUiSession` has a default-off receive-block hook behind
  `rdn-native-core`, preserving upstream behavior for non-FarPane builds.
- `FileResponse::Block` calls the hook first and falls back to
  `fs::get_job(...).write(...)` only when FarPane did not consume the block.
- `BridgeUi` recognizes only an exact ID in `active_file_download_jobs`, copies
  the small job authority out of the map and releases the mutex before decode
  and callback delivery.
- Exact-ID blocks with an invalid file number or payload are consumed without
  a callback, so malformed transfer data cannot fall through to an unrelated
  upstream writer.
- Static audits keep the next boundaries closed: there is still no Viewer wire
  request, safe-destination write, App/Agent file-transfer opt-in or shared ABI
  change in this step.

## Verification

- Focused Rust receive-block/io-loop regressions: 4/4 passed.
- Full Rust library suite with `rdn-native-core,rdn-native-host`: 228/228
  passed.
- New, predecessor and formatting-regression machine audits passed; full
  ScriptTests: 164/164 passed.
- Fresh arm64 Release Rust Core built successfully.
- Full Swift suite loaded that exact fresh Core: 951/951 passed with no skips.
- Bootstrap source replay, tracked patch reverse check, tracked/vendor bridge
  byte comparison, rustfmt and diff checks passed; fresh arm64 Swift Release
  build passed.
- Product App smoke is not applicable because no wire request or product route
  was enabled.
- Two-Mac file transfer remains unverified and does not block this
  development-only milestone.

## Next step

`host-file-transfer-viewer-download-wire-request-lifecycle`: send the bounded
Viewer download request for one registered transfer while continuing to
withhold destination writes and product enablement.
