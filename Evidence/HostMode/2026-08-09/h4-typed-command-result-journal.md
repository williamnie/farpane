# H4.3f5b Native typed command-result journal

## Outcome

- Replaced raw Core `commandResult` replay with a native typed journal record that shares the existing boot-lifetime local sequence, capacity and cursor authority.
- Added a strict Core result decoder and a command-service consume seam that completes only known queued commands before publishing their typed result.
- Preserved the existing wire schema and request retry authority while making replay independent from Rust event-ID reuse or synthetic IDs.

## Key evidence

- `HostAgentEventState.ingest(_:)` now rejects every raw Core event whose parsed type is `commandResult` with `typedCommandResultRequired`; that raw envelope cannot enter snapshot, replay or XPC projection.
- `.core` and `.commandResult` records are allocated under the same state lock and monotonically increasing local sequence. Both consume the same bounded record capacity and produce the same explicit gap/pagination behavior.
- A typed result requires a valid Host identifier and exact JSON timestamp. Equal retained command ID/result pairs return the original sequence; a different result for the same retained ID is rejected. Eviction removes only that exact retained record, allowing a later replay publication to receive a fresh local sequence.
- `HostAgentCoreCommandResultDecoder` accepts only an exact six-key schema-1 Core envelope whose non-Boolean positive event ID, event type, Host identity and timestamp agree with the already decoded `HostCoreEvent`; payload must be exactly the bounded typed result shape.
- `HostAgentXPCCommandService.consumeCoreResultEvent` leaves non-command events caller-owned, rejects malformed/foreign results, and sends decoded results through the existing queued-command completion authority. Unknown, pre-queue or contradictory results therefore cannot be journaled.
- Native typed records project directly to the unchanged `commandResult` wire payload. No raw Core JSON, password, arbitrary payload key or source event ID is serialized.
- Command retries still acknowledge first and publish afterward. While the typed record is retained publication is idempotent; after journal eviction the separately bounded command authority can republish the original result without preparing or executing the command again.

## TDD evidence

- RED: the focused target failed to compile because the journal had no typed payload, `ingestCommandResult`, strict Core result consumer or typed rejection/outcome cases.
- GREEN: five new tests cover raw rejection, native wire replay, retained dedupe/conflict, eviction/reappend, invalid identity/timestamp, strict Core consumption, malformed/foreign/unknown results and completed-command retry.
- Existing event state, wire event, command service, App snapshot/event client, polling owner and background projection tests were migrated from raw command-result fixtures to the native typed record path.

## Verification

- `swift test --filter 'HostAgent(EventState|XPCWireEvent|XPCCommandService|XPCSnapshotClient|XPCEventPollingOwner|XPCCommandResultJournal)'`: 58 tests, 0 failures.
- `swift test --filter HostAgentBackgroundProjectionAuthorityTests`: 10 tests, 0 failures.
- `swift test`: 668 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.

## Remaining boundary

- `HostAgentProcessRuntime` does not yet construct or retain one command admission authority, command service and execution adapter for the process boot.
- The real Core event callback does not yet route `commandResult` through the command service before generic snapshot/media consumers; raw results currently fail closed at the journal if no command composition exists.
- Listener construction still injects `commandService: nil`, so the product command selector remains unavailable.
- Execution adapter cancellation/drain is not yet ordered into process teardown, and malformed/foreign/unknown Core result outcomes have no process-lifetime invalidation policy.
- There is still no App command client, timeout/correlation owner or Home command availability transition.
- No App GUI, HostAgent process, SMAppService mutation, installation, deployment or real-device command was exercised.
