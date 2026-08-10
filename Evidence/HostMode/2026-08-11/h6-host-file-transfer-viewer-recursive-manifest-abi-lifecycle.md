# H6.3f2b2e Viewer recursive manifest ABI lifecycle

## Outcome

Viewer ABI v11 now carries an exact-session, single-flight recursive-manifest
request and two bounded callback-scoped semantic parts into the existing Swift
manifest authority. Product file transfer remains off and no download I/O is
reachable.

## Contract

- A positive request ID and exact active file-session epoch must pass active,
  authenticated, remote-permission and ready-sender gates. Only one recursive
  request is admitted per epoch: the empty-directory response has no request ID,
  so retries require a fresh epoch and cannot consume a late prior response.
- The command sends only root-bound `AllFiles` and `ReadEmptyDirs` messages with
  hidden entries disabled. It does not send a destination path.
- Rust owns each remote response before callback delivery, admits only regular
  files or empty directories with canonical relative paths, and enforces 1,024
  entries plus 1 MiB UTF-8 metadata per part.
- Files and empty directories may arrive in either order. Duplicate, malformed,
  exact remote error, send failure, disconnect, worker exit and job teardown
  clear pending state fail closed.
- Swift copies callback-scoped bytes synchronously, revalidates ABI, exact
  request identity, status, part, UTF-8, path, type, size, mtime and case-fold
  collisions, then projects the result into the existing recursive authority.

## Verification

- Focused Rust tests cover owned semantic bounds and the exact two-message,
  two-part lifecycle. Focused Swift tests cover callback-shape revalidation and
  either-order authority completion.
- The machine audit proves header/shim/build symbol coverage, request gates,
  response ownership, Swift revalidation, product non-opt-in and the remaining
  download boundary.
- Full Rust passed 222/222 and full Swift passed 941/941 with four unrelated
  environment-gated tests skipped. A separate exact built-core run passed 4/4,
  including Viewer ABI v11, the new manifest symbol and the unchanged Host ABI.
  ScriptTests passed 156/156. Fresh arm64 Rust Core and Swift Release builds,
  targeted rustfmt, Python compilation, machine audits and diff checks passed.

## Non-claims

- There is no download start command, local `openat`/write/staging lifecycle,
  conflict UI, picker UI or product opt-in.
- The App is not started because no product route reaches this ABI.
- No real user file, Hermes/server, CI, dependency, database, push or deploy
  state changes. Two-Mac acceptance remains unverified and non-blocking.

## Next step

`host-file-transfer-viewer-download-start-abi-lifecycle`: bind one validated
manifest and opaque destination lease to a bounded exact-session download job
before any local file creation or writing is introduced.
