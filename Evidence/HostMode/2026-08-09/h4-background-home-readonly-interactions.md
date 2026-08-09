# H4.2ab Background approval/session read-only Home presentation

## Outcome

- Home now presents pending approval and active session cards from the same coherent, typed background projection used for readiness and identity.
- Background approval/session cards are explicitly read-only. Two approval actions and four session actions are disabled, and every action handler independently rejects a snapshot whose `allowsCommands` is false.
- Legacy in-process Host cards preserve their existing command availability. Media diagnostics remain outside this projection boundary.

## Key evidence

- `HostAgentBackgroundHomeSnapshotProjectionPolicy` carries only validated wire approval/session values and fixes both background command-availability fields to false.
- `RustDeskNativeApp` maps background values without consulting legacy `hostSnapshot`; remote metadata remains labelled unverified and unsupported capabilities/transport fail closed.
- Background approval expiry is rendered as an absolute time because the background projection does not publish a per-second UI countdown.
- `HomeView` gates both button state and callbacks on the matching approval/session command-availability field.
- The implementation does not add an XPC selector, modify a wire schema or Host ABI, touch ServiceManagement state, or expose a temporary password.

## TDD evidence

- RED: the new projection test initially failed to compile because the background presentation had no typed approval/session payload or independent command-availability fields.
- GREEN: the focused policy/source integration suite passes with the typed payload projection and fail-closed Home gates.

## Verification

- `swift test --filter HostAgentBackgroundHomeSnapshotProjectionPolicyTests`: 5 tests, 0 failures.
- `swift test --filter 'HostAgentBackground(HomeSnapshotProjectionPolicy|HomeReadinessPresentationPolicy|ActivationOwner|ProjectionAuthority|HealthAuthority)Tests|HostApplicationLifecyclePolicyTests'`: 55 tests, 0 failures.
- `swift test`: 617 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: clean.

## Remaining boundary

- Background approval/session actions remain unavailable until H4.3 defines a strict typed command request/result contract with correlation, identity binding and dedupe semantics.
- No App GUI, HostAgent process, SMAppService mutation, installation, deployment, or real-device command flow was exercised in this automatic step.
