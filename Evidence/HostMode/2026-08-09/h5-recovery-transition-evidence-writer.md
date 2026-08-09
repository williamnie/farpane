# H5.3h Recovery transition evidence writer

## Outcome

The frozen H5.3g transition schema now has an independent, default-off JSONL
writer in `VideoPipeline`. It can persist only successfully converged
`sleepWake`, `networkPath`, or `displayReconfigure` proofs. This step does not
connect the writer to any product recovery owner and therefore creates no
runtime artifact or section 15.2 item 7 pass by itself.

## Key evidence

- Writer construction is all-or-nothing: an output path and two already
  derived SHA-256 digests must all be present. H5.3i narrows external
  configuration to the output path only; its process owner derives both
  digests in memory before constructing this writer. Both digests must be
  exactly 64 lowercase hexadecimal characters; raw Host/build identity is
  never part of the writer API or JSON.
- The output must be a new absolute file URL ending in `.jsonl`. Creation uses
  no-replace semantics, and the writer retains the original file handle so a
  later path replacement cannot redirect an append into another file.
- Every record carries schema v1, an internal monotonic sequence, wall and
  monotonic accepted/completed times, literal `completed` status, and the two
  opaque scope digests. Monotonic completion must be strictly after acceptance.
- Sleep/wake requires a nonzero recovery epoch and explicit running/ready
  convergence. Network recovery additionally requires a nonzero exact path
  generation.
- Display recovery records both previous and replacement route identity:
  display revisions may remain equal, matching the current pinned service,
  while connection and codec epochs must each increase strictly. This proves a
  fresh replacement route without persisting display ID or remote identity.
- The writer is thread-safe and bounded to 128 records. Capacity exhaustion,
  malformed timing, zero generations/epochs, stale route epochs, partial
  configuration, unsafe paths, and overwrite attempts all fail closed.

## Verification

- Writer-focused Swift tests: 5 passed, 0 failed. They cover all three exact
  JSON shapes, sanitization allowlists, configuration/path/digest rejection,
  invalid timing/correlation, 64-way concurrent sequencing, and the 128-record
  boundary.
- VideoPipeline test target: 117 passed, 0 failed.
- Full Swift package: 837 passed, 4 conditional built-core skips, 0 failed.
- Full ScriptTests: 46 passed, 0 failed. The machine audit now reports
  `status=writer-implemented`, 8/8 evidence checks, 9/9 source locations, and
  no missing evidence.
- arm64 Release build, Python compile, and diff checks passed.

## Remaining boundary

- H5.3i now derives both digests in memory and constructs at most one
  process-lifetime writer. Exact successful sleep, network, and display
  recovery callbacks are still not connected. Writer failure disables only
  evidence collection and cannot change recovery behavior or readiness.
- The bounded manifest validator and its negative fixtures remain unimplemented.
- Each transition still requires an installed-Mac execution followed by a
  fresh passed 600-second `1080p30` run on the same scope/build.
- Battery/thermal and combined-role evidence remain separate section 15.2
  items 9 and 10.
- No App or Agent was installed, launched, registered, or deployed. Host ABI,
  XPC, Hermes, CI, dependencies, database, real TCC/configuration, and secrets
  were not changed; nothing was pushed.
