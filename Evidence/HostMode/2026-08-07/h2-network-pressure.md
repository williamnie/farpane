# H2.2.6 current route network pressure evidence

- 日期：2026-08-07
- 范围：validated H2.1.8 QoS snapshot → `HostMediaTelemetry.captureBackpressure()` → adaptive capture cadence
- 网络：本步骤未连接 Hermes
- 密钥：未读取、未输出、未写入

## Outcome

The adaptive capture controller now consumes only the latest validated route-scoped RustDesk effective network delay, RTT and response-delayed subscriber count. Missing network samples remain unavailable and add no pressure. Route-lifetime maximum values stay evidence-only, so a recovered current sample can pass through the existing full-window plus minimum-dwell recovery gate.

The bounded thresholds are:

- moderate: effective network delay at least 150 ms or RTT at least 250 ms;
- severe: effective network delay at least 300 ms, RTT at least 500 ms, or any current response-delayed subscriber.

Existing pressure semantics remain unchanged: escalation is immediate; recovery needs a complete observation window and minimum dwell; moderate caps capture at 15 FPS and severe at 5 FPS, both still bounded by the negotiated maximum.

## Key evidence

- The input is the current H2.1.8 sample after route/count/availability validation, not an untrusted event payload.
- `nil` delay/RTT and no network sample do not become zero-valued evidence or a healthy-network claim.
- A prior severe sample remains in route maximum evidence but does not permanently pin cadence after a recovered current sample.
- No packet-loss, relay/direct, remote viewport or end-to-end latency value is inferred.

## Verification

1. Focused cadence/telemetry suites: 22 tests, 0 failures.
2. Threshold tests cover just-below/at moderate, at severe, response-delayed and unavailable inputs.
3. Telemetry test proves a 350/550 ms severe sample followed by 80/100 ms current sample recovers to no observed pressure while maxima remain 350/550 ms.
4. `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`: 98 tests, 0 failures; production-core ABI smoke executed.
5. `swift build -c release`: `Build complete`, exit 0.

## Next step

Run a real two-machine session and retain schema v6 route evidence to confirm sampled values and cadence transitions under a controlled network. Loss and relay/direct remain open until an authoritative route-correlated source is identified.
