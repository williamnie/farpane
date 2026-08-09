# H4.3f8 epoch-bound background command route

## Outcome

- Lifted the typed command seam from one session lifecycle through the active reconnect owner and product background activation runtime.
- Added a capability token bound to the current activation, coherent projection and reconnect-session epochs.
- Kept the application/Home action surface disabled while freezing exact target and stale-callback policy for the next step.

## Key evidence

- A reconnect command route exists only after the projection authority accepts the current session's initial snapshot. It carries the exact peer build/Host/boot identity and monotonic reconnect session generation.
- Disconnect, projection rejection, backoff, cancellation and replacement clear the route before another session can become active. Submit/retry recheck route equality against the currently owned session, so an old token cannot address a replacement lifecycle.
- The background route adds activation epoch and coherent projection generation. Availability requires a monitoring runtime, available typed projection, matching peer identity and a non-terminal command-intent state.
- Each new submission rechecks low-level idle state and the current typed projection. Approve/reject may target only the exact pending-approval connection ID; input, clipboard, audio and disconnect may target only the exact active-session connection ID.
- Retry has no replacement intent. It is admitted only when the current low-level state retains a retryable intent whose semantic name and connection target still match the same projection-bound route.
- Command callbacks share the activation delivery gate. If disable, termination or epoch replacement wins first, the observer receives one terminal cancellation; any later callback is dropped by the one-shot relay.
- The product runtime composition forwards availability, submit and retry only to its owned reconnect owner. Default protocol behavior remains fail-closed for injected runtimes that do not implement commands.
- `RustDeskNativeApp` still contains no background command-route reference. No Home button, legacy callback, automatic command-ID generation, automatic retry or user-facing result presentation is enabled in this step.

## Test evidence

- Reconnect tests cover unavailable-before-snapshot, active route identity/session generation, exact active-session forwarding, route withdrawal on disconnect, stale-route rejection and replacement-session retry routing.
- Activation tests cover coherent-projection gating, activation/projection/reconnect token composition, exact pending/session target checks, retained retry routing, disable cancellation and late callback suppression.
- Product source assertions prove the App/Home layer has not consumed the new route.

## Verification

- `swift test --filter 'HostAgent(XPCReconnectOwner|BackgroundActivationOwner)Tests'`: 30 tests, 0 failures.
- `swift test --filter 'HostAgent(BackgroundActivationOwner|BackgroundProjectionAuthority|BackgroundHealthAuthority|XPCReconnectOwner|XPCSessionLifecycle|XPCCommandIntentOwner|XPCEventPollingOwner|XPCSnapshotClient)Tests'`: 97 tests, 0 failures.
- `swift test`: 696 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: clean before final scoped staging.

## Remaining boundary

- Home still projects `allowsCommands = false` for background approval/session data and does not create or retain command presentation state.
- The next step must define action availability and result presentation without falling back to legacy Host callbacks, then wire the AppDelegate/Home boundary under MainActor.
- No wire schema, Host ABI, Rust, SMAppService, Hermes, root configuration or dependency changed; no App/Agent installation, deployment, push or real-device command was performed.
