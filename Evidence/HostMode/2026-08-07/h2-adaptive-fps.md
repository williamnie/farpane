# H2.2.1–H2.2.4 adaptive capture cadence evidence

- Date: 2026-08-07 (Asia/Shanghai)
- Scope: deterministic dirty-rect policy and production `SCStream.updateConfiguration` wiring
- Privacy: no frame content, peer identity, server configuration or credentials are recorded

## Implemented boundary

- `HostCaptureCadenceController` maps trusted dirty-area history to bounded 3/12/30/60 FPS tiers without exceeding the negotiated session cap.
- Demotion requires a full rolling window; promotion can use the latest dirty frame. Trusted-state transitions use a two-second minimum dwell, while metadata loss bypasses dwell and fails safe immediately.
- State-specific hold thresholds provide hysteresis below each entry threshold.
- Missing or non-finite dirty metadata clears history and immediately restores high-motion content demand. With no active backpressure this returns to the negotiated cap; an active pressure ceiling remains authoritative. Unknown metadata is never interpreted as a permanently static desktop.
- `HostScreenCaptureAdapter` applies the selected tier through a complete `SCStreamConfiguration`, preserving dimensions, pixel format, queue depth and cursor policy.
- At most one asynchronous update is in flight. A failed update leaves the last applied FPS authoritative and waits two seconds before retrying; completions from an old stream are ignored.

## Deterministic verification

`HostCaptureCadenceTests` covers:

1. full-window plus dwell gating before a 60 → 3 FPS idle demotion;
2. no immediate reverse transition inside the minimum dwell, followed by high-motion recovery;
3. state-specific hysteresis across interactive → lowMotion → idle;
4. `nil` and `NaN` metadata fail-safe to the negotiated cap;
5. every tier bounded by a 15 FPS negotiated maximum;
6. the production configuration builder emitting 1/12 and capped 1/30 `minimumFrameInterval` values without changing the capture contract.
7. immediate moderate encode-pressure capping at 15 FPS, followed by recovery only after a complete window and two-second dwell;
8. a 25% send-drop window applying a severe 5 FPS ceiling even when dirty metadata is missing;
9. encode-latency thresholds derived from the negotiated frame budget.
10. nominal/unknown thermal state producing no synthetic pressure, fair/serious and Low Power Mode producing moderate pressure, and critical producing severe pressure.

## Cadence lifecycle telemetry

- Every valid-frame decision records only content-state, target FPS and whether dirty metadata was trusted.
- Configuration submission, success, failure and cancellation are distinct events; success alone changes applied FPS.
- Snapshot counters cover state transitions, attempts, applied updates, failures, cancellations and in-flight state.
- A deterministic telemetry test verifies a repeated idle decision counts one transition, a failed 3 FPS update retains the negotiated 30 FPS applied value, a successful 12 FPS update advances it, and cancellation clears in-flight state.
- Real authorized H.264 and HEVC pipeline tests verify the initial cadence snapshot remains at the negotiated 15 FPS without fabricating an update before the rolling-window/dwell gate.
- No cadence event contains frame content, dirty-rect coordinates, process/peer/connection identity, server configuration, credential material or raw error text.

## Bounded encode/send pressure

- The capture callback reads a lightweight pressure view rather than sorting the full latency sample set.
- Moderate pressure is triggered by encode in-flight ≥2, latest latency ≥2 frame budgets, two consecutive drops, or a ≥12.5% drop rate with at least eight recent outcomes; it caps capture at 15 FPS.
- Severe pressure uses thresholds of 4, 4 frame budgets, four consecutive drops, or ≥25%; it caps capture at 5 FPS.
- Escalation is immediate. Recovery requires a full cadence window plus the two-second minimum dwell.
- Send outcomes use a fixed 32-entry overwrite ring. A test wrote 40 outcomes and verified the retained count stayed 32 with an exact 25% drop rate and severe classification.
- Snapshot evidence now includes pressure level/transitions, latest encode latency, recent outcome count/rate and consecutive drops.

## Thermal and Low Power input

- The pressure provider reuses the latest one-second `HostProcessSampler` telemetry; the capture callback does not resample ProcessInfo, IOKit or Mach.
- `fair` and `serious` map to the existing moderate 15 FPS ceiling, `critical` maps to the severe 5 FPS ceiling, and Low Power Mode guarantees at least moderate pressure.
- `nominal` and `unknown` do not create pressure. Unknown remains explicit in the underlying telemetry and cannot be reported as nominal evidence.
- Environment pressure combines with encode/send pressure by severity and uses the same bounded recovery gate.
- Deterministic tests cover every mapping and immediate escalation. A real sampler test confirms the pressure view receives the same thermal/Low Power values as the telemetry snapshot, but the OS thermal state was not artificially forced; this is not heat-soak evidence.

## Limitation

This evidence proves the policy, production API wiring, in-process telemetry accounting and Swift-side encode/send/thermal/Low Power feedback, not a performance improvement. Rust writer queue depth, RTT/loss and explicit viewport changes are not yet inputs, and the snapshot is not yet exported to an evidence artifact. A qualifying 10-minute Mac mini run plus Instruments trace remains required before making CPU, energy or quality claims.
