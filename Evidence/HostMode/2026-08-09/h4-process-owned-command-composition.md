# H4.3f5c Process-owned command composition

## Outcome

- Added one boot-lifetime owner that composes command admission, post-reply serial execution, typed Core-result consumption and native event-journal publication.
- Routed the real HostCore callback through that owner before the existing snapshot/media consumers and injected its single shared command service into every eligible product XPC connection.
- Ordered command admission closure and bounded queue drain before XPC identity invalidation and HostCore teardown.

## Key evidence

- `HostAgentXPCCommandProcessOwner` has an explicit `waitingForRuntime -> waitingForIdentity -> active` state machine. Runtime submission and Host identity each bind once; a changed identity, repeated executor binding or invalid ordering terminally invalidates the owner.
- The runtime creates the owner from the exact bootstrap lease build/boot identity before starting Core. `HostControlClient` sends every callback to `consumeCoreEvent`, while ordinary non-command events continue through the previous process consumer.
- A strict Core `commandResult` is consumed only by the active boot-bound command service. Published and unchanged results never reach the raw journal; malformed, foreign, unknown, contradictory or journal-rejected results invalidate the command owner and XPC identity once.
- The adapter submits only the existing typed Core command. Core `notRunning` maps to `core-unavailable`, typed command rejection to `core-rejected`, and other errors to `core-failure`; all immediate outcomes use the same typed service/journal publisher as authoritative Core results.
- Identity binding constructs one capacity-bounded admission authority, one serial adapter and one service. The listener receives that service through a process-owner provider, so reconnects share the same command-ID dedupe/result replay window.
- Product listener admission now requires a non-nil command service after peer and ready-identity checks. Missing composition rejects the connection before interface export/resume instead of silently exposing a read-only fallback.
- Cancellation first removes command service availability and invalidates admission, then waits up to the caller's bound for every acked command already in the serial queue. Product teardown requests a two-second drain before invalidating XPC identity and stopping Core; duplicate teardown callers wait on the same adapter group.
- The owner stores no request Data, raw JSON, credential, file, user default or XPC connection. Command results remain bounded typed records in the existing in-memory journal.

## TDD evidence

- RED: the new focused test target failed to compile because no process command owner, state machine, service snapshot or Core event routing API existed.
- GREEN: six owner tests cover one-shot runtime/identity binding, identity contradiction, post-reply typed execution, completed retry without re-execution, ordinary event forwarding, immediate failure publication, malformed/foreign/unknown result invalidation and cancellation that drains multiple queued submissions.
- Listener and product-source integration tests cover missing-service rejection, shared provider composition and command-drain-before-XPC/Core teardown ordering.

## Verification

- `swift test --filter 'HostAgentXPC(ProcessIdentityIntegration|ListenerAdmissionShell|CommandProcessOwner)Tests'`: 17 tests, 0 failures.
- `swift test`: 675 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: pending fresh run.
- `swift build -c release --arch arm64`: pending fresh run.

## Remaining boundary

- The App has no typed command client, request timeout/correlation lifecycle or command-result projection into the Home approval/session actions, so background commands remain disabled.
- No automatic reconnect policy is added; reconnect dedupe is ready only when the existing App lifecycle establishes another snapshot-first session in the same Agent boot.
- This step does not add password/secret commands, change any wire schema or Host ABI, or enable the top-level background command UI.
- No App GUI, installed HostAgent, SMAppService mutation, Hermes change, deployment, push or real-device command was exercised.
