# H4.3f1 Strict approval/session command wire contract

## Outcome

- Added a strict Data-only request and queued-acceptance contract for the six approval/session commands needed by the background Home cards.
- A fresh request ID may retry the same command ID and semantic payload. The contract preserves both identities for a later bounded dedupe authority.
- The acknowledgement carries only `acceptance=queued`; it cannot represent successful approval, revocation, or disconnect. Final outcomes remain correlated `commandResult` events.

## Key evidence

- Request envelopes use exact keys and bind wire version, canonical request ID, bounded command ID, Host instance, Agent boot, timestamp, canonical payload byte length, command name and connection ID.
- Connection IDs must be bounded, contain only the frozen identifier alphabet, and begin with the exact request Host instance plus `:`. A foreign or empty target fails closed.
- Only six non-sensitive command names exist in this schema. Unknown or future names and extra payload fields fail closed.
- Queued acknowledgements can only be constructed for the exact request Host/boot identity and are evaluated against request ID, command ID, wire version, Host instance and Agent boot ID.
- This file has no Objective-C/XPC selector, service, connection, queue, HostCore adapter or execution authority.

## TDD evidence

- RED: the focused test target failed to compile because the command request, command name, queued acknowledgement and document error types did not exist.
- GREEN: all seven focused round-trip, malformed-input, identity-correlation, retry and source-isolation tests pass.

## Verification

- `swift test --filter HostAgentXPCWireCommandTests`: 7 tests, 0 failures.
- `swift test --filter 'HostAgentXPCWire(Handshake|Snapshot|Event|Command)Tests'`: 31 tests, 0 failures.
- `swift test`: 624 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: clean.

## Remaining boundary

- There is no command selector, listener handler, App client, queue, dedupe window, HostCore execution adapter or Home command routing yet; background command availability remains false.
- The next automatic step is a bounded Agent-side command admission/dedupe authority. XPC service wiring follows only after duplicate, conflicting-payload, boot-lifetime and result-replay semantics are proven.
- No App GUI, HostAgent process, SMAppService mutation, installation, deployment or real-device command was exercised.
