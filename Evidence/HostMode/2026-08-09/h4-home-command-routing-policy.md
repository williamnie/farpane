# H4.3f12 owner-aware pure Home command routing

## Outcome

- Added a pure owner-aware routing boundary for future Home approval, session and retry callbacks.
- Froze exact visible-action/connection targeting and background epoch/projection correlation before product callback wiring.
- Made an invalid background request terminal `.none`; it cannot fall through to the legacy Host.

## Key evidence

- Owner authority is an explicit mutually exclusive unavailable/legacy/background value. The route policy never infers a fallback owner from missing background state.
- Home context carries exact visible approval/session connection IDs plus only the action set that is currently enabled. Disabled/hidden actions, empty/foreign IDs and action/target type crossings fail closed.
- Legacy accepts only a visible perform request while legacy command availability is true; retry is not invented for the old owner.
- Background independently reconciles enabled monitoring readiness, runtime/projection generation, activation epoch and exact peer identity with the command route before reading the authoritative payload target.
- A fresh background action requires no owner failure/result, idle command state and membership in H4.3f9 available actions. A terminal result blocks a new command until a route replacement clears it.
- Retry requires matching command/result action, terminal retryable result, exact visible and projected target, and no busy state. Its route carries only semantic retry; the lower owner remains responsible for the retained command ID/name/target.
- The policy imports no AppKit/SwiftUI or legacy Host client and calls no command owner. Source assertions prove App/Home still do not consume the new route.

## Test evidence

- All six exact actions route independently to background and legacy only under their explicit owner.
- Wrong owner, disabled legacy commands, retry on legacy, hidden action, wrong target type, missing activation and unavailable owner all return `.none`.
- Background busy state rejects perform/retry; result-unknown enables only exact retry; wrong retry target and fresh perform remain rejected.
- Completed terminal result blocks a fresh command, while a new coherent activation epoch clears it and restores routing.

## Verification

- `swift test --filter HostAgentBackgroundHomeCommandPresentationOwnerTests`: 11 tests, 0 failures.
- `swift test --filter 'HostAgent(BackgroundHome(CommandPresentationOwner|CommandPolicy|SnapshotProjectionPolicy|ReadinessPresentationPolicy|RoutingPolicy)|BackgroundActivationOwner|XPCReconnectOwner|XPCSessionLifecycle|XPCCommandIntentOwner)Tests'`: 83 tests, 0 failures.
- `swift test`: 712 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check` and the scoped whitespace/secret audit were clean before final staging.

## Remaining boundary

- `RustDeskNativeApp` and `HomeView` do not yet consume this policy; existing real callbacks and background `allowsCommands=false` remain unchanged.
- App has no background retry callback and no product call to the background presentation owner's submit/retry methods.
- H4.3f13 should build one main-actor dispatcher that routes every real Home command through this policy while still leaving background controls disabled.
- No wire schema, Host ABI, Rust, SMAppService, Hermes, root configuration or dependency changed; no App/Agent installation, deployment, push or real-device command was performed.
