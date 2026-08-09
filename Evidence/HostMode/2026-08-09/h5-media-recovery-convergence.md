# H5.1d fresh media route recovery convergence

## Outcome

Post-wake media recovery no longer treats an accepted asynchronous `reconfigure` as an active capture/encoder route. The package-internal recovery owner retains the exact previous and candidate route identities while the existing `HostMediaPipelineRouteOwner` is starting ScreenCaptureKit and VideoToolbox, then exposes a sanitized `pending | converged | failed | unavailable` convergence result to the HostAgent product boundary.

Convergence requires the underlying route owner to have zero pending lifecycle operations and to report the exact candidate as both desired and active. If queued work drains without that exact active route, recovery becomes terminal failed. This closes the gap where a ScreenCaptureKit permission/start error could otherwise allow a future sleep/wake adapter to resume registration and outward availability too early.

## Recovery and race boundary

- `schedulingFreshRoute` and `rebuildingFreshRoute` remain externally `rebuildingFreshRoute`; the exact candidate is retained in the in-process snapshot.
- A candidate whose start is still blocked returns `pending`, even though `reconfigure` was accepted.
- An exact active candidate with no pending operation returns `converged` and only then returns the media owner to `active`.
- A start failure that leaves no exact desired/active route returns `failed` and rejects IDR/control work.
- A matching remote stop during candidate startup transitions through `stoppingFreshRoute`; it converges only after both desired and active routes are empty, allowing the Host to become ready without fabricating a media pipeline.
- Concurrent state replacement/cancellation cannot be overwritten by a stale route snapshot because each poll rechecks the exact transition before mutating state.

## Verification

- `HostMediaPipelineRouteOwnerTests`: 18 tests, 0 failures. New coverage holds the second pipeline at asynchronous start, proves accepted-is-not-active, validates exact success convergence, validates start-failure fail-closed behavior, and validates remote stop during recovery.
- `CoreBridgeContractTests`: 37 tests, 1 conditional built-core test skipped, 0 failures. Product source contract confirms HostAgent exposes the recovery convergence seam.
- `swift test`: 733 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: passed before evidence finalization and is rerun before commit.

## Remaining boundary

- No process-owned timer currently polls this convergence result, and the H5.1b recovery-order owner is still not constructed by the HostAgent product composition.
- No `NSWorkspace` sleep/wake notification is registered. Display enumeration, TCC revalidation, Rendezvous withdrawal/resume, and sleep-assertion release still need real product operations before notifications can be admitted safely.
- The current Rust Host surface has no sleep-specific registration/assertion operation. This step does not add or simulate one and therefore does not claim a complete sleep/wake cycle.
- No App/Agent was launched, installed, registered or deployed; no real product configuration, media log, or secret was read; nothing was pushed, and Hermes/CI/dependencies/databases were untouched.
