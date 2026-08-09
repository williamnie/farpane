# H5.3o Battery and thermal evidence authority audit

## Outcome

Section 15.2 item 9 remains open, but its current evidence boundary and next
contract are now machine-auditable. The executable audit reports
`checkpoint-required`: FarPane already records battery/AC source, thermal
pressure, Low Power Mode, typed Host sleep assertions, and the live media
pressure/cadence state. The existing idle and active validators also prove
their respective route and assertion lifecycles.

Those facts do not yet prove item 9. The system sampler labels `top`'s POWER
column as `top-relative-not-joules`, and neither current validator consumes the
power-source, thermal, or energy columns. A route-stop snapshot is also only a
final aggregate and cannot prove that a serious/critical thermal observation
caused the live 15/5 FPS pressure ceiling during the same window.

## Frozen boundary

- Battery idle must bind a complete, at least 600-second
  `host-ready-no-screen-route` run whose every system sample is on battery,
  with zero authenticated connections, no media route/pipeline, and no Host
  sleep assertion.
- Battery active must bind a complete, at least 600-second passed production
  `1080p30` route whose system and media samples stay on battery, whose
  user-idle assertion covers the active route, and whose display-sleep
  assertion remains absent.
- Both runs must use the same portable Mac, build, and macOS identity, with
  bounded SHA-256-bound sources and fail-closed path/overwrite handling.
- Energy acceptance requires a named physical authority and unit, complete
  window coverage, and an explicit baseline/threshold. Relative `top` POWER,
  one battery percentage, or an Activity Monitor screenshot cannot substitute.
- Thermal acceptance requires a bounded per-sample series. If serious or
  critical pressure occurs, the same live media series must prove the thermal
  cause and the corresponding cadence degradation.

## Evidence

`Scripts/audit-host-battery-thermal-evidence.py` checks nine source-level facts
and thirteen direct source anchors:

- the design's battery idle/active, thermal, and idle-assertion requirement;
- sampler scenario admission, per-sample power/thermal/assertion fields, and
  explicit non-physical POWER unit;
- idle zero-connection/route/assertion gates;
- active production-route and typed assertion gates;
- the absence of battery/energy/thermal semantics in the current validators;
- production power/thermal/Low Power sampling and live pressure-cause logging;
- serious/critical pressure mapping to the 15/5 FPS cadence ceilings; and
- the base matrix's explicit item 9 exclusion.

The matching ScriptTest fails if any authority marker disappears, if the audit
stops reporting the checkpoint, or if the forbidden inference list is weakened.

## Verification

- `python3 -m unittest Tests.ScriptTests.test_host_battery_thermal_evidence_audit`
  — 1/1 passed.
- `python3 Scripts/audit-host-battery-thermal-evidence.py` —
  `checkpoint-required`, 9/9 evidence and 13/13 source anchors.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'` — 58/58
  passed.
- Python compile, diff checks, executable permission, and the arm64 Swift
  release build passed.

## Remaining boundary

No physical energy authority, quantitative acceptance threshold, battery
idle/active validator, or thermal live-log binding is implemented by this
checkpoint. No installed portable-Mac battery or heat-soak run was performed,
and no section 15.2 item 9 pass is claimed. The next automatic step is a
separate physical-energy authority checkpoint; only after that decision is
concrete should the bounded item 9 validator be implemented.
