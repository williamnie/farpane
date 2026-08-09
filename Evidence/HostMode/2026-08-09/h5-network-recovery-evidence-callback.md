# H5.3k Network-path recovery evidence callback

## Outcome

The process-lifetime recovery evidence owner is now connected to exact network
path generation recovery. Acceptance is captured only after HostCore accepts
the restart, the baseline Host/recovery epoch remains pinned, and the polling
owner commits the exact generation/epoch pair. Completion is persisted only
after a direct HostCore snapshot converges to the same Host, same recovery
epoch, `running`, and `ready/ready`, and the poll owner commits a converged
outcome. This checkpoint does not execute a real network transition and does
not claim a section 15.2 item 7 pass.

## Key evidence

- `NWPathMonitor` observations and the trigger owner still only normalize a
  candidate edge. Baseline establishment, outage observation, interface
  identity change, or generation allocation alone cannot create evidence.
- `recoveryAccepted(pathGeneration, recoveryEpoch)` runs only after the exact
  next nonzero generation passes baseline validation, the HostCore restart
  operation returns accepted, and polling state commits with its pinned epoch.
- The initial healthy Host state legitimately has `recoveryEpoch = 0`.
  H5.3k corrects the H5.3h writer/owner restriction so network evidence accepts
  that authoritative baseline while continuing to require a nonzero path
  generation. Sleep/wake evidence still requires a nonzero epoch.
- `recoveryCompleted(pathGeneration, recoveryEpoch)` runs only after direct
  snapshot convergence commits a `.completed(..., .converged)` outcome.
  Unavailable observations may retry, while foreign Host, epoch drift,
  incompatible state, restart rejection, timeout, failure, and cancellation
  never complete evidence.
- Completion remains marked in flight through the evidence callback, so
  process teardown drains the callback before cancelling the shared evidence
  owner. Acceptance clock sampling has an independent in-flight gate and is
  also drained before file-handle release.
- Product composition injects the same process-lifetime evidence owner used by
  sleep/wake. Observation callbacks are `Void`, their results are ignored, and
  evidence clock/path/append failure cannot alter restart, convergence,
  readiness, termination, or snapshot polling.

## Verification

- Network polling owner: 10 passed, 0 failed. The new test proves initial epoch
  zero acceptance, exact generation/epoch completion, and that epoch drift
  produces failure without completed evidence.
- Evidence owner: 9 passed, 0 failed. New deterministic tests prove exact
  generation/epoch matching, monotonic timing, duplicate/mismatch no-op, no
  output before completion, and cancellation draining clock sampling.
- Recovery writer: 5 passed, 0 failed, including a network record with the
  authoritative initial recovery epoch zero.
- Product/composition source contracts: 7 passed, 0 failed.
- VideoPipeline target: 126 passed, 0 failed.
- Full Swift package: 851 passed, 4 conditional built-core skips, 0 failed.
- Full ScriptTests: 46 passed, 0 failed. Python compile, arm64 Release build,
  and diff checks passed.
- The executable audit reports `status=network-callback-implemented`, 11/11
  evidence checks, 15/15 source locations, and no missing evidence.

## Remaining boundary

- Add a pinned Rust display-reconfiguration provenance marker before wiring
  display evidence; a generic Swift route replacement remains insufficient.
- Implement the bounded recovery manifest validator and negative fixtures.
- On installed Macs, execute all three transition types and one fresh passed
  600-second `1080p30` run after each transition on the same scope/build.
- Battery/thermal and combined-role evidence remain separate section 15.2
  items 9 and 10.
- No App or Agent was installed, launched, registered, or deployed. Host ABI,
  XPC, Hermes, CI, dependencies, database, real network/TCC/configuration, and
  secrets were not changed; nothing was pushed.
