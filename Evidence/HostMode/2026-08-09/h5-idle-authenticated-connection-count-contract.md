# H5.3f Idle authenticated-connection count contract

## Outcome

The H5.3e shared checkpoint is implemented end to end. Host ABI v11 and Host
snapshot schema v8 now publish `authenticatedConnectionCount` from the length
of RustDesk server `AUTHED_CONNS`, the mutex-protected authority that contains
every admitted `AuthConnType` and is pruned by `AuthedConnID` RAII drop.

Strict Swift, the Agent projection, and nested XPC snapshot schema v8 preserve
the unsigned count. Missing, boolean, fractional, or otherwise malformed
counts fail closed; an `activeSession` paired with zero authenticated
connections is also rejected. The outer XPC wire version remains unchanged.

Runtime-state schema v2 records the count from exactly one authority: the
legacy in-process Host snapshot, or one coherent background Agent projection.
The idle validator now requires every accepted ready-window record to contain
count zero and derives `allAuthenticatedConnectionsProvenAbsent`; it no longer
hardcodes the result or substitutes media/session/sleep-assertion state.

## Key evidence

- `native_host_authenticated_connection_count()` reads `AUTHED_CONNS` under
  its existing mutex without filtering Remote, FileTransfer, PortForward,
  ViewCamera, Terminal, or future admitted connection types.
- Host snapshot v8 exports the count and Host ABI v11 prevents older strict
  clients or cores from silently accepting the changed snapshot contract.
- `HostCoreSnapshot` and `HostAgentXPCWireSnapshotPayload` use strict integer
  conversion and preserve the count through Agent snapshot publication.
- Runtime-state schema v2 emits an explicit JSON `null` while the selected
  authority is unavailable; a ready idle acceptance window rejects any null or
  nonzero count.
- The machine audit now emits `status=implemented`, while the performance
  matrix still demands a real positive idle run and retains the remaining
  section 15.2 boundaries.

## Verification

- Pinned Rust patch bootstrap and reverse-apply replay passed at commit
  `6c578292e8ebbbec708b76986ba8c4bc7c509747`.
- Rust full library tests: 149 passed, 0 failed.
- Swift full tests without a built core: 832 passed, 4 conditional built-core
  skips, 0 failed.
- Fresh arm64 Release Rust core build succeeded; built-core Swift full tests:
  832 passed, 0 skipped, 0 failed. The real Host ABI lifecycle observed v11,
  snapshot v8, and idle count zero.
- Focused idle/audit compatibility tests: 12 passed, 0 failed. Full
  ScriptTests: 45 passed, 0 failed.
- Swift arm64 Release build, Python compile, canonical Rust patch reverse
  replay, and source diff checks passed.
- Strict decoder tests cover missing, boolean, fractional, and active-session
  zero-count rejection in both HostCore and nested XPC documents.

## Remaining boundary

- This implementation does not create real performance evidence. A fresh
  installed-machine 600-second `host-ready-no-screen-route` run is still
  required before section 15.2 item 1 can pass.
- The Apple Silicon/Intel 12-run base matrix, recovery repetition, battery and
  thermal evidence, combined Host/Viewer budgets, and Instruments remain open.
- The installed-App golden preflight remains unavailable on this machine
  because `/Users/xiaobei/Applications/FarPane.app` is not installed; it must
  be rerun after a signed App is installed.
- No App or Agent was installed, launched, registered, or deployed. Hermes,
  CI, dependencies, database, real TCC/configuration, and secrets were not
  changed; nothing was pushed.
