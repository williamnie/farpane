# H6.3f2b2d Viewer recursive manifest authority lifecycle

## Outcome

CoreBridge now joins two bounded semantic recursive-list parts into one
canonical Viewer manifest for an exact file-session epoch and request. This is
a pure state authority; no network command, destination access or download I/O
is enabled.

## Contract

- Only one positive epoch/request can be active. Stale observations and stale
  teardown are inert.
- Exactly one files part and one empty-directories part are accepted in either
  order. Duplicate or malformed exact-request parts terminate with stable
  protocol violation.
- Each part is bounded to 1,024 entries and 1 MiB UTF-8 metadata before it is
  retained. Empty-directory paths pass the canonical relative-path gate.
- Completion reuses `ViewerFileTransferManifest`, so combined entry/metadata
  limits, checked total bytes, case-fold collisions and ancestor type conflicts
  remain authoritative.
- Only rejected, unavailable and connection-closed may arrive as remote stable
  failures. Exact-epoch teardown is terminal.

## Verification

- Four focused Swift tests cover either-order completion, stale/duplicate
  handling, cross-part collision, pre-retention bounds, stable failures and
  exact teardown.
- The machine audit proves exact ownership, independent part bounds, canonical
  finalization, terminal behavior, ABI immutability and product non-opt-in.
- Focused authority tests passed 4/4. ScriptTests passed 155/155. The full
  Swift suite loaded the exact arm64 Core and passed 940/940; the ABI and all
  Rust/Core sources remain unchanged in this step. Fresh arm64 Swift Release,
  Python compilation, machine audits and `git diff --check` passed.

## Non-claims

- There is no remote recursive-manifest command/callback, download start,
  `openat`, staging file, conflict workflow, picker UI or product opt-in.
- The App is not started because no product path reaches this authority.
- No real user file, Hermes/server, CI, dependency, database, push or deploy
  state changes. Two-Mac acceptance remains unverified and non-blocking.

## Next step

`host-file-transfer-viewer-recursive-manifest-abi-lifecycle`: carry both
bounded semantic parts across the exact Viewer file-session ABI.
