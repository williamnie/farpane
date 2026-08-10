# H6.3c Host bounded file-transfer block envelope

## Outcome

FarPane's pinned file-transfer sender and receiver now share a canonical
128 KiB block limit. The receive path rejects an oversized wire payload before
decompression and applies the same hard limit to decoded compressed data before
examining a data source or creating a destination for the current block.

The product remains fail closed: App and HostAgent do not opt into file
transfer, and this step does not claim end-to-end Native Host file transfer.

## Implementation

- `MAX_FILE_TRANSFER_BLOCK_BYTES` is the single sender/receiver limit.
- Raw and compressed wire payloads larger than 128 KiB are rejected before
  decode.
- Compressed payloads use `decompress_with_limit` with a 128 KiB decoded limit;
  malformed input and decompression bombs are rejected.
- Validation runs at the start of `TransferJob::write`, before the data-source
  branch and the `File::create` performed by that write path. A resume-offset
  stream may already have been opened earlier; this step does not change that
  lifecycle, but an invalid block still cannot be decoded or written.
- At-limit raw and compressed payloads remain accepted.
- The implementation and regression tests live in the canonical
  `h6-file-transfer-bounded-block.patch`; bootstrap applies it after the base
  `hbb_common` patch and verifies reverse applicability.

## Security boundary

This step bounds per-block memory growth only. It does not close the documented
validation-to-open symlink TOCTOU, constrain management paths to a FarPane-owned
destination root, implement the Native Host file-service owner, or add Viewer
destination/overwrite/progress UX. File transfer therefore remains disabled in
product callers.

## Verification

- Focused `hbb_common` bounded-block tests: 3/3 passed, covering exact-limit
  raw/compressed, raw/wire oversize, decoded oversize, and malformed compressed
  input.
- Full `hbb_common` release suite: 93/94 passed. The only failure is the existing
  environment-dependent `socket_client::tests::test_test_if_valid_server`, whose
  expectation that the bare host `a` must be rejected also failed when rerun
  alone; all H6.3c tests passed.
- Full `rdn-native-core,rdn-native-host` Rust library suite: 180/180 passed.
- Fresh arm64 Core build succeeded; Swift tests loading that Core: 924/924
  passed; full ScriptTests: 138/138 passed; release Swift build succeeded.
- The H6.3c machine audit verifies the shared limit, validation ordering,
  bounded decoder, canonical patch/bootstrap replay, focused tests, and
  product default-off state.
- The updated H6.3b audit continues to require every remaining product-readiness
  gap while recognizing bounded compressed payloads as an established guard.
- Canonical bootstrap/reverse applicability, Python compilation, diff check,
  and sensitive-assignment scan passed.

## Next step

H6.3d1 established the descriptor-relative no-follow receive root, H6.3d2 added
safe mutations, and H6.3e1 composed their owner core. The next boundary is
`host-file-transfer-receive-root-config-contract`, still before any product
caller can opt in.
