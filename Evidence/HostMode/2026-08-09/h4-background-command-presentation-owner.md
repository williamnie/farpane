# H4.3f10 epoch-aware App command presentation owner

## Outcome

- Added a toolkit-independent App-side owner for the pure Home command policy and the existing background activation command seam.
- Serialized explicit refresh, fresh submit, immutable retry and correlated callback presentation behind one owner.
- Kept construction inert and left the real App/Home controls untouched.

## Key evidence

- The product factory obtains activation phase/projection, current command availability, submit and retry only from the same `HostAgentBackgroundActivationOwner`; it does not create a second reconnect, projection or command authority.
- One recursive delivery gate serializes refresh, operation transition and callback publication. A separate state lock protects monotonic view/attempt generations, and an active transition rejects reentrant or overlapping operations.
- Fresh submit delegates command/target/ID creation to H4.3f9. Retry retains the complete original route and intent, checks its action against the retryable result and never calls the command ID factory again.
- Every callback is correlated to the complete attempt. `accepted` must occur exactly once with matching busy state; completion/unknown/timeout must follow it. Terminal command availability must independently agree with the exact route/action and terminal class.
- Route replacement clears the old attempt, result and route-scoped failure. A late callback from the old observer cannot publish into the new route.
- Foreign ACK, duplicate or out-of-order callback, contradictory availability, and rejected submit/retry fail closed for the current route. Refresh alone cannot unlock it; a different coherent route can.
- Source-boundary assertions prove the owner imports no AppKit/SwiftUI, legacy Host client, preferences or ServiceManagement. `RustDeskNativeApp` and `HomeView` still do not construct or consume it.

## Test evidence

- Refresh/submit coverage proves exact intent creation, queued/completed result projection, monotonic publication and rejection of reentrant submit.
- Retry coverage proves the original command ID/name/target are retained across result-unknown retry and successful completion.
- Route replacement coverage proves a new epoch clears prior state and a late old observer cannot mutate the new presentation.
- Fail-closed coverage proves foreign ACK, terminal-before-accepted, duplicate accepted, submit rejection and retry rejection cannot expose an actionable command.
- Product-boundary coverage proves construction is inert and no real App/Home owner or action callback was added.

## Verification

- `swift test --filter HostAgentBackgroundHomeCommandPresentationOwnerTests`: 8 tests, 0 failures.
- `swift test --filter 'HostAgent(BackgroundHomeCommandPresentationOwner|BackgroundHomeCommandPolicy|BackgroundHomeSnapshotProjectionPolicy|BackgroundActivationOwner|XPCReconnectOwner|XPCSessionLifecycle|XPCCommandIntentOwner)Tests'`: 66 tests, 0 failures.
- `swift test`: 709 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check` and the scoped whitespace/secret audit were clean before final staging.

## Remaining boundary

- The real App lifecycle does not yet retain this owner, and Home has no read-only command/result projection.
- Background Home action callbacks remain disabled; no command was submitted by the product UI and legacy callbacks remain isolated.
- H4.3f11 should give the App lifecycle one stable presentation owner and project its read-only state into the Home model while keeping real action callbacks disabled for a later bounded step.
- No wire schema, Host ABI, Rust, SMAppService, Hermes, root configuration or dependency changed; no App/Agent installation, deployment, push or real-device command was performed.
