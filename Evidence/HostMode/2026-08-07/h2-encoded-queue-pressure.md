# H2.2.5 production encoded queue pressure input

- 日期：2026-08-07
- 范围：validated Rust encoded queue depth → capture cadence pressure
- 网络：未连接或修改 Hermes
- 密钥：未读取、未输出、未写入

## Outcome

The already validated, route-scoped production Rust queue sample now participates in `HostCaptureBackpressure`. For the fixed capacity-three encoded queue, current depth two applies the existing moderate 15 FPS ceiling and depth three applies the existing severe 5 FPS ceiling. Missing queue evidence remains unavailable and contributes no pressure.

The existing cadence controller still owns immediate escalation and bounded recovery: pressure drops only after a full recovery window and minimum dwell, so a one-second queue sample cannot make capture oscillate frame by frame. No queue capacity, drop policy, ABI, wire contract, server setting, or cadence threshold outside this input mapping changed.

## Key evidence

- Only `currentDepth` is used for live pressure. The route-lifetime maximum is intentionally excluded because it is sticky and would prevent recovery forever after one spike.
- Queue values enter this path only after CoreBridge validation and telemetry capacity-consistency checks.
- `depth >= capacity` is severe; `depth >= capacity - 1` is moderate. Unknown values are not treated as zero or congestion.

## Verification

1. Focused cadence/telemetry suites: 19 tests, 0 failures.
2. Tests cover depth 2/3 moderate/severe mapping, unavailable-as-none, and a validated telemetry sample reaching the same controller input.
3. Full suite with production Rust core: 94 tests, 0 failures; built-core ABI smoke executed.
4. `swift build -c release`: `Build complete`, exit 0.

## Boundary

This is local encoded-handoff occupancy, not RTT, loss, relay/direct status, encrypted connection backlog, or remote decoder pressure. Real two-machine performance behavior remains a manual acceptance step.
