# H5.3n Recovery performance manifest validator

## Outcome

Section 15.2 item 7 now has an executable, bounded aggregation gate. A
recovery-only `1080p30` acceptance run is schema v5 and binds the exact
transition-record SHA-256, sequence, kind, completion time, sanitized Host
scope digest, and build digest. It also preserves the authoritative system
sampling start/completion timestamps. Existing non-recovery performance runs
remain schema v4, so the base matrix contract is unchanged.

The recovery manifest accepts exactly three passed, at-least-600-second v5
runs and requires one each for `sleepWake`, `networkPath`, and
`displayReconfigure`. Every run must start strictly after its exact transition
completed, and all three must share one machine, macOS, Host scope, and build.
This implements the gate; it does not generate real transition or performance
evidence and therefore does not claim item 7 has passed.

## Key evidence

- The common system sampler now emits schema v4 with a sampling-start UTC
  timestamp while retaining its existing one-sample-per-second wall-duration
  boundary.
- The scenario runner accepts recovery source and sequence only as an exact
  pair, only for a real `1080p30` acceptance run, and only from an absolute
  regular non-symlink JSONL file.
- The run validator strictly decodes the selected transition record, verifies
  its typed correlation and pre-sampling completion, and emits v5 only when
  the recovery binding is valid. Missing or malformed binding produces a
  failed v5 artifact, never an unbound pass.
- The manifest binds the complete transition source and each run source by
  declared SHA-256, then independently binds each run to one raw transition
  record SHA-256.
- Manifest/source size, record count, exact keys, contiguous sequence, typed
  correlations, UTC/monotonic ordering, unique paths/digests/records, and
  machine/scope/build coherence are bounded and fail closed.
- Relative-path escape, any symlink component, missing/malformed input,
  duplicate sources, digest mismatch, pre-recovery sampling, short/smoke/failed
  runs, and existing output are rejected.
- A passing aggregate explicitly publishes
  `fullSection15_2Item7Complete=true`; the repository currently contains no
  such real aggregate.

## Verification

- Recovery manifest validator regression: 9 passed, 0 failed.
- Recovery run binding, manifest, and audit focused regression: 17 passed,
  0 failed.
- Full ScriptTests: 57 passed, 0 failed.
- Recovery machine audit reports `manifest-validator-implemented`, 14/14
  evidence checks, 21/21 source locations, and no missing evidence.
- Python compile, zsh syntax checks, diff whitespace checks, and arm64 Swift
  Release build completed successfully.

## Remaining boundary

- On one installed Mac and one exact Host/build scope, generate successful
  sleep/wake, network-path, and display-reconfigure transition records.
- After each transition completes, execute one fresh passed 600-second
  `1080p30` acceptance run with the matching source/sequence binding, then run
  the new aggregate validator.
- Battery/thermal and combined Host/Viewer budgets remain separate section
  15.2 items 9 and 10.
- No App or Agent was installed, launched, registered, or deployed. Hermes,
  CI, dependencies, database, real TCC/configuration, and secrets were not
  changed; nothing was pushed.
