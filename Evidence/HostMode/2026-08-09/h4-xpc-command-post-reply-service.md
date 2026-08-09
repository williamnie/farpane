# H4.3f3 Post-reply command service orchestration

## Outcome

- Added a pure Swift command service that composes strict command Data decoding, boot-bound admission, injected execution preparation, queued acknowledgement and result publication/replay.
- New work and completed-result replay are represented as one-shot post-reply actions, so the future transport can deliver the correlated queued acknowledgement before any execution or replay publication becomes observable.
- No XPC selector, HostCore adapter, event journal integration, App command client or Home command enablement was added.

## Key evidence

- A new command first reserves admission, prepares a non-executing queue ticket, constructs the bounded acknowledgement Data and marks the exact reservation queued. Only then does the service return a `HostAgentXPCCommandPreparedResponse`.
- The prepared response documents and exposes the required transport order: deliver `data`, then call `performAfterReply()`. The one-shot action remains safe under concurrent repeated calls.
- A duplicate arriving while preparation is pending receives no acknowledgement. After queueing, the same semantic command receives an acknowledgement without another preparation or execution.
- A completed retry receives its new correlated acknowledgement before the retained result is republished. Publication failure keeps the completed result available for another retry without re-execution.
- Execution preparation or acknowledgement construction failure cancels the pre-queue reservation, allowing a fresh retry. A preclaimed ticket violates the preparation seam and terminally invalidates the authority without starting work.
- Foreign identity, malformed Data, conflicting payload, unknown result and contradictory result remain fail closed through the existing strict wire and admission authorities.
- Source-isolation tests verify that this layer contains no XPC interface/listener/connection, Objective-C selector, HostCore command call, file persistence or user defaults.

## TDD evidence

- RED: the focused test target failed to compile because the command service, typed execution, queue ticket, delivery outcomes and response orchestration did not exist.
- GREEN: thirteen focused tests cover malformed/foreign input, queue-before-start ordering, preparation rollback, pending concurrency, duplicate acknowledgement, completed replay, publication retry, invalid clock rollback, conflicts, terminal invalidation and concurrent one-shot execution.
- During review the initial start-before-return shape was rejected: it could allow a synchronous result to appear before the caller delivered the queued acknowledgement. The implementation and tests were tightened to an explicit post-reply action before final verification.

## Verification

- `swift test --filter HostAgentXPCCommandServiceTests`: 13 tests, 0 failures.
- `swift test --filter 'HostAgentXPC(CommandService|CommandAdmissionAuthority|WireCommand)Tests'`: 34 tests, 0 failures.
- `swift test`: 651 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.

## Remaining boundary

- The transport has not yet installed a Data-only Objective-C command selector. H4.3f4 must send `prepared.data` through the reply block before invoking `performAfterReply()` and must only admit commands after that connection's authoritative snapshot is ready.
- There is still no product execution adapter from the six typed commands to HostCore, no command-result journal publication wiring, App-side command request owner or Home command availability transition.
- If a future transport omits the post-reply call, the command remains queued but unstarted; selector integration must make the two operations an explicit linear sequence.
- No App GUI, HostAgent process, SMAppService mutation, installation, deployment or real-device command was exercised.
