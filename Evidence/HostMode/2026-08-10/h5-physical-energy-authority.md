# H5.3p Physical-energy authority checkpoint

## Outcome

The section 15.2 item 9 physical-energy authority is selected without adding
privilege to FarPane. Machine-verifiable acceptance evidence will use raw,
NUL-separated plist output from `/usr/bin/powermetrics`, launched explicitly
by the operator as superuser during an acceptance run. FarPane, HostAgent, and
the ordinary performance runners must never request or escalate privilege and
must not embed or invoke `sudo`.

The new executable audit reports `privileged-authority-selected`. It does not
claim that a capture runner, parser, threshold, battery validator, or real
battery run already exists.

## Local authority evidence

Read-only checks on 2026-08-10 established the current macOS boundary:

- `/usr/bin/powermetrics --help` advertises machine-readable plist output,
  NUL-separated records, and the `battery`, `cpu_power`, `thermal`,
  `gpu_power`, and `ane_power` samplers.
- The installed `powermetrics(1)` manual says subsystem power is estimated and
  may be inaccurate, must not be compared across devices, and is suitable for
  same-device energy optimization. It describes per-process energy impact as a
  rough, platform-specific proxy rather than a physical unit.
- The manual describes battery discharge-rate and charge-level evidence as
  useful over longer intervals, while warning about short-window aliasing,
  sleep/wake discontinuities, AC transitions, and cross-model comparison.
- Running one non-writing, non-privileged `cpu_power` plist sample exited 1
  with `powermetrics must be invoked as the superuser`.
- The current machine's read-only `AppleSmartBattery` registry reports
  `BatteryInstalled=0`; it therefore cannot provide the portable-Mac raw plist
  fixture needed to implement and verify a parser.

No `sudo` command was run and no system setting, power state, or evidence file
was changed by these probes.

## Frozen capture contract

- The raw authority is `/usr/bin/powermetrics --format plist`; minimum
  acceptance samplers are `battery,cpu_power,thermal`. Optional SoC samplers
  may be retained when supported but cannot make a run mandatory on one CPU
  architecture and impossible on the other.
- A qualifying battery window is at least 600 seconds at a 1,000 ms sample
  interval and must be bound to the exact scenario, Host PID, machine/macOS,
  and Host executable digest.
- Raw bytes, command metadata, and declared SHA-256 must be preserved with
  bounded size/count and no-replace atomic publication.
- Battery source must cover the complete window. Estimated power and battery
  discharge are compared only against a paired baseline from the same portable
  Mac, macOS, and build.
- Per-process energy impact and `top POWER` remain diagnostic proxies, not
  joules or watt-hours. Instruments Energy Log remains manual corroboration,
  not the machine-readable authority.
- The capture tool itself may require that it was already launched as root,
  but may not invoke `sudo`; the product may never request or escalate root.

## Machine audit

`Scripts/audit-host-physical-energy-authority.py` verifies nine source facts
and nine anchors: the existing H2 authority statement, the operator-only raw
plist/privilege/same-machine contract, the current sampler's non-physical
unit, H5.3o's physical authority and threshold requirements, item 9's matrix
exclusion, absence of product privilege invocation, and absence of a not-yet-
implemented capture runner/validator.

The matching ScriptTest freezes the selected executable, raw format, sampler
minimum, explicit privilege boundary, 600-second/1 Hz capture contract, and
the prohibition on guessing a plist schema before a real fixture exists.

## Verification

- `python3 -m unittest Tests.ScriptTests.test_host_physical_energy_authority_audit`
  — 1/1 passed.
- `python3 Scripts/audit-host-physical-energy-authority.py` —
  `privileged-authority-selected`, 9/9 evidence and 9/9 source anchors.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'` — 59/59
  passed.
- Python compile, diff checks, executable permission, and the arm64 Swift
  release build passed.

## Remaining boundary

No capture runner or plist parser was implemented because the current machine
has no installed battery and therefore cannot produce a truthful portable-Mac
fixture. A paired baseline and quantitative acceptance threshold also remain
undefined. The next automatic step can implement the bounded raw capture
wrapper without parsing values; parser and item 9 validator work must wait for
a real portable-Mac raw artifact so the schema is not invented. No item 9 pass
is claimed.

Historical update: H5.3q subsequently implemented the bounded root-preflight,
no-sudo raw capture wrapper and advanced this audit to
`raw-capture-implemented`. The portable-Mac fixture/parser, full-window battery
proof, paired threshold, thermal correlation, validator, and real runs remain
open.
