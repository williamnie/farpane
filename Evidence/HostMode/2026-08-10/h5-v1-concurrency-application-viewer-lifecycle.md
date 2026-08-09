# H5.3y App Viewer lifecycle evidence composition

## Outcome

- Extended the H5.3x App process owner with one serialized Viewer session state machine and process-local monotonic session epochs.
- Connected `starting`, Rust-authoritative `authenticatedStreaming`, terminal disconnect, same-epoch recovery and App-owned stop edges to the real live Viewer path.
- Kept all evidence calls observation-only: configuration, clocks, append failure, stale callback, duplicate callback or unavailable evidence cannot alter connection, UI, retry or teardown behavior.
- Upgraded the rerunnable V1 audit to `application-viewer-lifecycle-implemented` while leaving Host observations, HostAgent composition, actual Viewer auto-recovery, the five-scenario validator and live acceptance open.

## Viewer state authority

The evidence owner allocates a positive, process-local `sessionEpoch` only after a strict `starting` append succeeds. An active session is unique; a second begin, stale epoch, duplicate state or callback after stop is rejected without writing.

The normalized transition authority is:

- accepted live Viewer attempt → `starting`, generation 0;
- exact Rust Core `.streaming` for the current epoch → `authenticatedStreaming`, generation 0;
- terminal Core state after streaming → `disconnected`, generation 1;
- exact same-epoch `.streaming` after that disconnect → `recoveredStreaming`, preserving generation 1;
- each later recovered-stream disconnect increments generation exactly once;
- App-owned teardown → `stopped`, generation 0 and releases the active epoch;
- terminal Core state before streaming → `stopped`, not a fabricated disconnect/recovery.

All transition preparation, writer admission and state commit are serialized. The owner commits epoch/generation/state only after the JSONL append and sync succeed. A write failure drops the writer, clears the active session and moves evidence to `unavailable`; the Viewer continues independently.

## Product composition

`startLive` begins evidence before constructing/connecting the Core client, and a `defer` closes the session if client creation or `connect` throws. The exact epoch is captured by the Core callback and cannot be replaced by a later attempt.

Only these real product edges are mapped:

- Core `.streaming` → `observeViewerStreaming`;
- Core `passwordRequired | authenticationFailed | disconnected | error` → `observeViewerTerminal`;
- `showHomeUI` and App `finish` → `stopViewerLifecycleEvidence` before `coreClient.disconnect()`.

No peer ID, password, server configuration, packet or UI text enters the evidence API. Fixture playback is excluded because it is not a remote Viewer session.

## Recovery boundary

The owner can recognize a real same-epoch recovery, but the current App treats terminal Core state as terminal, returns to Home and closes that Viewer session. Therefore this step does **not** claim Viewer auto-recovery or the `dualDisconnectRecover` scenario. A later product recovery step must keep one exact session alive across disconnect and receive a genuine subsequent Core `.streaming` callback before `recoveredStreaming` can appear in live evidence.

## Verification

- Focused owner tests: 9/9, covering exact epochs/generations, pre-stream terminal, same-epoch recovery, two disconnect generations, explicit stop, stale callbacks, 64 concurrent streaming callbacks and evidence-only failure.
- Focused App composition contract tests: 3/3.
- Focused audit: 1/1; `application-viewer-lifecycle-implemented`, 27/27 evidence checks and 49/49 source anchors.
- Full ScriptTests: 96/96.
- Full Swift tests: 875/875 with 4 expected built-core skips.
- arm64 Release build, Python compilation and `git diff --check`: passed.

## Next boundary

The App file still has no authoritative Host observation. The next automatic step is to bind background Host identity/config revision and normalized ready/active/disconnected state to the same App evidence owner without changing Host XPC or media ABI. HostAgent process evidence, a five-scenario validator and installed two-machine execution remain later work.
