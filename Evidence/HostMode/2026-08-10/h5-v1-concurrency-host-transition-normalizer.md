# H5.3ac HostAgent Host transition normalizer

## Outcome

- Replaced the HostAgent evidence API's caller-supplied final evidence state and recovery generation with three authoritative runtime inputs only: ready with zero inbound sessions, inbound media active, and disconnected.
- Added one owner-maintained Host scope containing the Host digest, Agent boot UUID, positive config revision and Agent build digest. A different scope cannot advance or replace an active evidence session.
- Serialized source generations and Host evidence appends under the existing process owner. Duplicate, stale, concurrent same-generation, invalid-state and identity-drift observations are rejected without disabling product behavior.
- Routed the existing post-listener initial ready observation through the normalizer using the exact snapshot refresh generation.

## Transition contract

An initial ready or active observation writes generation zero. An initial disconnected observation binds only the scope and source-generation watermark, because no previous online state exists to disconnect from. A transition from ready/active to disconnected creates recovery generation one. A subsequent ready/active observation becomes the matching recovered state at that generation. Later disconnects increment the recovery generation with checked arithmetic; ready/active changes inside the same recovered period keep that generation.

Semantic duplicates advance only the source watermark and do not append an event. This prevents an older different state from being accepted after a newer duplicate observation. Source generations must be positive and strictly increasing, and the process role/build plus Host/boot/config scope must remain exact. Evidence state and source watermark commit only after a record append succeeds, except for duplicate or initial-disconnected watermark-only mutations. A real append failure still disables evidence only.

## Product composition boundary

The product currently supplies only the already-proven post-listener initial ready snapshot. This step does not subscribe the owner to continuous snapshot, media or connection publications. Existing snapshot refresh work may overlap or coalesce, so polling it or reading after arbitrary events would not be lossless and was not added.

The next boundary is an authoritative lossless HostAgent-local publication seam that can submit every ready/active/disconnected transition and its source generation. App-side Host evidence remains fail closed until a versioned XPC identity binds the accepted peer to the exact HostAgent PID and kernel process-start identity. Viewer product auto-recovery, the five-scenario validator and installed two-machine results also remain open; no V1 matrix pass is claimed.

## Verification

- Focused owner and HostAgent product source tests: 17/17 passed.
- Full Swift suite: 878/878 passed, with 4 expected built-core environment skips.
- Full ScriptTests: 96/96 passed.
- arm64 Release build, Python compilation and `git diff --check`: passed.
- V1 audit: `status=host-agent-transition-normalizer-implemented`, 38/38 evidence checks and 82/82 source anchors.
