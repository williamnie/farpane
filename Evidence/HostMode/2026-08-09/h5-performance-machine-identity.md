# H5.3b Performance evidence machine identity

## Outcome

The active, connected-static, and 30-minute stability validator now binds every
run summary to the machine identity emitted by the system sampler. A passing
summary carries the bounded `machineModel`, exact `arm64 | x86_64`
`architecture`, and bounded `macOSVersion` values. Missing, unsupported,
whitespace-padded, oversized, or control-character-bearing identity data fails
closed.

This closes the evidence-chain gap where a valid performance run could lose
the facts needed to prove the section 15.2 Apple Silicon and Intel split. It
does not claim either architecture has completed a real run.

## Key evidence

- `Scripts/sample-farpane-host-performance.sh` already captures `hw.model`,
  `uname -m`, and `sw_vers -productVersion` in schema-v3 system evidence.
- `Scripts/validate-farpane-host-performance.py` now requires and sanitizes
  those fields before publishing its existing schema-v4 run summary.
- Invalid identity values are published only as `unavailable` in a failed
  summary, so untrusted control characters or future architecture labels do
  not propagate into aggregate evidence.
- `Tests/ScriptTests/test_host_performance_validator.py` proves both the valid
  Apple Silicon projection and fail-closed handling for missing model,
  unsupported architecture, and a control-character-bearing OS version.

## Verification

- `python3 -m unittest Tests.ScriptTests.test_host_performance_validator`:
  6 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  34 tests, 0 failures.
- `python3 -m py_compile Scripts/validate-farpane-host-performance.py Tests/ScriptTests/test_host_performance_validator.py`:
  exit 0.
- `git diff --check`: exit 0.

No Swift/Rust product source changed, so no App/Core build is claimed for this
script, test, evidence, and design-only step.

## Remaining boundary

- Idle evidence still needs the same machine-identity binding before an
  aggregate section 15.2 matrix can treat it as architecture-qualified.
- Real 600-second and 1,800-second runs on both Apple Silicon and Intel remain
  mandatory. Synthetic fixtures prove validator behavior only.
- Recovery repetitions, battery idle/active, combined Host/Viewer budgets,
  Instruments traces, and installed-machine acceptance remain open.
- No App or Agent was installed, launched, registered, or deployed. Hermes,
  CI, dependencies, database, TCC, real configuration, and secrets were not
  touched; nothing was pushed.
