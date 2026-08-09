# H4.3f4 Snapshot-gated Data-only command XPC session

## Outcome

- Extended the inherited Clang XPC surface with one Data-only semantic command selector.
- Integrated the H4.3f3 command service into the existing per-connection handshake/snapshot/event state machine with snapshot-first gating, command-specific rate limiting and reply-before-action ordering.
- Kept the product listener fail closed by explicitly injecting no command service until the process-owned execution and result-journal composition exists.

## Key evidence

- `RDNHostAgentXPCCommandService` inherits the existing event service and adds only `submitCommandWithRequestData:reply:` with nonnull `NSData` request and nullable `NSData` response. No collection, URL, error, proxy or decoded arbitrary-object parameter was added.
- The exported interface now uses the command protocol while existing App snapshot/event transport continues to consume inherited methods on the same connection.
- A command must decode strictly and match the negotiated wire version plus exact Host instance and Agent boot identity while the session is `snapshotReady`. Handshake-only, incompatible, foreign, malformed, out-of-order and concurrent calls reply nil exactly once.
- Command attempts have an independent 100 ms monotonic per-connection limit. Ineligible calls are rejected by a side-effect-free precheck before reading the clock or touching the boot-bound admission authority.
- The handler keeps the connection in `submittingCommand` while it invokes the reply block and the one-shot post-reply action. It restores the exact prior snapshot cursor only after the action returns, preventing reentrant snapshot, event or command work from overtaking the queued acknowledgement.
- A direct ordering test observes `reply`, reentrant rejection and execution in that exact order. A real anonymous XPC test completes handshake, snapshot, event and correlated queued command acknowledgement.
- The product listener currently passes `commandService: nil`; the selector therefore remains unavailable in the future product runtime rather than routing to legacy in-process control or fabricating completion.

## TDD evidence

- RED: the focused test target failed to compile because the command protocol, selector name, handler injection and `submitCommand` entrypoint did not exist.
- The first GREEN attempt exposed an empty monotonic-clock fixture because pre-snapshot command rejection read the clock too early. The handler was corrected to mirror the existing snapshot/event side-effect-free eligibility precheck before rate-limit reservation.
- GREEN: fifteen focused snapshot-session tests cover the inherited interface, snapshot gate, identity rejection, reply-before-action order, reentry rejection, independent rate limit, exact cursor restoration and real anonymous XPC round-trip.

## Verification

- `swift test --filter HostAgentXPCSnapshotServiceTests`: 15 tests, 0 failures.
- `swift test --filter 'HostAgentXPC(SnapshotService|SnapshotClient|HandshakeAdmissionLifecycle|CommandService|CommandAdmissionAuthority|WireCommand)Tests'`: 70 tests, 0 failures.
- `swift test`: 654 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.

## Remaining boundary

- The listener does not yet own or inject a process-lifetime command service. Cross-connection retries therefore cannot yet exercise the shared boot-bound dedupe authority through the product listener.
- There is no adapter from the six typed commands to `HostControlClient`, no serial execution queue and no publication of final command results into the process-owned event journal.
- The App client has no command request/timeout/correlation owner, and background approval/session actions remain disabled in Home.
- No App GUI, HostAgent process, SMAppService mutation, installation, deployment or real-device command was exercised.
