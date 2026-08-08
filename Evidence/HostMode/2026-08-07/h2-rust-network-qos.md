# H2.1.8 route-scoped RustDesk QoS network evidence

- 日期：2026-08-07
- 范围：production `video_service::run_native` → RustDesk `VideoQoS` → Host event → Swift telemetry → route-stop schema v6
- 网络：本步骤未连接或修改 Hermes
- 密钥：未读取、未输出、未写入

## Outcome

production native video route now exports one low-frequency, route-scoped `mediaNetworkDiagnostic` at the existing writer/QoS one-second boundary and one final `routeStopped` sample before `stopCapture`. The sample uses the exact subscriber IDs returned by the current display route's `send_video_frame`, but exports counts and worst sampled values only; no ID leaves Rust.

The authoritative sources are RustDesk's existing `TestDelay`/`VideoQoS` state: `RttCalculator.get_rtt()` is the host-to-viewer-to-host delay estimate after its minimum sample threshold, while `UserDelay.avg_delay()` preserves RustDesk's effective network-delay semantics, including its existing RTT subtraction behavior. Users without real `TestDelay` history remain unavailable instead of inheriting the controller's 150 ms fallback.

Swift accepts only route-matching, integral and internally bounded counts, with nullable values exactly matching their sampled-subscriber counts. `HostMediaTelemetry` stores latest and route-maximum delay/RTT, rejects samples after finalization, and exports additive schema v6. The performance validator requires periodic plus final samples and real delay/RTT availability for a production acceptance run.

## Key evidence

- The QoS snapshot filters out users that did not receive the current display route and excludes unrelated users from worst values.
- Rust and Swift both enforce `qos <= subscriber`, `rtt-sampled <= delay-sampled <= qos`, and nullable-value/count consistency.
- Final queue, writer and network diagnostics are emitted before the existing `stopCapture` event.
- Evidence contains no peer/connection identifier, server, password, key, transport endpoint, packet, payload or screen data.

## Verification

1. Focused Rust QoS test: route filtering, unsampled preservation, RTT minimum-sample availability and unrelated-user exclusion pass.
2. Focused Rust Host bridge suite: 10 passed, 0 failed; malformed network snapshots are rejected and final event order includes network diagnostics before stop.
3. Focused Swift suites: 22 tests executed, 1 built-core smoke skipped until a production dylib is supplied, 0 failures.
4. Schema v6 synthetic validator smoke: complete network evidence passes; `network.finalized=false` exits 1 and preserves a `status=fail` artifact with the final-sample reason.
5. `Scripts/build-rust-core.sh`: release core built successfully as an arm64 Mach-O dylib.
6. `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`: 96 tests, 0 failures; production-core ABI smoke executed.
7. `swift build -c release`: `Build complete`, exit 0.
8. Canonical/vendor bridge byte comparison and upstream reverse-patch check pass.

## Measurement boundary

- `worstRoundTripTimeMilliseconds` is RustDesk's `TestDelay` estimate, not input-to-photon latency, remote decode/display acknowledgement, TCP/UDP handshake RTT, or a packet-loss measurement.
- `worstNetworkDelayMilliseconds` follows the pinned RustDesk QoS controller's effective-delay calculation. It is diagnostic input, not a new wire protocol or a claim of one-way clock-synchronized latency.
- Loss, direct/relay transport type, reconnect count, async encryption/send CPU and remote viewport remain unavailable in this step; no value is inferred for them.
- Synthetic validation proves the schema and fail-closed gate, not real-session performance. A two-machine route is still required to capture production values.

## Next step

Feed the validated current route delay/RTT snapshot into the adaptive capture controller as a separately bounded signal, without treating missing samples as healthy or using route-lifetime maxima for recovery. Packet loss and relay/direct must remain unavailable until an authoritative route-correlated source is found.
