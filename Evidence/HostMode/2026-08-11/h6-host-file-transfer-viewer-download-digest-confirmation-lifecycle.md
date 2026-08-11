# H6.3f2b2o Viewer download digest-confirmation lifecycle

## Outcome

Viewer download jobs now retain the completed recursive manifest's per-file
size/mtime authority inside Rust. The pinned upstream io loop asks a
feature-gated bridge hook before its existing digest path: only the next exact
new-file digest for a registered download receives `OffsetBlk(0)` through the
existing peer. Matching malformed or duplicate digests are consumed and fail
closed; foreign jobs retain upstream behavior.

## Key evidence

- Download registration requires the exact completed manifest file count and
  clones its ordered per-file authority into the connection-local job.
- Digest admission rejects upload, resume, identical and nonzero transferred
  offsets, plus out-of-order file numbers and size/mtime drift.
- The confirmation sequence advances only when an exact confirmation is
  constructed; duplicate or later malformed input cannot skip a file.
- Inbound blocks are rejected until that file number's digest has been
  confirmed, and remain under the existing owned/decompressed 128 KiB envelope.
- A standalone tracked patch owns the upstream hook and bootstrap replays and
  reverse-checks it. No Viewer ABI, path or descriptor crosses this boundary.
- The Swift destination reservation/write/commit adapter and all product routes
  remain off, so the semantic callback still drops payload bytes.

## Verification

- Focused Rust digest regression: 1/1 passed; receive-block regressions: 3/3
  passed; download-start regressions: 2/2 passed.
- Full Rust library suite with `rdn-native-core,rdn-native-host`: 230/230
  passed.
- New and predecessor machine audits passed; full ScriptTests: 166/166 passed.
- Fresh arm64 Release Rust Core built successfully.
- Full Swift suite loaded that exact fresh Core: 951/951 passed with no skips.
- Bootstrap source replay, tracked patch reverse-check, canonical/vendor bridge
  comparison, rustfmt, static contract and diff checks passed; fresh arm64 Swift
  Release build passed.
- Product App smoke is not applicable because the destination adapter and
  product routes remain disabled.
- Two-Mac file transfer remains unverified and does not block this
  development-only milestone.

## Next step

`host-file-transfer-viewer-receive-write-adapter-lifecycle`: connect the owned
semantic receive-block callback to exact-session Swift reservation/write/commit
authority while preserving path-free ABI, no-replace destination semantics and
product-off defaults.
