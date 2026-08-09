# H4.3f5a Typed HostCore command execution adapter

## Outcome

- Added an exhaustive typed mapping from the six command-wire names to approval, active-capability revoke and disconnect HostCore submissions.
- Extended the existing Core runtime and owned-runtime lifetime boundary with the corresponding typed HostControl operations.
- Added a process-lifetime serial execution adapter whose queue ticket remains inert until the H4.3f4 transport has delivered the queued acknowledgement.

## Key evidence

- Approval and rejection map only to `HostApprovalDecision`; input, clipboard and audio revocation map only to `HostSessionRevocableCapability`; disconnect has its own action. Command ID and exact connection ID remain attached to every typed submission.
- The Core runtime calls only `resolvePendingApproval`, `disableActiveSessionCapability` or `disconnectSession`. It does not reconstruct arbitrary command names or payload dictionaries.
- Core and owned-runtime locks keep command submission under the same single owner as snapshot/media access and reject it with `notRunning` after teardown.
- Preparing an adapter ticket performs no Core submission. The H4.3f3 post-reply action enqueues it on a dedicated serial queue, and concurrent tickets never overlap submission.
- Core acceptance returns `awaitingCoreResult`, preserving Rust's event as final authority. Pre-Core rejection/failure produces only bounded typed details: `core-rejected`, `core-unavailable` or `core-failure`.
- Cancellation rejects new preparation. A ticket whose ack was already delivered but whose action arrives after cancellation emits correlated `agent-stopping` instead of silently losing work; already enqueued work is drained up to the caller's explicit deadline.
- Calling cancel-and-wait from the execution queue returns false instead of self-deadlocking. Invalid result construction terminally invalidates the adapter.

## TDD evidence

- RED: the focused target failed to compile because the typed Core action/submission, submission outcome and execution adapter did not exist.
- GREEN: seven adapter tests cover all six mappings, no execution before post-reply action, one-shot behavior, serial queueing, typed immediate results, cancel-before-action and draining already-enqueued work.
- Core-runtime and owned-runtime tests separately prove exact typed method routing and `notRunning` after stop.

## Verification

- `swift test --filter 'HostAgent(XPCCommand|CoreRuntime|OwnedCoreRuntime)'`: 49 tests, 0 failures.
- `swift test`: 663 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.

## Remaining boundary

- The adapter is not yet constructed by `HostAgentProcessRuntime`, injected into the listener or retained and drained by process lifetime teardown; the product selector remains fail closed with `commandService: nil`.
- Core `commandResult` events still enter the raw Core-event journal path. Safely replaying a completed result needs a native typed journal record with a new local sequence; reusing a retained Rust event ID would be rejected as a duplicate and synthetic ID namespaces would create an avoidable collision contract.
- Immediate adapter results are typed but not yet accepted by the boot-bound command service or published into the event journal.
- There is still no App command client, timeout/correlation owner or Home command availability transition.
- No App GUI, HostAgent process, SMAppService mutation, installation, deployment or real-device command was exercised.
