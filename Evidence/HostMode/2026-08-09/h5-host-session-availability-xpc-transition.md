# H5.2e Host session availability XPC transition

## Outcome

The second H5.2 implementation checkpoint is complete. The Agent's strict XPC
snapshot payload now uses schema 7 and carries the top-level active-Aqua tuple
without deriving or overriding it in Swift. Both encode and decode accept only
`available + null` or `limited + sessionUnavailable`.

The process-owned 500 ms snapshot refresh path now detects a change in that
typed tuple after an accepted authoritative snapshot. It appends one bounded,
payload-free Agent-local `snapshotChanged` journal record, then performs one
additional snapshot copy so the published `lastEventId` catches up to the same
journal sequence. An already connected App therefore uses its existing event
poller to fetch the marker and automatically resnapshot. The initial snapshot,
duplicate observations, rejected stale observations, and unchanged tuples do
not create markers or a polling loop.

## Contract implemented

- XPC snapshot schema 7 carries `sessionAvailability` and
  `sessionUnavailableReason`; unknown, missing, wrong-typed, schema-6, or
  contradictory documents fail closed.
- The XPC handshake wire version remains 1. This is an internal same-bundle
  App/Agent snapshot payload revision, not a Hermes or remote media protocol
  change.
- The local transition record contains only its Agent-local sequence and
  timestamp. It contains no Core raw JSON, session metadata, identity,
  password, server configuration, or media payload.
- The existing fixed-capacity journal owns sequence assignment and eviction.
  Host mismatch, invalid timestamp, and sequence exhaustion reject the marker;
  product composition then clears snapshot availability and invalidates XPC
  identity rather than publishing a cursor contradiction.
- A successful marker schedules exactly one convergence copy at the marker's
  sequence. The App's existing `snapshotChanged` behavior discards potentially
  stale incremental state and retrieves an authoritative snapshot.
- `HostAgentProcess` injects the same process-owned event journal into the
  snapshot coordinator; no second journal, listener, connection, or session
  authority was introduced.

## Verification

- Focused snapshot/journal/wire tests: 49 passed, 0 failed.
- Focused XPC service/client/event-poller/session/reconnect/admission tests:
  76 passed, 0 failed.
- Fresh `swift test`: 825 passed, 4 conditional built-core tests skipped,
  0 failed.
- Fresh built-core `RDN_CORE_LIBRARY=... swift test`: 825 passed, 0 skipped,
  0 failed; the checked arm64 dylib passed strict code-signature verification.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  28 passed, 0 failed.
- Session audit schema 3 reports `xpc-transition-implemented` with no missing
  evidence. The sleep audit was aligned with XPC snapshot schema 7 and remains
  implemented.
- `swift build -c release --arch arm64`: succeeded.
- Canonical RustDesk and `hbb_common` patches passed reverse-apply checks; the
  tracked Host bridge still matches its Vendor mirror byte-for-byte; `git diff
  --check` passed.

## Remaining boundary

- Background health/readiness still does not consume the top-level tuple. It
  must withdraw ready, approval, and new-control actions while limited.
- Home must present lock/LoginWindow/Fast User Switching as limited or
  unsupported, while an existing session retains only exact disconnect.
- Lock/unlock, LoginWindow, no-user-login, Fast User Switching, TCC continuity,
  fresh media epochs, and zero input/media leakage still require a later
  installed-build acceptance matrix on real Macs.
- Secure Input remains a separate capability decision.

No App/Agent was installed, launched, registered, or deployed. No Hermes,
server key, CI, dependency, database, real TCC state, or user configuration was
changed.
