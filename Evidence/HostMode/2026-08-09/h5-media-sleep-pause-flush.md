# H5.1c resumable media sleep pause/flush seam

## Outcome

The HostAgent media path now has a package-internal, nonterminal sleep recovery owner around the existing `HostMediaPipelineRouteOwner`. Sleep admission claims a monotonic recovery epoch, rejects new route work, waits for already-admitted controls, stops the current desired route, and synchronously drains queued ScreenCaptureKit/VideoToolbox lifecycle work. The underlying route owner is not cancelled, so the process can recover without recreating its whole media owner.

Wake reopens ingress without replaying the pre-sleep capture/encoder configuration. If a route existed before sleep, the first replacement must carry either a newer connection epoch or a newer codec epoch. A display-revision-only replacement with the old codec epoch is rejected: every rebuilt `HostMediaPipeline` restarts its presentation time at zero, while Rust enforces monotonic PTS inside one codec epoch, so replaying the old epoch would make valid post-wake packets look stale.

## Failure and concurrency boundary

- `pauseAndFlushForSleep()` succeeds only after the route owner reports no desired route, no active route, and no pending lifecycle operation.
- New start/reconfigure/IDR/stop work is rejected while suspending. An already-admitted control is allowed to return before stop/flush begins.
- A remote stop matching the remembered pre-sleep route clears the fresh-route requirement; an idle Host can therefore wake without inventing a pipeline.
- A concurrent terminal cancellation waits for sleep draining, then seals the route owner exactly once. The sleep call cannot overwrite `cancelling/cancelled` with a late success.
- Recovery state and epoch are exposed only through the existing in-process HostAgent media snapshot. No Host ABI, XPC/wire schema, public VideoPipeline API, Rust bridge, or shared storage contract changed.

## Verification

- `HostMediaPipelineRouteOwnerTests`: 16 tests, 0 failures. Four new cases cover active-route drain and fresh-epoch recovery, idle sleep/wake, remote stop while suspended, and terminal cancellation racing a blocked encoder stop.
- `CoreBridgeContractTests`: 37 tests, 1 conditional built-core test skipped, 0 failures. Product source-order checks confirm HostAgent routes media controls and terminal teardown through the recovery owner.
- `swift test`: 731 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: passed before evidence finalization and is rerun before commit.

## Remaining boundary

- The seam is intentionally not connected to `NSWorkspace` sleep/wake notifications yet. No real system sleep, display re-enumeration, TCC transition, registration withdrawal/resume, or sleep-assertion lifecycle is claimed here.
- `resumeAfterWake()` only reopens ingress and, when necessary, waits for a fresh authoritative Core route. A future product adapter must not publish Host availability merely because ingress reopened; it must wait until display/TCC validation and the fresh media route have actually converged.
- No App/Agent was launched, installed, registered or deployed; no real product configuration, media log, or secret was read; nothing was pushed, and Hermes/CI/dependencies/databases were untouched.
