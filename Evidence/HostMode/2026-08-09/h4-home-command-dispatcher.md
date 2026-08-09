# H4.3f13 App main-actor Home command dispatcher

## Outcome

- Routed every real Home approval/session callback through the H4.3f12 owner-aware policy.
- Added one injected dispatcher that executes exactly the route-selected legacy, background submit or background retry operation.
- Preserved background Home controls as disabled; this step connects the safe path without making it user-invocable.

## Key evidence

- `RustDeskNativeApp` converts approval and session callbacks into the six typed semantic command actions and no longer calls the legacy handlers directly from those callbacks.
- Dispatch is rejected off the main thread. On the main actor, the App rebuilds current legacy/background Home snapshots, visible connection IDs and enabled actions at click time instead of trusting stale callback context.
- The existing H4.3f12 policy still owns all owner selection and correlation: legacy runtime availability, background activation/projection epoch, exact peer identity, command presentation and authoritative target must agree before a route exists.
- `HostAgentHomeCommandDispatchPolicy` has only four exhaustive outcomes: no operation, one legacy operation, one background submit or one background retry. A false result is returned directly and never triggers a fallback owner.
- Background retry performs one final active-action comparison before invoking the presentation owner. It cannot replace the retained command semantic or target.
- Legacy handlers now have explicit legacy names and Boolean acceptance results, so a rejected stale/duplicate request remains observable to the dispatcher without inventing success.
- The background H4.2ab/H4.3f11 Home snapshots still expose `allowsCommands=false`. The App derives `enabledActions` only from the same visible snapshot flags and capability fields, so all background perform routes remain `.none` in the current product UI.
- `HomeView` still knows neither the raw command route nor presentation owner, and it has no retry callback/button.

## Test evidence

- The injected dispatch test proves `.none` executes nothing, legacy executes only legacy, background executes only submit even when that operation rejects, and retry executes only retry.
- Source boundaries prove the App owns the single route/dispatch composition while CoreBridge routing/dispatch policies import no AppKit, SwiftUI, Host client, ServiceManagement or ambient persistence.
- Existing routing tests continue to reject wrong owners, stale/foreign targets, unavailable actions, busy commands and invalid retry state.

## Verification

- `swift test --filter HostAgentBackgroundHomeCommandPresentationOwnerTests`: 12 tests, 0 failures.
- `swift test --filter 'HostAgent(BackgroundHome(CommandPresentationOwner|CommandPolicy|SnapshotProjectionPolicy|ReadinessPresentationPolicy|RoutingPolicy)|BackgroundActivationOwner|XPCReconnectOwner|XPCSessionLifecycle|XPCCommandIntentOwner)Tests'`: 84 tests, 0 failures.
- `swift test`: 713 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check` and the scoped whitespace/secret audit were clean before final staging.

## Remaining boundary

- Background approval/session actions remain disabled by design; no real background command was submitted in this step.
- Home has no retry control, so the retry request seam is not yet user-invocable.
- H4.3f14 should derive background Home `allowsCommands` from the exact H4.3f9 available actions and add an explicit retry affordance tied to the same action and connection ID.
- No wire schema, Host ABI, Rust, SMAppService, Hermes, root configuration or dependency changed; no App/Agent installation, deployment, push or real-device command was performed.
