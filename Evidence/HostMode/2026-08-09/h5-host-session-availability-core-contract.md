# H5.2d Host session availability core contract

## Outcome

The first H5.2d implementation checkpoint is complete. Host ABI version 10 and
Host snapshot schema version 7 now carry a strict top-level active-Aqua tuple
from the pinned Rust authority through the C version gate and Swift's strict
decoder into the Agent's in-memory snapshot projection.

Native monitor media now fails closed at three boundaries: before a route is
created, on every route service iteration, and at the final encoded access-unit
admission before the payload is copied or queued. Leaving the active Aqua
session therefore rejects new encoded submissions and causes the existing
`NativeRouteGuard` to retire the exact route when the service loop observes the
transition.

This checkpoint intentionally does not publish the tuple through the existing
XPC snapshot document or change background readiness/Home presentation. The
Agent retains the schema-7 tuple internally while its current XPC wire payload
remains schema 6 until the next bounded protocol checkpoint.

## Contract implemented

- `native_host_session_is_available()` is the only product authority and calls
  the pinned macOS `is_active_aqua_session()` policy. Missing or malformed
  `CGSession` evidence continues to fail closed.
- The only valid top-level snapshot tuples are:
  - `available` with a null `sessionUnavailableReason`;
  - `limited` with `sessionUnavailable`.
- Swift requires snapshot schema 7 and rejects missing, unknown, wrong-typed,
  or contradictory availability tuples.
- The Agent snapshot projection retains both typed fields without retaining
  raw JSON or one-shot password material.
- The C header and Rust runtime both report Host ABI 10. No new symbol was
  added; the existing all-or-nothing shim version check protects older cores.
- Identity, password, server configuration, sleep/network generations, and
  connection/codec/display epoch contracts were not changed.

## Verification

- `cargo test --lib --features rdn-native-core,rdn-native-host
  rdn_host_bridge::tests`: 33 passed, 0 failed.
- Fresh final `cargo test --lib --features
  rdn-native-core,rdn-native-host`: 148 passed, 0 failed.
- `Scripts/build-rust-core.sh`: rebuilt and atomically published the arm64
  release core at `Build/CoreBridge/arm64/liblibrustdesk.dylib`.
- Final built-core focused Swift run: 42 passed, 0 skipped, 0 failed, including
  the complete Host lifecycle and shim ABI surface.
- Full built-core `swift test` before the final Rust admission hardening:
  821 passed, 0 skipped, 0 failed; Swift sources were unchanged afterward, and
  the final rebuilt core then passed the 42-test focused lifecycle/ABI run.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  28 passed, 0 failed.
- `swift build -c release --arch arm64`: succeeded.
- Session audit schema 2 reports `core-contract-implemented` with no missing
  evidence; network and sleep audits remain implemented under ABI 10/schema 7.
- Canonical RustDesk and `hbb_common` patches passed reverse-apply checks; the
  tracked Host bridge matched its Vendor mirror byte-for-byte; `git diff
  --check` passed.
- The golden installed-App preflight reached its installation gate and stopped
  because `~/Applications/FarPane.app` is absent. No App was installed for this
  code-only checkpoint.

## Remaining boundary

- Propagate the typed tuple through a versioned Agent XPC snapshot transition,
  including bounded resnapshot and stale-generation rejection.
- Make background health withdraw ready/approval/new-control actions while
  limited, then add explicit Home limited/unsupported presentation with only
  exact disconnect retained for an existing session.
- Install a later completed build and verify lock/unlock, LoginWindow,
  no-user-login, Fast User Switching, TCC continuity, fresh media epochs, and
  zero input/media leakage on real Macs.
- Secure Input remains a separate capability decision.

No App/Agent was installed, launched, registered, or deployed. No Hermes,
server key, CI, dependency, database, real TCC state, or user configuration was
changed.
