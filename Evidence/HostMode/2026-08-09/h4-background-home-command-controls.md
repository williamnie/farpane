# H4.3f14 exact background Home controls and retry

## Outcome

- Enabled the six existing Home approval/session controls only from the exact coherent H4.3f9 action set.
- Replaced card-wide command availability with per-action Home eligibility.
- Added one explicit retry control for the exact retained background action and currently visible connection target.

## Key evidence

- The App-owned read-only command projection carries no operation closure. It exposes `availableActions` only while the current H4.3f10 view is coherent, idle, has no result and is not retryable or busy.
- Approval allow/reject and session disable-input/clipboard/audio/disconnect are represented by separate Home action sets. Home button state and each action handler independently require membership in the matching set.
- Session capability fields still describe visibility; action eligibility is a separate requirement, so a capability cannot accidentally authorize its command.
- Busy state exposes only `activeAction` for the existing “处理中” presentation and no new action. Any terminal result keeps new actions disabled until a coherent route replacement clears it.
- Retry eligibility requires the command's retained active action, a matching terminal result and both retry flags. The App additionally requires the corresponding approval or session card to remain visible before producing a retry snapshot.
- Home's retry callback carries only the visible connection ID. The H4.3f13 dispatcher rebuilds current visible targets and H4.3f12 rechecks the exact action, authoritative projection target, activation epoch and peer identity before H4.3f10 reuses the retained command ID.
- Legacy Home operations retain their existing per-action behavior and never receive a retry route.
- The obsolete “当前版本仅可查看，操作尚未接通” copy was removed now that the typed background command chain is product-wired.

## Test evidence

- Idle coherent presentation exposes all six exact actions; busy presentation exposes none and retains only the active action.
- Retryable disconnect exposes no fresh actions and exactly `.disconnect` as retry; a retry attempt returns to busy with no retry action.
- Completed terminal presentation exposes neither fresh actions nor retry, preventing an operation against a stale projection.
- Unavailable registration/health or missing route remains the all-empty unavailable projection.
- Source gates prove Home uses exact approval/session sets, owns only the connection-ID retry callback and does not consume raw command routes or the presentation owner.

## Verification

- `swift test --filter HostAgentBackgroundHomeCommandPresentationOwnerTests`: 12 tests, 0 failures.
- `swift test --filter HostAgentBackgroundHomeSnapshotProjectionPolicyTests`: 5 tests, 0 failures.
- `swift test --filter 'HostAgent(BackgroundHome(CommandPresentationOwner|CommandPolicy|SnapshotProjectionPolicy|ReadinessPresentationPolicy|RoutingPolicy)|BackgroundActivationOwner|XPCReconnectOwner|XPCSessionLifecycle|XPCCommandIntentOwner)Tests'`: 84 tests, 0 failures.
- `swift test`: 713 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check` and the scoped whitespace/secret audit were clean before final staging.

## Remaining boundary

- No real App/Agent process was launched and no background command was submitted through the product UI in this step.
- Two-machine approval, session capability revocation, disconnect and forced retry acceptance remain manual evidence; the user's controller machine is currently unavailable.
- The next automated step should add a product-composed smoke that drives a semantic Home request through queued acknowledgement and typed terminal projection without bypassing the real command owners.
- No wire schema, Host ABI, Rust, SMAppService, Hermes, root configuration or dependency changed; no installation, deployment or push was performed.
