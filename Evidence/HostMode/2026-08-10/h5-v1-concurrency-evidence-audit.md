# H5.3v V1 coexistence evidence authority audit

## Outcome

- Added `Scripts/audit-host-v1-concurrency-evidence.py` as a rerunnable, fail-closed checkpoint for the five §18/§20.3 V1 Host/Viewer coexistence cases.
- Confirmed that process/config isolation and H5.3u item-10 resource overlap are code-ready, but the current evidence cannot prove the required cross-role ordering, dual-role recovery or App-restart Host ID continuity.
- Froze the minimum timestamped cross-process lifecycle evidence contract before adding a writer or five-result manifest validator. H5.3w implemented the strict writer/schema, H5.3x connected App process start/termination, and H5.3y connected exact Viewer session/Core/App teardown edges; Host observations, HostAgent composition, actual Viewer auto-recovery and the validator remain open.
- No product behavior, Host/Media/XPC ABI, wire schema, Rust, Hermes, configuration, credentials or external state changed.

## Current authority and gap

| Area | Current authority | Why it is insufficient for the five-case matrix |
|---|---|---|
| Process/config isolation | Exact `--host-agent` process mode, separate Rust config root, App Viewer process, canonical bootstrap and single-writer lease | Proves separation and code path, not a live ordered scenario |
| Host lifecycle | Runtime-state schema v2 has contiguous sequence, wall/boot-monotonic time, ready/registration, authenticated count and media route/pipeline state | Contains no Viewer lifecycle or App/Agent process-start identity |
| Viewer lifecycle | Viewer report binds exact process/build and the overall measurement/presentation window | `coreStateTransitions` is an array of strings without per-transition wall or monotonic timestamps |
| Resource overlap | H5.3t/H5.3u prove `host-ready-viewer` and `host-viewer-dual` full-window state/resource budgets | Two simultaneous states cannot prove Viewer-before-inbound or Host-before-Viewer ordering; the pair explicitly keeps `v1ConcurrencyRecoveryMatrixComplete=false` |
| Recovery | Host recovery evidence binds sleep/wake, network-path and display-reconfigure completion to Host/build digests | It has no Viewer disconnect/recovery event and only completes §15.2 item 7 |
| XPC identity continuity | Reconnect sessions carry the previous Host/Agent identity and reject replacement inside one App process | The previous identity is held in memory; a fresh App process has no bound before/after App-lifetime evidence |
| App termination | App termination cancels its background monitoring client; unregister remains a separate explicit typed mutation | Source structure is not installed-process evidence that Agent PID/start identity and Host ID remain stable across two App lifetimes |

H5.3w provides a default-off timestamped Host/Viewer lifecycle writer with separate per-process files, domain-separated identity digests, strict role/event shapes and terminal lifecycle ordering. H5.3x gives the App process one best-effort owner that derives exact kernel process-start identity plus packaged build identity, then records start/termination. H5.3y adds serialized Viewer epochs and maps only real Core streaming/terminal plus App teardown edges. The current App still closes the session on terminal Core state, so same-epoch recovery is supported by the owner but not produced by current product behavior. App Host observations and HostAgent product composition remain unconnected. The repository still contains no five-scenario validator or passing V1 concurrency result.

## Frozen scenario contract

The future aggregate must contain exactly these five independently passing ordered scenarios:

1. `hostReadyThenOutboundViewer`: Host ready with zero inbound sessions → Viewer authenticated/streaming → Host remains ready with zero inbound sessions.
2. `viewerThenInboundHost`: Viewer authenticated/streaming → Host accepts inbound authentication → both media roles active.
3. `activeHostViewerStartStop`: Host inbound media active → Viewer starts and streams → Viewer stops → Host inbound media remains active.
4. `dualDisconnectRecover`: both media roles active → both disconnected → Host and Viewer each prove recovery → both active again.
5. `appRestartStableHostID`: first App observes ready Host → first App process terminates → distinct second App process starts → second App observes the same Host scope while the same HostAgent process-start identity remains active.

Every event needs wall and boot-monotonic time, a contiguous per-process sequence, exact role PID/process-start identity, Agent boot/config revision, and domain-separated Host/build digests. Credentials, peer IDs, server configuration and media payloads are forbidden. The aggregate must bind five unique safe relative sources by SHA-256, require one machine/architecture/macOS/build scope and publish without overwrite.

Passing H5.3u results may be reused only as resource authority for the matching cases; they cannot substitute for lifecycle ordering.

## Forbidden inference

- An item-10 overlap pair is not the complete V1 matrix.
- Two active snapshots are not proof of which role started first.
- Untimed Viewer transition strings are not ordering proof.
- Host-only recovery is not dual-role recovery.
- Same-process XPC reconnect is not App-restart evidence.
- Showing the same Host ID twice is insufficient without two distinct App lifetimes and stable HostAgent process identity.
- Process liveness or window visibility is not session-state authority.

## Verification boundary

After H5.3y, the audit emits `status=application-viewer-lifecycle-implemented` only while the writer, App process/Viewer owner composition, current authorities and remaining gaps match the repository. It intentionally claims neither Viewer recovery nor a V1 matrix pass.

The next safe automatic step is App Host observation composition with exact background Host identity/config revision. The five-result manifest validator comes only after App and HostAgent writers are connected to authoritative lifecycle events. Installed App/Agent and two-machine execution remain a later manual checkpoint.

Fresh verification completed with focused owner tests 9/9, App composition contract tests 3/3 and focused audit 1/1; full ScriptTests 96/96; Swift tests 875/875 (4 expected built-core skips); an arm64 Release build; Python compilation; and `git diff --check`. The audit reports 27/27 evidence checks and 49/49 source anchors.
