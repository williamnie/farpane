# H5.2f Background session readiness and command withdrawal

## Outcome

The third H5.2 implementation checkpoint is complete. Background App health
now consumes the strict top-level active-Aqua session tuple already projected
by the Agent XPC snapshot. `limited + sessionUnavailable` can no longer become
background ready even when the LaunchAgent handshake, snapshot, and Rendezvous
registration are otherwise healthy.

The same typed tuple now gates both Home command discovery and the final
activation-owner submission boundary. While limited, pending approval is not
projected to Home, approval and capability mutations are unavailable, and
stale retained commands of those kinds cannot be submitted or retried. An
existing active session retains only its exact disconnect action and retry.

## Contract implemented

- `HostAgentBackgroundProjectionView` derives a typed session status only from
  the strict XPC payload tuple; missing or contradictory runtime evidence is
  never treated as available.
- Background health requires snapshot/session evidence to be coherent.
  Limited sessions publish `sessionUnavailable`, `isReady == false`, and the
  bounded Home status `当前 Mac 会话不可用` while still accurately reporting
  that the background component process is running.
- Home read-only projection suppresses a pending approval while limited and
  retains an existing active session solely so it can be disconnected.
- One central command policy binds each command name to the exact projected
  connection ID. In limited state it accepts only `disconnectSession` for the
  current active session.
- Home command presentation consumes that policy for idle, in-flight, and
  retryable states. The activation owner independently rechecks it immediately
  before submit or retry, so stale UI cannot bypass the withdrawal.
- Returning to a later coherent `available + null` projection restores ready;
  no second Aqua authority, TCC prompt, registration mutation, or server
  operation was introduced.

## Verification

- Focused projection/readiness/Home/command/activation tests: 77 passed,
  0 failed.
- Fresh `swift test`: 831 passed, 4 conditional built-core tests skipped,
  0 failed.
- Fresh built-core
  `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`:
  831 passed, 0 skipped, 0 failed; the arm64 dylib passed strict code-signature
  verification.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  28 passed, 0 failed.
- Session audit schema 4 reports
  `background-readiness-command-withdrawal-implemented` with no missing
  evidence.
- `swift build -c release --arch arm64`: succeeded.
- Canonical RustDesk and `hbb_common` patches passed reverse-apply checks; both
  tracked bridge mirrors match their Vendor copies byte-for-byte; nested and
  root `diff --check` checks passed.

## Remaining boundary

- Home still needs one dedicated checkpoint for detailed
  lock/LoginWindow/Fast User Switching unsupported/limited session-card
  presentation; this checkpoint adds only the truthful readiness status and
  command withdrawal.
- Lock/unlock, LoginWindow, no-user-login, Fast User Switching, TCC continuity,
  fresh media epochs, and zero input/media leakage still require a later
  installed-build acceptance matrix on real Macs.
- Secure Input remains a separate capability decision.

No App/Agent was installed, launched, registered, or deployed. No Hermes,
server key, CI, dependency, database, real TCC state, or user configuration was
changed.
