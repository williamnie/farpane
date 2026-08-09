# H5.3q Bounded raw powermetrics capture wrapper

## Outcome

The privileged physical-energy authority selected by H5.3p now has a bounded
raw capture wrapper. `Scripts/sample-farpane-host-powermetrics.py` captures
only `/usr/bin/powermetrics`' NUL-separated plist stream plus strict schema-v1
metadata; it deliberately does not parse Apple-private plist fields or publish
any battery, energy-threshold, thermal-response, or section 15.2 pass claim.

The wrapper never invokes `sudo`. It fails unless the operator has already
started it as root, and ordinary FarPane, HostAgent, and performance-runner
processes remain unprivileged.

## Capture contract

- The only scenarios are `battery-idle` and `battery-active`. Acceptance runs
  require 600–1,800 seconds; explicit smoke runs allow 1–60 seconds.
- The output prefix must be absolute. Its existing parent must contain no
  symlink component, must be owned by root or `SUDO_UID`, and must not be
  group/world writable.
- The caller supplies the exact Host PID. The wrapper resolves the live macOS
  process path, accepts only `FarPane` or `RustDeskNative`, safely opens and
  SHA-256 hashes its single-link executable, and requires the same PID and
  executable identity after capture.
- Battery power is required at both start and completion. Full-window battery
  coverage remains explicitly unproven until a real raw plist parser exists.
- The fixed command uses 1,000 ms sampling and only
  `battery,cpu_power,thermal`; it does not request the `tasks` sampler or
  per-process energy-impact proxy.
- Child file output is capped at 256 MiB, stderr at 64 KiB, runtime at the
  requested duration plus 60 seconds, and raw NUL delimiter count is bounded.
- Raw and metadata files refuse overwrite and are published by hard link from
  private temporary files. Pair publication rolls back its own raw link if the
  metadata link loses a race.

## Metadata claims

Schema `farpane-host-powermetrics-raw-capture` version 1 records scenario,
mode, requested duration/count/interval, fixed samplers and authority,
machine/macOS/architecture, exact Host PID/process/executable digest, start and
completion times, wall duration, exit/stderr status, and raw artifact relative
path/SHA-256/size/NUL count.

The following fields are permanently `false` in this raw-only checkpoint:

- `rawSourceParsed`;
- `batterySourceThroughoutProven`;
- `physicalEnergyThresholdEvaluated`;
- `thermalResponseEvaluated`; and
- `section15_2Item9Complete`.

## Verification

Eleven focused tests cover acceptance/smoke limits; scenario, absolute-path,
symlink, ownership/mode and PID rejection; root/no-sudo command construction;
real non-root CLI fail-closed with zero artifacts; battery preflight; exact
executable hashing and mutation detection; a fake NUL plist producer; empty,
unseparated and excessive-delimiter rejection; raw-only metadata; and atomic
no-replace pair publication.

The physical-energy audit now reports `raw-capture-implemented`, with 10/10
evidence and 17/17 direct source anchors. Full ScriptTests passed 70/70; Python
compile, diff checks, executable permission, the arm64 Swift release build, and
an explicit non-root CLI smoke also passed.

## Remaining boundary

No real `powermetrics` capture was run: this machine is non-root and has no
installed battery. A portable-Mac raw fixture is still required before plist
parsing, full-window battery proof, physical-value extraction, paired threshold
evaluation, thermal live-log binding, and the item 9 manifest validator can be
implemented. No battery performance or item 9 pass is claimed.
