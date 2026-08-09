# H4.3f9 pure Home command presentation/action policy

## Outcome

- Added a toolkit-independent Home policy for the epoch-bound background command route.
- Froze exact six-action availability, fresh-command creation, immutable retry and bounded result copy before any App/Home wiring.
- Kept the legacy in-process Host and the background Agent command owners isolated.

## Key evidence

- Availability independently requires a monitoring activation epoch, enabled authoritative registration, no readiness failure, matching readiness/projection generation and derived runtime evidence, an available typed projection, plus an exact route activation epoch, projection generation and peer identity.
- Idle pending approval produces only approve/reject targets for its exact connection ID. Idle active session produces disconnect plus only capability revocations whose complete capability set is still active.
- New product submissions create a lowercase canonical UUID only after the requested action is proven available. The generated immutable intent maps one semantic action to the exact projected connection target.
- Pausing/awaiting acceptance, queued/awaiting result and retryable states expose no new action targets. Retry returns only the existing background route, so the lower command owner remains the sole authority for the retained command ID/name/target.
- Result presentation accepts the complete route-bound submission. A queued ack must match its command ID plus exact Host/agent-boot identity; a final typed result must match its command ID. It distinguishes queued, success, rejected, unsupported, error, timeout/unknown, cancellation and invalid channel outcomes without rendering raw result detail.
- Source assertions prove the policy imports no product UI framework, legacy Host client, preferences or ServiceManagement and calls neither submit nor retry. `RustDeskNativeApp` and `HomeView` still contain no new policy/action consumer.

## Test evidence

- Coherent idle projection coverage proves all six actions, exact approval/session targets, capability filtering and distinct product UUIDs.
- Fail-closed coverage varies activation epoch, projection generation, peer identity, availability, command ID and semantic target.
- Command-state coverage proves submission/acceptance, queued and retryable presentation, and that retry cannot create a replacement command.
- Result coverage proves correlation, bounded typed copy, retry classification and raw-detail non-disclosure.

## Verification

- `swift test --filter HostAgentBackgroundHomeCommandPolicyTests`: 5 tests, 0 failures.
- `swift test --filter 'HostAgent(BackgroundHomeCommandPolicy|BackgroundHomeSnapshotProjectionPolicy|BackgroundActivationOwner|XPCReconnectOwner|XPCSessionLifecycle|XPCCommandIntentOwner)Tests'`: 58 tests, 0 failures.
- `swift test`: final 8 consecutive reruns each executed 701 tests with 4 environment-gated skips and 0 failures. One preceding full-suite run reported one failure after its detailed output had already been truncated; it did not reproduce in 5 serial reruns or 3 reruns alongside the script suite, and the 5-test focused/58-test related suites remained green.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: clean before final scoped staging.

## Remaining boundary

- No App-owned command presentation state exists yet; the pure policy does not observe activation changes or call submit/retry.
- `RustDeskNativeApp` and `HomeView` remain unchanged, so background approval/session controls are still disabled and still cannot fall through to legacy callbacks.
- H4.3f10 should add an App-owned, epoch-aware command presentation owner that serializes policy refresh, submit/retry and correlated callback state before real Home action wiring.
- No wire schema, Host ABI, Rust, SMAppService, Hermes, root configuration or dependency changed; no App/Agent installation, deployment, push or real-device command was performed.
