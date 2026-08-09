# H5.3d Dual-architecture base performance matrix validator

## Outcome

`Scripts/validate-farpane-host-performance-matrix.py` now validates the
dual-architecture base of section 15.2 from archived run summaries. A manifest
must contain exactly twelve safe relative JSON paths: one qualifying source for
each of six requirement groups on `arm64` and `x86_64`.

The six groups are Host idle, connected static, active 1080p30, active 4K30
normal, active 4K30 video, and a 30-minute stability profile. Static and
stability each permit one of their existing 1080p/4K variants, but duplicates
within one requirement group fail closed.

The output deliberately reports
`coverageScope=section-15.2-items-1-through-6-and-8` and
`fullSection15_2Complete=false`. Recovery repetition, battery scenarios, and
combined Host/Viewer resource budgets remain outside this base matrix.

## Admission contract

- Input manifest keys and schema are exact; it contains exactly 12 unique,
  bounded, relative `.json` paths under the manifest directory.
- Source files are bounded to 1 MiB, cannot escape through `..` or a final
  symlink, and are bound into the result by SHA-256.
- Every source must use the exact current idle/performance summary schema,
  report `sampleMode=acceptance`, `status=pass`, an empty failure list, a valid
  UTC collection timestamp, a supported architecture, and a bounded machine
  model/macOS version.
- Active/static runs require at least 600 seconds; stability requires at least
  1,800 seconds and an exact matching performance profile.
- The idle source additionally requires
  `allAuthenticatedConnectionsProvenAbsent=true`. Current idle summaries
  intentionally publish `false`, so a real matrix cannot pass item 1 until the
  all-authenticated-connection authority gap is closed.
- All six sources for one architecture must use one machine model and one
  macOS version. Apple Silicon and Intel are evaluated independently.
- Output is atomic and refuses replacement. Untrusted source values are not
  copied into the aggregate unless they pass bounded validation.

## Verification

- `python3 -m unittest Tests.ScriptTests.test_host_performance_matrix_validator`:
  8 tests, 0 failures.
- The focused suite covers complete dual-architecture admission, missing Intel
  stability, smoke/failed/incomplete-idle evidence, model/OS drift, malformed
  JSON value types, path escape/duplicate source, SHA-256 binding, explicit
  incomplete-section marker, executable CLI publication, and no-replace output.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  43 tests, 0 failures.
- `python3 -m py_compile Scripts/validate-farpane-host-performance-matrix.py Tests/ScriptTests/test_host_performance_matrix_validator.py`:
  exit 0.
- `git diff --check`: exit 0.

No Swift/Rust product source changed, so no App/Core build is claimed for this
script, test, evidence, and design-only step.

## Future real-matrix usage

Create a schema-v1 manifest beside the twelve immutable run summaries, with a
`runs` array of their relative filenames, then run:

```sh
Scripts/validate-farpane-host-performance-matrix.py \
  /absolute/evidence/matrix.manifest.json \
  /absolute/evidence/matrix.run.json
```

Synthetic fixtures prove the aggregation contract only. No Apple Silicon or
Intel performance run was executed here. No App or Agent was installed,
launched, registered, or deployed. Hermes, CI, dependencies, database, TCC,
real configuration, and secrets were not touched; nothing was pushed.
