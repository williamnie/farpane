# H2.3.2 Network backpressure IDR recovery

- Date: 2026-08-07 (Asia/Shanghai)
- Scope: Swift reaction to the existing Host Media ABI queue-full result
- ABI/schema impact: none

## Implemented boundary

- `HostControlError.requiresMediaKeyframeRecovery` is true only for `RDN_HOST_ERR_BACKPRESSURE`.
- Stale epoch and bad state remain expected route drops but do not request a keyframe.
- H2.3.2 originally used a locked, route-local weak pipeline reference to synchronously request a keyframe at the encoder callback boundary; a late old-route callback could not address the new AppDelegate pipeline.
- H2.3.3 subsequently preserved that route-local boundary but replaced the direct request with encoder-generation reset; current behavior is documented in `h2-encoder-reset.md`.
- Existing send-drop telemetry and adaptive FPS pressure remain authoritative; recovery does not increment accepted sends.

## Fresh focused verification

- `CoreBridgeContractTests.testOnlyEncodedQueueBackpressureRequiresKeyframeRecovery`: 1 passed, 0 failed.
- The same build compiled and linked the App target with the route-local callback integration.
- Existing real VideoToolbox H.264 and HEVC tests exercise `requestKeyframe()` and require keyframe plus parameter sets; the full fresh suite is recorded in the H2 progress report for this step.

## Boundary

This file preserves the H2.3.2 intermediate evidence. Its “no flush/generation gate” limitation is closed in H2.3.3 by `h2-encoder-reset.md`; a real congestion run and six-reason drop telemetry remain open.
