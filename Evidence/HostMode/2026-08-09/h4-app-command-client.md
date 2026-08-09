# H4.3f6 App-side typed command client

## Outcome

- Extended the existing snapshot-first App XPC client and its single connection transport with one typed semantic command submission seam.
- Added strict queued-ack correlation followed by terminal command-result correlation from the same authoritative event stream.
- Kept command submission inert at the product lifecycle/UI boundary; background Home actions remain disabled until polling coordination and intent ownership are composed.

## Key evidence

- Commands can start only from the exact `ready(peer,lastEventID)` state after compatible handshake and authoritative snapshot. The request reuses the negotiated wire version and exact Host/boot identity; the caller supplies a bounded semantic name, current connection ID and retry-stable command ID while every attempt receives a fresh request UUID.
- The same `NSXPCConnection` transport invokes the inherited Data-only command selector. A second command, event fetch or non-ready call cannot replace the in-flight request.
- The client accepts only a strictly decoded queued response whose request, command, wire, Host and boot identity correlate with the exact request. Nil, malformed, foreign or late acknowledgement fails the session and invalidates transport once.
- Queued acknowledgement is an observable non-terminal result. The main client immediately returns to the unchanged ready event cursor while its orthogonal command state waits for the terminal typed `commandResult`, allowing the existing event fetch path to continue.
- A matching terminal result is delivered only after its containing event batch has been delivered. If the batch requires authoritative resnapshot, snapshot delivery occurs first and command completion follows; a gap/resnapshot without the result reports retryable `resultUnknown`.
- Acceptance has the existing five-second request timeout and is connection-terminal because execution is ambiguous. An accepted command has a separate 30-second result timeout that clears only the pending command and leaves the snapshot/event session ready, so the caller may retry with the same command ID under Agent dedupe.
- Cancellation before acceptance reports `cancelled`; connection loss before acceptance reports `disconnected`; loss after queued acceptance reports `resultUnknown`. All pending callbacks are one-shot and late reply/timeout/event delivery cannot revive them.
- The client keeps no password, arbitrary payload, raw event JSON, file, UserDefaults or log record. It uses only the existing six typed command names and bounded wire documents.

## TDD evidence

- RED: the focused target failed to compile because the snapshot client had no command transport method, command state, observer result type, submission API or test transport support.
- GREEN: five new client tests cover exact request construction, duplicate rejection, correlated ack/result ordering, authoritative resnapshot ordering, malformed/late ack, acceptance/result timeouts, cancellation, disconnect-after-acceptance and retryable unknown result.
- The anonymous XPC test now exercises handshake -> snapshot -> command queued ack -> typed result publication -> event fetch -> correlated completion through the real Objective-C protocol surface.

## Verification

- `swift test --filter HostAgentXPCSnapshotClientTests`: 19 tests, 0 failures.
- `swift test --filter 'HostAgentXPC(SnapshotClient|EventPollingOwner|SessionLifecycle|ReconnectOwner|WireCommand|SnapshotService|CommandService)Tests'`: 81 tests, 0 failures.
- `swift test`: 680 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.

## Remaining boundary

- Product `HostAgentXPCSessionLifecycle` still owns automatic event polling without a command-aware pause/resume arbiter. No product code calls `submitCommand`, avoiding a race where polling could attempt another selector during command acceptance.
- There is no App pending-intent owner, automatic same-ID retry policy, Home command availability transition or user-facing accepted/result/error presentation.
- Password and other secret-bearing commands remain outside this wire surface.
- No wire schema, Host ABI, Rust, SMAppService, Hermes, root configuration or dependency changed; no App/Agent installation, deployment, push or real-device command was performed.
