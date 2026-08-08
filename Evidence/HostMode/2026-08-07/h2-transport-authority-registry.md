# H2.1.9a connection transport authority registry

- 日期：2026-08-07
- 范围：inbound connection creation → connection-ID lifetime → route-scoped aggregate lookup
- 网络：本步骤未连接 Hermes，未修改服务端
- 密钥：未读取、未输出、未写入

## Outcome

The pinned Host core now retains the authoritative direct/relay fact that was previously discarded when connection creation converged on `Connection::start`.

An internal `ConnectionTransportRegistration` is created immediately after the Host allocates a connection ID. The existing public `create_tcp_connection` path classifies direct access, intranet/TCP punch, IPv6 and KCP direct streams as `Direct`; only `create_relay_connection_` calls the internal helper with `Relay`. The registration guard remains alive across secure handshake and the full `Connection::start` lifetime, then removes the mapping on handshake error or connection exit.

`route_transport_snapshot` accepts the exact current display route subscriber-ID set and returns aggregate subscriber/direct/relay/unknown counts. It does not export connection IDs or server endpoints. Unknown IDs remain explicit instead of being guessed as direct or relay.

## Key evidence

- No existing public function signature, `ConnectionMeta`, authenticated registry, C ABI, wire message or Swift contract changed.
- All non-relay creation call sites retain their existing call to `create_tcp_connection`; the explicit relay path alone uses `ConnectionTransport::Relay`.
- Registry insertion occurs only after a unique connection ID exists.
- RAII cleanup covers authentication failure, secure-handshake failure, normal close and error close because the guard encloses the complete connection future.
- Route aggregation is read-only, bounded by the supplied subscriber set and contains counts only.

## Verification

1. Focused Rust test constructs direct, relay and unknown route members, verifies `1/1/1`, drops direct and verifies `0/1/2`, then drops relay and verifies all three unknown.
2. The Rust library test target compiles with `rdn-native-host`; existing upstream warnings remain and the focused test reports 1 passed, 0 failed.
3. `Scripts/build-rust-core.sh` completes a production arm64 Rust core build.
4. `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test` loads that new core and passes all 98 Swift tests with 0 failures.
5. `swift build -c release` succeeds. The resulting executable and Rust dylib were assembled into `Build/FarPane-arm64-h2-transport-authority-preview.app` and `.zip`; the app and a freshly extracted zip copy both pass strict deep signature verification, and both Mach-O payloads report arm64.
6. Upstream patch reverse-check, bridge-source byte comparison and repository whitespace check pass.

## Boundary

This step establishes authority only. It does not yet emit a Host event, change schema v6, alter QualityController, or claim a real session used direct or relay. H2.1.9b must separately join the registry snapshot to the current video route, fail closed on unknown counts, export a sanitized schema revision and capture real two-machine evidence.

Packet loss and reconnect remain unavailable; this registry is not a proxy for either metric.

## Next step

Add a low-frequency route transport diagnostic beside the existing H2.1.8 network sample, preserving unknown counts and final-before-stop ordering, then extend Swift/evidence/validator as an additive schema v7 step.
