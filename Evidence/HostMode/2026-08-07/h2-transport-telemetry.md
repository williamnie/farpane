# H2.1.9b route-scoped transport telemetry

- 日期：2026-08-07
- 范围：authoritative connection transport registry → current display route → Rust event → Swift telemetry → schema v7 evidence
- 网络：本步骤未连接 Hermes，未修改服务端
- 密钥：未读取、未输出、未写入

## Outcome

The production Host video-service loop now joins the exact subscriber-ID set returned by `GenericService::send_video_frame` to the H2.1.9a connection-lifecycle registry once per low-frequency diagnostic interval. It emits only aggregate `subscriberCount`, `directSubscribers`, `relaySubscribers` and `unknownSubscribers` values through a dedicated `mediaTransportDiagnostic` event.

The event is separate from `mediaNetworkDiagnostic`, so a missing or invalid transport sample cannot discard otherwise valid RustDesk QoS delay/RTT evidence. Rust and Swift both require the direct/relay/unknown counts to partition the complete subscriber set. Unknown remains explicit and is never inferred as direct or relay.

The latest transport snapshot is retained by the route and emitted as `routeStopped` before `stopCapture`, including host unbind teardown. Swift accepts only the current route, rejects inconsistent counts and rejects samples after finalization. Route-stop evidence is additive schema v7 with a sanitized `transport` object.

## Key evidence

- No connection ID, peer ID, server address, endpoint, password, key, packet, payload or screen data crosses the event boundary.
- Direct/relay authority still originates only at the connection-creation branches covered by H2.1.9a; the telemetry layer performs no classification.
- The same exact current video-route subscriber set feeds both the QoS snapshot and transport snapshot.
- `unknownSubscribers` is retained in schema v7. The real performance validator fails closed while any current route subscriber lacks authoritative classification.
- Packet loss and reconnect remain unavailable and are not derived from transport type.

## Verification

1. Rust transport telemetry test accepts a complete mixed partition, rejects inconsistent counts and verifies the payload allowlist.
2. Rust route-stop ordering test verifies periodic queue/writer/network/transport samples, then final queue/writer/network/transport samples, then `stopCapture`.
3. CoreBridge parser test verifies route matching, unknown preservation, integer bounds, complete partition and sanitized payload.
4. Swift telemetry test verifies sample replacement, inconsistent partition rejection and no sample after finalization.
5. Evidence allowlist test verifies schema v7 and the exact six-field `transport` object.
6. Validator synthetic smoke passes a fully classified direct route and preserves a fail result for an otherwise identical route with one unknown subscriber.

Fresh results:

- `cargo test --features rdn-native-core,rdn-native-host --lib`: 94 passed, 0 failed.
- `Scripts/build-rust-core.sh`: production arm64 dylib built successfully.
- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`: 100 passed, 0 failed, including built-core ABI loading.
- `swift build -c release`: succeeded.
- `Build/FarPane-arm64-h2-transport-telemetry-preview.app` and `.zip`: executable and dylib are arm64; the app and a freshly extracted zip copy both pass strict deep signature verification.
- Pinned upstream patch reverse-check, canonical/vendor bridge byte comparison, Python syntax check, shell syntax checks, repository whitespace check and changed-file credential-pattern scan pass.

## Boundary

This is production-path code plus deterministic local verification, not a claim that the current two-machine session used direct or relay. A real FarPane Viewer session must generate schema v7 route-stop evidence before any real transport classification or performance result is reported.

## Next step

Run the existing real-session performance scenario on the Mac mini after installing the new preview and confirm `transport.metricSamples > 1`, `unknownSubscribers == 0` and `transport.finalized == true`. Overnight automatic work can continue with a separate authority audit for the remaining encryption/send CPU, loss and reconnect metrics without inventing substitutes.
