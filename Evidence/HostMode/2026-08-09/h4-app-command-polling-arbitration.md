# H4.3f7 App command intent / event polling arbitration

## Outcome

- Added a product-owned App command intent authority beside the existing snapshot-first session client and single event polling owner.
- Serialized command acceptance against event fetches, then restored authoritative polling while the terminal result remains pending.
- Retained retryable intent identity without exposing background Home commands yet.

## Key evidence

- The session lifecycle constructs the command owner only after the initial authoritative snapshot has been published and the one polling owner exists. A command cannot enter before the lifecycle is polling.
- Every attempt first pauses event polling. Scheduled work is cancelled immediately; an in-flight accepted fetch is allowed to publish and returns the client to `ready` before the pause completion permits command submission.
- Poll termination while a pause is pending rejects the pause before terminal delivery. Cancellation clears the pending pause callback and generation-gates late scheduled work or fetch replies.
- A strictly correlated queued acknowledgement moves the immutable intent to result waiting and resumes event polling after 100 ms. This bounded post-reply interval avoids racing the Agent handler's acknowledgement-first action and per-connection state restoration.
- `completed` clears the intent. `resultUnknown` and `resultTimedOut` retain the exact command ID, semantic name and connection ID; `retry` has no replacement parameters, so a fresh wire request can reuse only that same semantic intent under Agent dedupe.
- Invalid local request construction restores polling immediately without terminating the session. Pre-acceptance disconnect, timeout and invalid response preserve their recoverable lifecycle reason; an impossible arbitration transition fails closed as `invalidState`.
- Session termination claims and cancels the command owner before cancelling the client. Pending observers complete once with `cancelled`; retryable intent and late pause/client callbacks cannot cross a reconnect or identity-replacement epoch.
- No automatic command retry is performed. User intent remains required for a retry and no password, arbitrary payload, raw event JSON, secret, file or ambient configuration is retained.

## Test evidence

- Dedicated intent-owner tests cover pause-before-submit, accepted/resume/result ordering, immutable same-ID retry, invalid-request polling restoration, cancellation and fail-closed resume contradiction.
- Polling-owner tests cover scheduled pause, in-flight drain-before-pause, caller-owned resume delay and terminal rejection of a pending pause.
- Session lifecycle tests cover product composition, command arbitration, exact retained retry, cancellation/late callback rejection and recoverable pre-acceptance disconnect routing.

## Verification

- `swift test --filter 'HostAgentXPC(EventPollingOwner|CommandIntentOwner|SessionLifecycle)Tests'`: 27 tests, 0 failures.
- `swift test --filter 'HostAgentXPC(SnapshotClient|EventPollingOwner|CommandIntentOwner|SessionLifecycle|ReconnectOwner|WireCommand|SnapshotService|CommandService)Tests'`: 94 tests, 0 failures.
- `swift test`: 693 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.

## Remaining boundary

- The reconnect owner/background activation runtime does not yet expose the current session command seam or typed command availability. Home approval/session actions therefore remain disabled and cannot call this owner.
- A future product step must bind availability to the exact current projection epoch/peer identity and active connection ID, generate a fresh command ID for a new user intent, and present queued/terminal/retryable outcomes without falling back to legacy callbacks.
- No wire schema, Host ABI, Rust, SMAppService, Hermes, root configuration or dependency changed; no App/Agent installation, deployment, push or real-device action was performed.
