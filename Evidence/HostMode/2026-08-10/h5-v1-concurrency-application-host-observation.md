# H5.3ag App Host lifecycle observation composition

## Outcome

The App process now records Host lifecycle observations from the background
HostAgent without discovering or guessing the Agent process. Each observation
combines one coherent App background projection, a positive configuration
revision and the exact five-field identity accepted by the version-2 XPC
handshake.

This step connects App Host ready, inbound-active, disconnected and recovered
evidence. It does not add Viewer reconnection behavior, a five-scenario
validator or installed two-machine results, so it does not claim the V1
concurrency matrix passes.

## Composition authority

`HostAgentApplicationConcurrencyObservationState` consumes only the typed
background projection already accepted by the App lifecycle. A projection is
eligible only when configuration coherence supplies a positive revision and
the shared Host runtime-state policy accepts one of these exact shapes:

- ready/ready, zero authenticated connections and no active session;
- ready/ready, positive authenticated connections and an active session;
- a typed non-running Host state mapped to disconnected.

An available projection with missing configuration evidence or contradictory
session counts emits nothing. Loss of the projection may emit disconnected
only after a coherent scope was previously bound. Repeated UI refreshes are
deduplicated by activation source token and normalized candidate; emitted
observations receive a separate contiguous process-local source generation.

The bound scope contains only the validated peer identity and configuration
revision. A later Host, boot, build, PID, process-start digest or configuration
revision change fails this evidence owner closed rather than mixing two Agent
lifetimes in one App evidence stream. Snapshot payloads are inspected only for
normalization and are not retained.

## Evidence owner binding

`HostViewerConcurrencyEvidenceProcessOwner` now exposes an App-role Host
observation path. The App remains the observer process identity in each JSONL
record. The Host event separately carries the Agent PID and lowercase
process-start SHA-256 directly from `HostAgentXPCSnapshotClientPeerIdentity`,
plus Host scope, Agent boot/build and configuration revision. The process owner
rejects PID values at or below one, malformed digests, stale generations and
any mid-run scope drift.

The product composition never calls `getpid()` or `PROC_PIDTBSDINFO` for the
Agent and does not hash or persist raw process-start data. Evidence remains
default-off and best-effort; a configuration or append failure cannot alter
Host observation, XPC reconnection, UI or Viewer behavior.

## Verification boundary

The rerunnable audits are:

```sh
python3 Scripts/audit-host-agent-xpc-process-identity-contract.py
python3 Scripts/audit-host-v1-concurrency-evidence.py
```

They must report `application-host-observation-composed`, no missing evidence
or source anchors, and
`nextImplementationBoundary=viewer-automatic-recovery-composition`.

Fresh H5.3ag verification passed with focused Swift tests 20/20, focused audit
tests 2/2, full ScriptTests 97/97, full Swift tests 887/887 with four expected
built-core conditional skips, arm64 Release build, Python compilation and
`git diff --check`. The focused identity/composition audit reports 15/15
evidence checks and 24/24 source anchors; the main H5 audit reports 41/41
evidence checks and 99/99 source anchors.

## Remaining boundary

The existing Viewer evidence owner can normalize recovery only if the current
product supplies a real same-epoch Core streaming edge after disconnect. The
App currently tears down the Viewer connection instead, so Viewer automatic
recovery remains the next implementation boundary. The five-scenario manifest
validator follows only after that authority exists. Installed App/Agent and
two-machine execution remain a later manual checkpoint.
