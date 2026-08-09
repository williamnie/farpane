# H5.3ad HostAgent continuous Host observation ingress

## Outcome

- Added one bounded `HostAgentConcurrencyObservationState` to the process-boot state owner. It assigns a strictly increasing local source generation and drains sanitized observations in order after the runtime lease identity becomes available.
- Consumed only accepted `sessionStarted` and `sessionEnded` Core events for exact inbound-active and disconnected edges. Irrelevant event types and raw event payloads do not enter this ingress.
- Added an accepted-snapshot callback to the existing serialized snapshot coordinator. The callback fires only after the projection publish and semantic session-transition journaling both succeed; rejected, stale, contradictory and copy-failed snapshots are not forwarded.
- Connected event and snapshot observations to the H5.3ac normalizer on the existing serial Host event queue. The previous one-off initial-ready path now uses the same ingress and source-generation authority.

## Ordering and failure contract

Relevant Core events are admitted by `HostAgentEventState` before the concurrency ingress. The product records the exact session edge before requesting its snapshot refresh. Accepted snapshot callbacks are placed back on the same Host event queue, so a session-start/session-end edge cannot be overtaken by the projection requested for that event.

Events arriving before the lease identity is exposed are retained only as a bounded sanitized state/Host-ID tuple. Binding drains them in source-generation order. The ingress admits at most 256 pending observations; capacity or generation exhaustion clears the pending set and fails evidence closed without stopping HostAgent. Teardown first cancels and drains snapshot publication, then drains the Host event queue and cancels the ingress before the process evidence owner writes its terminal edge.

Snapshot classification is fail closed:

- exact `ready + registered + zero authenticated connections + no active session` becomes ready-zero;
- exact `ready + registered + positive authenticated count + active session` becomes inbound-media-active;
- a known non-ready Host state becomes disconnected;
- incoherent and unknown tuples emit nothing.

## Remaining boundary

This step connects the HostAgent writer to continuous authoritative session edges and accepted Host projections. It does not add a new timer, parse sensitive event payloads, modify the Host ABI/XPC schema, or infer state from an event followed by an unrelated snapshot read.

App-side Host evidence is still fail closed because the version-1 XPC peer identity does not bind the exact HostAgent PID and kernel process-start identity. Viewer product auto-recovery, the five-scenario aggregate validator and installed two-machine results remain open, so no V1 concurrency matrix pass is claimed.

## Verification

- Focused ingress, snapshot coordinator and product composition tests: 28/28 passed.
- Full Swift suite: 882/882 passed, with 4 expected built-core environment skips.
- Full ScriptTests: 96/96 passed.
- arm64 Release build, Python compilation and `git diff --check`: passed.
- V1 audit: `status=host-agent-continuous-observation-implemented`, 40/40 evidence checks and 89/89 source anchors.
