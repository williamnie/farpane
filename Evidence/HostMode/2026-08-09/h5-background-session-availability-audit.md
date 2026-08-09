# H5.2c background session availability authority audit

## Outcome

H5.2 is not complete for the background HostAgent. The pinned Rust input path
already has the correct fail-closed Aqua authority and an active connection can
publish nested `limited/sessionUnavailable`, but that evidence is insufficient
to withdraw the product's top-level background `ready` state.

The current Host ABI is version 9 and snapshot schema is version 6. The
top-level Host snapshot, Agent projection, XPC snapshot, component-health
policy, and Home readiness contain no active-Aqua availability tuple. As a
result, an enabled LaunchAgent with a compatible XPC snapshot and registered
Rendezvous runtime can still project `ready` while the same macOS session is
locked, off-console, or at LoginWindow. The process-owned background media
owner also has no active-Aqua input; the older in-process App media/presentation
guards do not protect HostAgent media.

This audit freezes the minimum cross-layer contract as Host ABI version 10 and
snapshot schema version 7. It does not implement or advertise that contract.

## Current authoritative evidence

- Rust's macOS authority reads `CGSessionCopyCurrentDictionary` and accepts only
  strict boolean `on-console=true`, `login-done=true`, and `locked!=true`.
  Missing dictionaries, required keys, or non-boolean values fail closed.
- Final simulated mouse/pointer/key adapters recheck that authority before
  injection. Queued input is also protected by the permission epoch, so a
  transition invalidates older queued work.
- An already-authorized Remote connection polls platform authority once per
  second. A transition removes `controlKeyboardMouse`, publishes nested
  `limited/sessionUnavailable`, synchronizes Viewer permission, and emits
  `snapshotChanged`.
- Legacy in-process Host code separately samples Aqua state to pause its local
  SCK/VT route and override session presentation. Background HostAgent uses a
  different media owner and does not execute that App path.
- HostAgent copies HostCore snapshot every 500 ms, but the current snapshot has
  no top-level session tuple and the poller has no semantic transition owner.
- Background readiness currently combines only registration, handshake,
  snapshot availability, and Rendezvous status. Home's background session card
  consumes only nested input availability.

## Frozen ABI v10 / snapshot v7 target

1. Add a strict top-level tuple to the Host snapshot:
   `sessionAvailability=available` with a null reason, or
   `sessionAvailability=limited` with
   `sessionUnavailableReason=sessionUnavailable`. Unknown or contradictory
   tuples fail closed.
2. The tuple is derived only from the pinned Rust active-Aqua authority. Swift
   may transport and consume it but may not override it with a second local
   session decision.
3. While limited, native monitor routes must be rejected or retired through the
   existing exact-route lifecycle; no compressed access unit may enter Rust.
   Recovery in the same Aqua session must revalidate TCC and use fresh media
   epochs rather than replaying an old SCK/VT route.
4. HostAgent must detect semantic tuple changes through its bounded snapshot
   cadence and cause XPC clients to resnapshot. Duplicate observations must not
   create an event or busy loop; stale Agent/session generations cannot restore
   availability.
5. Background health keeps the Agent process as running but withdraws `ready`.
   Home explicitly shows lock/LoginWindow/Fast User Switching as unsupported
   and limited. Pending approval and new control actions are unavailable;
   an existing session may retain only an exact disconnect action.
6. The transition must not request TCC, rotate identity/passwords, change server
   configuration, restart the LaunchAgent, or mutate sleep/network epochs.

## Machine-readable audit

`Scripts/audit-host-session-availability-contract.py` reads only tracked
sources and emits compact JSON. It verifies the existing input safety chain,
the legacy/background ownership split, the absent top-level tuple, and the
current readiness gap. It exits non-zero if those premises drift before the
shared ABI implementation begins.

## Verification

- `python3 Scripts/audit-host-session-availability-contract.py`:
  `contract-gap-confirmed`, no missing evidence.
- `python3 -m unittest Tests.ScriptTests.test_host_session_availability_contract_audit`:
  1 test, 0 failures.
- `swift test`: 820 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  28 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- Canonical RustDesk and `hbb_common` patches passed reverse-apply checks; both
  tracked bridge mirrors matched their Vendor copies byte-for-byte.
- `git diff --check`: passed before staging.

## Remaining boundary

- H5.2d should implement Rust/header/shim and strict Swift decoding for ABI v10
  / snapshot v7 first, including native media fail-closed behavior. Agent XPC
  transition projection and Home readiness should follow as separate bounded
  steps rather than being hidden inside the ABI change.
- Secure Input remains a separate capability decision; this audit does not
  claim it is detected or supported.
- Lock/unlock, LoginWindow, no-user-login, Fast User Switching, TCC continuity,
  media recovery, and zero-input-leak behavior still require an installed Mac
  acceptance matrix.
- No App/Agent was installed, launched, registered, or deployed; no real
  session, TCC state, Hermes configuration, server key, or user file changed.
