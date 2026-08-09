# H5.3j Sleep/wake recovery evidence callback

## Outcome

The process-lifetime recovery evidence owner is now connected to the real
sleep/wake state machine at two exact-epoch boundaries. Acceptance is captured
only after a matching `sleeping(epoch)` state commits to recovery. Completion
is persisted only after media recovery, registration recovery, authoritative
`running + ready` publication, and the final same-epoch `running` state commit.
This checkpoint does not execute a real sleep/wake cycle and does not claim a
section 15.2 item 7 pass.

## Key evidence

- `HostAgentSleepWakeRecoveryOwner` exposes two observation-only `Void`
  callbacks. They cannot veto, advance, or change recovery state.
- `recoveryAccepted(epoch)` runs only after the state machine accepts the
  matching wake edge and commits `recovering(epoch)`. Duplicate, future,
  out-of-order, preflight-rejected, or sleep-preparation-rejected events cannot
  create an acceptance.
- `recoveryCompleted(epoch)` runs only after exact media and registration
  completions, successful `publishAvailable(epoch)`, and replacement of
  `restoringRegistration(epoch)` with `running(epoch)`. Failed/rejected starts,
  failed or stale completions, cancellation, and publication failure never
  invoke it.
- The evidence owner stores one bounded in-memory sleep/wake acceptance with
  wall and monotonic clocks. Completion must match the exact nonzero epoch;
  mismatches and duplicates have no clock, file, sequence, or recovery side
  effect.
- Acceptance clock sampling has an explicit in-flight gate. Teardown closes
  admission and waits for accepted configuration, clock sampling, and append
  work before clearing the pending epoch and releasing the file handle.
- Product wiring injects the same process-lifetime evidence owner into the
  installed sleep/wake composition. Both callback results are deliberately
  ignored; disabled evidence or append failure cannot alter Host startup,
  readiness, sleep recovery, or termination.

## Verification

- Sleep/wake owner behavior: 13 passed, 0 failed, including explicit proof
  that failed authoritative availability publication cannot complete evidence.
- Evidence owner behavior: 7 passed, 0 failed. The new deterministic tests
  prove exact-epoch correlation, accepted/completed monotonic preservation,
  duplicate rejection, no output before completion, and teardown draining an
  accepted clock-sampling window.
- Product/composition source contracts: 9 passed, 0 failed.
- VideoPipeline target: 124 passed, 0 failed.
- Full Swift package: 848 passed, 4 conditional built-core skips, 0 failed.
- Full ScriptTests: 46 passed, 0 failed. Python compile, arm64 Release build,
  and diff checks passed.
- The executable audit reports `status=sleep-wake-callback-implemented`, 10/10
  evidence checks, 13/13 source locations, and no missing evidence.

## Remaining boundary

- Connect the exact network-path generation acceptance/completion callback in
  a separate checkpoint.
- Add a pinned Rust display-reconfiguration provenance marker before wiring
  display evidence; a generic Swift route replacement remains insufficient.
- Implement the bounded recovery manifest validator and negative fixtures.
- On installed Macs, execute all three transition types and one fresh passed
  600-second `1080p30` run after each transition on the same scope/build.
- Battery/thermal and combined-role evidence remain separate section 15.2
  items 9 and 10.
- No App or Agent was installed, launched, registered, or deployed. Host ABI,
  XPC, Hermes, CI, dependencies, database, real TCC/configuration, and secrets
  were not changed; nothing was pushed.
