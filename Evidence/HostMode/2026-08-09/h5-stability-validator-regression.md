# H5.3a Stability validator durable regression

## Outcome

The existing 30-minute Host stability validator now has durable repository
regression coverage. Its previous synthetic fixture checks were described in
evidence but were not retained as executable tests, so later edits could weaken
the acceptance gate without a failing test.

This checkpoint adds no performance data and does not turn a smoke fixture into
real-Mac acceptance.

## Contract frozen

- A minimal complete `stability-1080p30` smoke fixture exercises the same
  route-telemetry schema, Rust queue/writer/network/transport finalization,
  six-reason drop ledger, active-route sleep assertion, and six stability
  windows used by the production validator.
- The valid fixture must publish schema-v4 run evidence with status `pass`, six
  windows, and the complete zero-count drop ledger.
- A material monotonic CPU rise across all six windows must fail and remain
  visible in the published result.
- Any missing or uninstrumented member of the six-reason drop ledger must fail.
- A short smoke window relabeled as acceptance must fail the independent
  1,800-second validator gate.
- Existing run evidence is immutable: a second validation attempt refuses to
  overwrite the first result and preserves its bytes.

## Verification

- Focused stability-validator tests: 5 passed, 0 failed.
- Full `Tests/ScriptTests` suite: 33 passed, 0 failed.
- Python bytecode compilation for the validator and its regression test:
  passed.
- Root `git diff --check`: passed.

## Remaining boundary

- H5.3 still requires real 1,800-second Apple Silicon and Intel runs. Smoke
  fixtures prove validator behavior only, not CPU, memory, energy, thermal,
  hardware codec, route continuity, or product stability.
- The complete section 15.2 matrix still needs installed-machine evidence for
  idle, static, 1080p30, 4K30 normal/video, post-recovery repetition, battery,
  outbound Viewer, and simultaneous Host + Viewer sessions.
- Instruments Time Profiler/System Trace/Allocations/Leaks and input-to-photon
  evidence remain real-machine tasks.

No App/Agent was installed, launched, registered, or deployed. No Hermes,
server key, CI, dependency, database, real TCC state, or user configuration was
changed.
