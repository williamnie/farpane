# H5.3v V1 coexistence evidence authority audit

## Outcome

- Added `Scripts/audit-host-v1-concurrency-evidence.py` as a rerunnable, fail-closed checkpoint for the five §18/§20.3 V1 Host/Viewer coexistence cases.
- Confirmed that process/config isolation and H5.3u item-10 resource overlap are code-ready, but the current evidence cannot prove the required cross-role ordering, dual-role recovery or App-restart Host ID continuity.
- Froze the minimum timestamped cross-process lifecycle evidence contract before adding a writer or five-result manifest validator. H5.3w implemented the strict writer/schema, H5.3x connected App process start/termination, H5.3y connected exact Viewer session/Core/App teardown edges, H5.3aa connected HostAgent process start/termination, and H5.3ab connected the first post-startup ready-zero HostAgent self-observation. H5.3z verified that App-side Host composition must remain fail closed until the versioned XPC identity binds the exact HostAgent PID and process-start identity; continuous Host transitions, actual Viewer auto-recovery and the validator remain open.
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

H5.3w provides a default-off timestamped Host/Viewer lifecycle writer with separate per-process files, domain-separated identity digests, strict role/event shapes and terminal lifecycle ordering. H5.3x gives the App process one best-effort owner that derives exact kernel process-start identity plus packaged build identity, then records start/termination. H5.3y adds serialized Viewer epochs and maps only real Core streaming/terminal plus App teardown edges. H5.3aa reuses the same role-bound owner inside the HostAgent product lifetime: it consumes the already-preflighted Agent build ID, records start before `HostAgentProcessRunner.run`, and records termination through a defer after every sanitized run result. H5.3ab retains the exact lease boot/build/config identity inside the running lifetime and, only after XPC listener activation, records `readyZeroInbound` when the current sanitized snapshot is exactly ready/registered with zero authenticated connections and no active session. The current App still closes the session on terminal Core state, so same-epoch recovery is supported by the owner but not produced by current product behavior. Continuous Agent Host transitions and all App Host observations remain unconnected. The repository still contains no five-scenario validator or passing V1 concurrency result.

H5.3z audited the complete App background projection path. The validated projection already carries `hostInstanceID`, `agentBuildID`, `agentBootID`, projection generation, Host state, authenticated connection count, active-session state and observation time. App configuration coherence also binds the live Agent build/boot identity to the persisted positive config revision. That is sufficient to normalize Host ready/active/disconnected states, derive the Host/build digests and bind boot/config/generation, but it is not sufficient to identify the exact Agent process.

The strict lifecycle writer intentionally requires `hostAgentProcessID` plus a domain-separated digest of the Agent kernel process-start identity. The current version-1 XPC handshake/client identity exposes only build, Host instance and Agent boot identifiers; neither handshake nor snapshot exposes an Agent PID or process-start identity. A boot UUID is not a kernel process-start identity, and discovering a same-bundle process locally would not bind that process to the accepted XPC peer. Therefore App Host lifecycle emission remains unimplemented and fail closed. The next bounded contract must version the Agent process identity across XPC before product composition is allowed.

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

After H5.3ab, the audit emits `status=host-agent-initial-ready-evidence-implemented` only while the writer, App process/Viewer composition, HostAgent process-lifetime and initial readiness composition, available Host authority, exact missing App-visible Agent process identity and remaining gaps match the repository. It intentionally claims neither continuous Agent/App Host observation, Viewer recovery nor a V1 matrix pass.

The next safe automatic step is the HostAgent-local Host transition normalization state machine, still without changing XPC. A later versioned, fail-closed HostAgent process-identity XPC contract remains mandatory before App Host observation can bind exact Agent PID/start identity to the same validated peer. The five-result manifest validator comes only after App and HostAgent writers are connected to authoritative lifecycle events. Installed App/Agent and two-machine execution remain a later manual checkpoint.

H5.3z verification completed with focused audit 1/1, full ScriptTests 96/96, Python compilation and `git diff --check`. H5.3aa added HostAgent process-lifetime composition. H5.3ab advances the audit to 38/38 evidence checks and 77/77 source anchors; its complete fresh verification is recorded in `h5-v1-concurrency-host-agent-initial-ready.md`.
