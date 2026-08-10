# H6.3f2b2k Viewer inbound block envelope

## Outcome

Viewer Rust now has an owned, bounded and fail-closed semantic envelope for
future inbound file blocks. It remains internal: no receive callback, io-loop
interception, download wire dispatch or product enablement exists.

## Key evidence

- An inbound block must match the exact registered transfer ID and carry a
  nonnegative file number below that job's manifest total.
- Raw wire data must be nonempty and no larger than upstream
  `MAX_FILE_TRANSFER_BLOCK_BYTES` (128 KiB).
- Compressed data is decoded only through `decompress_with_limit` using the
  same 128 KiB bound; raw data is also copied into an owned `Vec<u8>`.
- Empty or oversized decoded payloads, malformed compressed data, compression
  bombs, wrong transfers and invalid file numbers fail closed.
- The resulting semantic value is path-free and contains only transfer ID,
  file number and owned payload bytes.

## Verification

- Focused Rust receive-block regressions: 2/2 passed.
- Full Rust library suite with `rdn-native-core,rdn-native-host`: 226/226
  passed.
- Fresh arm64 Release Rust Core built successfully.
- Full Swift suite loaded that exact fresh Core: 950/950 passed with no skips.
- New machine audit passed; full ScriptTests: 162/162 passed.
- Targeted rustfmt check, bootstrap source replay, tracked/vendor bridge byte
  comparison, diff check and fresh arm64 Swift Release build passed.
- Product App smoke is not applicable because no App/Agent route reaches this
  internal envelope.
- Two-Mac file transfer remains unverified and does not block this
  development-only milestone.

## Next step

`host-file-transfer-viewer-receive-block-abi-lifecycle`: expose the owned
semantic block through an exact-session callback without yet dispatching the
remote download command.
