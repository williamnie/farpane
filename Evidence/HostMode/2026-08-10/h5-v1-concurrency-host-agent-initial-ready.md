# H5.3ab HostAgent initial ready-zero coexistence evidence

## Outcome

- Retained an immutable evidence identity sourced only from the live `HostAgentBootstrapContext` single-writer lease: Agent boot UUID, preflighted build ID and positive config revision.
- Exposed that identity through the running `HostAgentProcessLifetimeGate`; stopped or stopping runtimes cannot provide it.
- Added a HostAgent-only observation API that fills exact PID/process-start identity from the configured process owner and requires the caller's Agent build digest to match that owner.
- Connected one initial `readyZeroInbound` record after all HostAgent startup gates, including XPC listener activation, have succeeded.

## Initial readiness authority

The initial record is emitted only when the current sanitized `HostAgentSnapshotState` projection simultaneously proves:

- `hostState == "ready"`;
- `registrationStatus == "ready"`;
- `authenticatedConnectionCount == 0`;
- `activeSession == nil`.

The Host scope digest comes from that projection's exact Host instance ID. Agent boot/build/config come from the process-lifetime lease record. Exact PID/start identity and the process build digest come from the already configured HostAgent evidence owner. The writer's HostAgent self-observation validation requires both process identities and build digests to agree.

Malformed state generation, zero config revision, zero Agent boot UUID, raw identity failure, wrong process role or mismatched Agent build are rejected before append and do not disable evidence. A real timing or I/O append failure still makes evidence unavailable without affecting HostAgent startup or exit.

## Lifecycle order

The process owner writes `processStarted` before Host startup. The initial Host record occurs only after the validated initial snapshot is bound to XPC identity, media/polling/recovery owners have started and the XPC listener is active. `processTerminating` remains deferred across every HostAgent run result.

## Remaining boundary

This step proves only the first post-startup ready-zero observation. It does not infer or emit inbound-media-active, disconnected or recovered transitions. Existing snapshot refreshes can overlap/coalesce, so reading immediately after an arbitrary event is not yet a lossless publication seam; no timer/polling approximation was added.

The next automatic step is a serialized HostAgent-local transition normalizer that rejects duplicates, stale generations and invalid ready/active/disconnected/recovery ordering. Connecting it to a lossless snapshot/media publication seam remains separate. App observation still requires the versioned Agent PID/process-start XPC contract identified by H5.3z.

## Verification

Focused owner/product composition tests passed 16/16 after correcting invalid Host observations to reject before append. Full Swift tests passed 877/877 with 4 expected built-core environment skips; full ScriptTests passed 96/96; the arm64 Release build, Python compilation and `git diff --check` passed. The V1 audit reports `status=host-agent-initial-ready-evidence-implemented`, 38/38 evidence checks and 77/77 source anchors.
