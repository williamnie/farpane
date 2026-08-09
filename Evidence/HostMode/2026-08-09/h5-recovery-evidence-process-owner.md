# H5.3i Recovery evidence process owner

## Outcome

HostAgent now owns one best-effort recovery evidence authority for its process
lifetime. The owner derives the Host-instance scope and build-identity digests
in memory, constructs the H5.3h writer only when an output path is explicitly
configured, and drains it during teardown. H5.3j subsequently connects the
exact sleep/wake callback, and H5.3k connects network path. Display remains
open. None of these checkpoints by itself creates a runtime transition proof
or section 15.2 item 7 pass.

## Key evidence

- External configuration supplies only `FARPANE_HOST_RECOVERY_OUTPUT`. The raw
  Host instance ID comes from the exact HostAgent snapshot identity and the raw
  build identity comes from the executable's expected Agent build ID; neither
  value is accepted from environment configuration.
- Both raw identities are bounded to 1...512 UTF-8 bytes and reject control or
  DEL characters. CryptoKit derives lowercase SHA-256 with distinct domains:
  `farpane.host-recovery.scope.v1` and
  `farpane.host-recovery.build.v1`, each separated from its value by a NUL.
- Missing output configuration leaves evidence disabled. Invalid identity,
  path, or writer construction makes only evidence unavailable. HostAgent
  deliberately ignores the configuration result, so evidence cannot gate Host
  startup, readiness, recovery, or termination.
- The owner serializes appends through the same writer, permanently disables
  evidence after a record failure, bounds observable counters, and exposes a
  one-shot terminal cancellation that drains accepted work before releasing
  the file handle.
- HostAgent creates exactly one owner. Teardown first drains the network and
  sleep recovery owners, then the evidence owner, and only then cancels media
  and snapshot polling, preventing a recovery producer from outliving its
  evidence sink.
- Swift media-route replacement currently cannot distinguish display
  reconfiguration from codec change, subscriber replacement, or another route
  replacement. No display record is emitted until the pinned Rust authority
  exposes an exact provenance marker.

## Verification

- Owner/writer focused tests: 10 passed, 0 failed. They cover default-off
  behavior, digest domains, raw-identity omission, invalid identity/path
  isolation, write failure, bounded sequencing, and terminal cancellation.
- HostAgent composition contract tests: 3 passed, 0 failed. They prove one
  process owner, ignored configuration result, ordered teardown, CryptoKit
  domain separation, and output-only external configuration.
- VideoPipeline target: 122 passed, 0 failed. Full Swift package: 845 passed,
  4 conditional built-core skips, 0 failed on two consecutive final runs.
- Full ScriptTests: 46 passed, 0 failed. Python compile, arm64 Release build,
  and diff checks passed.
- The executable audit reports `status=process-owner-implemented`, 9/9 evidence
  checks, 11/11 source locations, and no missing evidence.
- No installed App, live Host, or real recovery was exercised by this
  checkpoint.

## Remaining boundary

- H5.3j now binds exact successful sleep/wake convergence; network-path
  convergence is now bound by H5.3k. Evidence append failure remains isolated.
- Add a pinned Rust display-reconfiguration provenance marker before wiring
  display evidence; generic Swift route replacement is not sufficient proof.
- Implement the bounded recovery manifest validator and negative fixtures.
- On installed Macs, execute all three transition types and one fresh passed
  600-second `1080p30` run after each transition on the same scope/build.
- Battery/thermal and combined-role evidence remain separate section 15.2
  items 9 and 10.
- No App or Agent was installed, launched, registered, or deployed. Host ABI,
  XPC, Hermes, CI, dependencies, database, real TCC/configuration, and secrets
  were not changed; nothing was pushed.
