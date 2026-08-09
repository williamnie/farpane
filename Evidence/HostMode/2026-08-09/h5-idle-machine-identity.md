# H5.3c Idle evidence machine identity

## Outcome

The Host-ready/no-screen-route idle validator now binds every run summary to
the machine identity already emitted by the shared system sampler. A passing
idle summary carries bounded `machineModel`, exact `arm64 | x86_64`
`architecture`, and bounded `macOSVersion` values.

Missing, whitespace-padded, oversized, control-character-bearing, or
unsupported identity data fails closed. Invalid values are represented only as
`unavailable` in the failed summary, so they cannot become architecture proof
in a later section 15.2 matrix.

## Key evidence

- `Scripts/sample-farpane-host-performance.sh` is the common authority for
  idle and active system evidence and already records `hw.model`, `uname -m`,
  and `sw_vers -productVersion` in schema v3.
- `Scripts/validate-farpane-host-idle.py` now requires and sanitizes those
  fields before publishing the additive fields in its schema-v1 run summary.
- `Tests/ScriptTests/test_host_idle_validator.py` proves a valid Intel identity
  survives projection and that a padded model, unsupported `i386`
  architecture, and missing OS version all fail closed.

## Verification

- `python3 -m unittest Tests.ScriptTests.test_host_idle_validator`:
  7 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  35 tests, 0 failures.
- `python3 -m py_compile Scripts/validate-farpane-host-idle.py Tests/ScriptTests/test_host_idle_validator.py`:
  exit 0.
- `git diff --check`: exit 0.

No Swift/Rust product source changed, so no App/Core build is claimed for this
script, test, evidence, and design-only step.

## Remaining boundary

- Idle and active/static/stability summaries now retain architecture identity,
  but there is no aggregate matrix validator yet to require every section 15.2
  scenario on both architectures exactly once with passing source evidence.
- Real idle acceptance remains a 600-second installed-machine run; this step
  does not provide Apple Silicon or Intel performance data.
- The current idle authority proves no screen media route, not the absence of
  every authenticated non-screen connection; the summary continues to report
  `allAuthenticatedConnectionsProvenAbsent=false`.
- Recovery repetitions, battery idle/active, combined Host/Viewer budgets,
  Instruments traces, and all installed-machine acceptance remain open.
- No App or Agent was installed, launched, registered, or deployed. Hermes,
  CI, dependencies, database, TCC, real configuration, and secrets were not
  touched; nothing was pushed.
