# H4.3f11 App-owned read-only Home command projection

## Outcome

- Gave the App lifecycle one stable H4.3f10 command presentation owner backed by the existing background activation owner.
- Projected bounded command progress/result state into the existing Home snapshot without enabling any background action callback.
- Added a second epoch/projection/peer coherence gate at the asynchronous App-model delivery boundary.

## Key evidence

- `AppDelegate` has exactly one lazy `HostAgentBackgroundHomeCommandPresentationOwner.makeProduct` composition and passes its existing `hostAgentBackgroundActivationOwner`; no reconnect, projection or command authority is duplicated.
- Activation updates and disable transitions explicitly refresh that owner. Its observer returns to the main queue and updates only a read-only presentation before refreshing Home.
- The pure read-only policy contains no submit/retry call or legacy Host dependency. It retains only a busy active action, bounded status/error copy and retryability; a routed view must match the current activation epoch, projection generation and exact Host/boot peer or it becomes unavailable.
- Approval busy state maps only to `isResolving`; session busy state maps exhaustively to the matching existing `HostSessionHomeAction`. Queued/success/failure text uses H4.3f9 bounded copy and raw Core/Agent detail is never rendered.
- Background approval/session snapshots still take their `allowsCommands` values from H4.3e4i's fixed-false read-only projection. `HomeView` retains no raw owner view/route, while App source has no call to the presentation owner's `submit` or `retry` methods.

## Test evidence

- Busy, accepted, unknown/retry and completed flows prove exact read-only active-action/status/error projection and immutable retry state.
- Missing activation and non-enabled readiness prove an otherwise busy command view fails closed at the App-model coherence gate.
- Submit/retry rejection proves typed owner failures become bounded product copy without exposing transport or raw error data.
- Source boundaries prove a single App composition, reuse of the activation owner, read-only Home mapping and absence of background action calls.

## Verification

- `swift test --filter 'HostAgentBackgroundHome(CommandPresentationOwner|SnapshotProjectionPolicy)Tests'`: 14 tests, 0 failures.
- `swift test --filter 'HostAgent(BackgroundHome(CommandPresentationOwner|CommandPolicy|SnapshotProjectionPolicy|ReadinessPresentationPolicy|RoutingPolicy)|BackgroundActivationOwner|XPCReconnectOwner|XPCSessionLifecycle|XPCCommandIntentOwner)Tests'`: 81 tests, 0 failures.
- `swift test`: 710 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check` and the scoped whitespace/secret audit were clean before final staging.

## Remaining boundary

- Background Home controls remain disabled and all real action callbacks still route only through the legacy path when legacy controls are enabled.
- Home has no retry control and App does not call command submit/retry; no real background command has been issued.
- H4.3f12 should freeze pure Home action routing by owner kind and exact visible connection target before a later step enables product controls.
- No wire schema, Host ABI, Rust, SMAppService, Hermes, root configuration or dependency changed; no App/Agent installation, deployment, push or real-device command was performed.
