# H5.3v V1 coexistence evidence authority audit

## Outcome

- Added `Scripts/audit-host-v1-concurrency-evidence.py` as a rerunnable, fail-closed checkpoint for the five §18/§20.3 V1 Host/Viewer coexistence cases.
- Confirmed that process/config isolation and H5.3u item-10 resource overlap are code-ready, but the current evidence cannot prove the required cross-role ordering, dual-role recovery or App-restart Host ID continuity.
- Froze the minimum timestamped cross-process lifecycle evidence contract before adding a writer or five-result manifest validator. H5.3w implemented the strict writer/schema, H5.3x connected App process start/termination, H5.3y connected exact Viewer session/Core/App teardown edges, H5.3aa connected HostAgent process start/termination, H5.3ab connected the first post-startup ready-zero HostAgent self-observation, H5.3ac added the HostAgent-local transition normalizer, H5.3ad connected accepted session edges plus accepted snapshot publications through one bounded generation ingress, H5.3af implemented exact Agent process identity over XPC v2, H5.3ag composes App-observed Host lifecycle evidence, and H5.3ah composes bounded same-epoch Viewer automatic recovery. The five-result validator remains open.
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

H5.3w provides a default-off timestamped Host/Viewer lifecycle writer with separate per-process files, domain-separated identity digests, strict role/event shapes and terminal lifecycle ordering. H5.3x gives the App process one best-effort owner that derives exact kernel process-start identity plus packaged build identity, then records start/termination. H5.3y adds serialized Viewer epochs and maps only real Core streaming/terminal plus App teardown edges. H5.3aa reuses the same role-bound owner inside the HostAgent product lifetime: it consumes the already-preflighted Agent build ID, records start before `HostAgentProcessRunner.run`, and records termination through a defer after every sanitized run result. H5.3ab retains the exact lease boot/build/config identity inside the running lifetime and records the first ready-zero state. H5.3ac adds an owner-maintained transition normalizer: strict source generations and one immutable Host/boot/config/build scope reject stale, duplicate, concurrent same-generation and identity-drift inputs; disconnected/recovered generations are derived rather than caller supplied. H5.3ad adds a bounded process-boot ingress that consumes only accepted `sessionStarted`/`sessionEnded` edges and accepted snapshot coordinator publications, assigns one ordered local generation, buffers sanitized pre-identity observations, binds the lease identity before initial snapshot publication and drains before process termination. H5.3ag now feeds App-observed Host states from coherent background projections and exact XPC v2 peer identity into the same strict writer. H5.3ah keeps one logical Viewer epoch across a fixed 500/1,500/3,000 ms replacement-client window, rejects stale Core generations and accepts recovery only from a real current-client streaming callback. Replacement credentials come only from the existing per-device Keychain item; unsaved credentials fail closed. H5.3ai adds an exact App-only coherent Host reaffirmation after successfully recorded Viewer streaming/stopped edges, so unchanged ready/active state is provable on the far side of those boundaries without weakening ordinary duplicate suppression. The repository still contains no five-scenario validator or passing V1 concurrency result.

H5.3z audited the complete App background projection path. The validated projection already carries `hostInstanceID`, `agentBuildID`, `agentBootID`, projection generation, Host state, authenticated connection count, active-session state and observation time. App configuration coherence also binds the live Agent build/boot identity to the persisted positive config revision. That is sufficient to normalize Host ready/active/disconnected states, derive the Host/build digests and bind boot/config/generation, but it is not sufficient to identify the exact Agent process.

The strict lifecycle writer intentionally requires `hostAgentProcessID` plus a domain-separated digest of the Agent kernel process-start identity. The current version-1 XPC handshake/client identity exposes only build, Host instance and Agent boot identifiers; neither handshake nor snapshot exposes an Agent PID or process-start identity. A boot UUID is not a kernel process-start identity, and discovering a same-bundle process locally would not bind that process to the accepted XPC peer. Therefore App Host lifecycle emission remains unimplemented and fail closed.

H5.3ae froze the missing contract as a rerunnable audit. H5.3af implements it: handshake schema/wire version 2 carries build, Host instance, Agent boot, exact Agent PID and the existing domain-separated process-start SHA-256. HostAgent captures one `getpid()` plus matching `PROC_PIDTBSDINFO` before immutable XPC identity publication and shares that authority with the command owner. App accepts the identity only from a compatible v2 handshake, retains the complete typed identity through the same snapshot/event/command connection and compares all five fields across reconnect. Snapshot does not redefine identity, raw process-start data does not cross XPC, and schema/wire v1 fails closed.

H5.3ag composes that authority with the coherent background projection. The App observation state accepts only a positive configuration revision and normalized ready-zero, inbound-active or disconnected Host shape; unavailable configuration evidence emits nothing, while loss of a previously coherent projection can emit disconnected. One process-local source sequence deduplicates repeated UI refreshes. Host/boot/build/PID/start/config drift fails the evidence run closed, and the product passes the Agent PID/start only from the typed XPC peer identity. The App does not scan processes or retain snapshot payloads.

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

After H5.3ai, the audit emits `status=viewer-boundary-host-reaffirmation-composed` only while the writer, App process/Viewer composition, HostAgent process lifetime, Host transition normalizer, bounded continuous observation ingress, exact XPC v2 Agent identity, coherent App Host observation, bounded credential-safe replacement-client recovery and Viewer-boundary exact Host reaffirmation match the repository. It still does not claim a V1 matrix pass.

The next implementation boundary is `five-scenario-concurrency-validator`. Installed App/Agent and two-machine execution remain a later manual checkpoint.

H5.3z verification completed with focused audit 1/1, full ScriptTests 96/96, Python compilation and `git diff --check`. H5.3aa added HostAgent process-lifetime composition, H5.3ab added initial ready evidence, H5.3ac added transition normalization, H5.3ad added continuous observation, H5.3ae froze the version-2 contract, and H5.3af implements it. H5.3af passed focused audit tests 2/2, full ScriptTests 97/97, Swift 882/882 with four expected built-core conditional skips, arm64 Release build, Python compilation and `git diff --check`; its focused audit is 13/13 evidence checks plus 20/20 source anchors, while the main audit is 41/41 plus 94/94. H5.3ag passed focused Swift tests 20/20, focused audit tests 2/2, full ScriptTests 97/97, Swift 887/887 with four expected built-core conditional skips, arm64 Release build, Python compilation and `git diff --check`; its focused audit is 15/15 plus 24/24 and main audit is 41/41 plus 99/99. Full H5.3ag details are recorded in `h5-v1-concurrency-application-host-observation.md`.

H5.3ah passed focused recovery/App composition tests 12/12, focused audit tests 2/2, full ScriptTests 97/97, Swift 895/895 with four expected built-core conditional skips, arm64 Release build, Python compilation and `git diff --check`. The main audit now reports `viewer-automatic-recovery-composed`, 42/42 evidence checks and 103/103 source anchors; the identity/recovery boundary audit reports 16/16 plus 26/26. Full H5.3ah details are recorded in `h5-v1-concurrency-viewer-automatic-recovery.md`.

H5.3ai passed focused state/process/App composition tests 23/23, focused audit 1/1, full ScriptTests 97/97, Swift 897/897 with four expected built-core conditional skips, arm64 Release build, Python compilation and `git diff --check`. The main audit now reports `viewer-boundary-host-reaffirmation-composed`, 43/43 evidence checks and 106/106 source anchors. Full H5.3ai details are recorded in `h5-v1-concurrency-viewer-boundary-host-reaffirmation.md`.
