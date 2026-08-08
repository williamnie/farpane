# H2.1.10 encryption/send CPU, packet loss and reconnect authority audit

- 日期：2026-08-07
- 范围：current display route → connection writer → encrypted transport，以及 Host authenticated connection lifecycle
- 代码：本步骤只读审计，没有增加 telemetry 字段或修改 transport/session contract
- 网络：未连接 Hermes，未修改服务端
- 密钥：未读取、未输出、未写入

## Outcome

The current production Host has no route-correlated source that can truthfully populate encryption/send CPU, packet-loss percentage, or media reconnect count. These values therefore remain unavailable rather than being exported as zero or inferred from nearby symptoms.

The three gaps have different owners. Encryption/send CPU needs connection-aware synchronous CPU accounting inside the transport writer. Loss needs transport-specific counters that are not exposed through the current erased stream abstraction. Reconnect needs a product-defined Host control-session recovery identity; a new inbound connection is not sufficient evidence.

No schema v8 was created, and H2's real-session validator continues to judge only metrics with production authority.

## Key evidence

### Encryption / send CPU

- `ConnInner::send` only queues a `(timestamp, message)` pair. The connection task later receives it from `rx_video` and awaits `conn.stream.send(message)`.
- When `video_ack_required` is false, `notify_video_frame_fetched` runs before that awaited stream send. The existing frame-controller confirmation therefore cannot prove socket-send completion.
- `Stream::send` dispatches to TCP, WebSocket or WebRTC. TCP then performs protobuf serialization, optional `secretbox` encryption and an asynchronous framed socket write.
- Timing the whole `await conn.stream.send(...)` would mix serialization, encryption, Tokio scheduling, downstream backpressure and kernel/socket wait. It is wall time, not CPU time.
- A per-thread CPU clock around that await would also be invalid because an async task may resume on another Tokio worker. The current stream types carry neither route/connection telemetry context nor a synchronous CPU measurement hook.

### Packet loss

- Direct and relay TCP are reliable byte streams below the Host media service. `DynTcpStream(Box<dyn TcpStreamTrait>)` erases the concrete socket and exposes no raw descriptor or TCP retransmission statistics.
- KCP is also wrapped as `Stream::Tcp`. The pinned `kcp-sys` safe API exposes `waitsnd()` and `sendwnd()`, but no loss or retransmission statistic.
- The underlying KCP control block has internal transmission/RTO fields, but the pinned Rust wrapper does not expose them. Aggregate transmissions would not by themselves define a loss percentage.
- Exposing KCP internals would require modifying/forking the pinned dependency, while TCP/WebSocket would still need separate platform-specific providers and availability semantics.
- QoS delay, response timeout, encoded-queue backpressure, writer errors and frame-controller timeouts are symptoms or local events, not packet loss.

### Host media reconnect

- `ui_session_interface.reconnect_count` belongs to the controlling/client session. It is not updated by the controlled-side inbound Host path.
- A Host reconnect creates a new inbound `Connection` and new connection ID.
- The Host `SessionKey` is `(peer_id, name, session_id)`, but the authenticated registry explicitly supports concurrent connections sharing a session key: a remote-control connection may coexist with file-transfer or port-forward connections, and session cleanup has special handling for another remote connection.
- Counting new connection IDs or repeated session keys would therefore conflate recovery, parallel features and intentional new sessions. Rendezvous registration retries are Host-to-server availability, not recovery of the active media route.

## Rejected proxies

- subscriber dispatch wall or frame-controller confirmation wall as encryption/send CPU;
- process-wide CPU delta as encryption/send CPU;
- `TestDelay`, response-delayed state, queue drops or socket errors as packet loss;
- connection-open count, session-key reuse or rendezvous retry count as media reconnect.

## Safe future architecture boundary

1. **Encryption/send CPU:** add a connection-aware transport instrumentation contract and isolate synchronous serialization/encryption work from async socket wait. CPU accounting must have defined units and valid task/thread attribution.
2. **Loss:** define a transport-specific optional metric provider for TCP/KCP/WebSocket, including numerator, denominator, interval/reset semantics and unavailable behavior. This likely crosses platform socket access and the pinned KCP dependency.
3. **Reconnect:** define the Host control-session recovery identity and generation/predecessor relation, including how parallel remote/file/port-forward connections and close reasons are treated. This belongs with H5 recovery/session work unless the product contract is explicitly advanced.

Each item is a separate architecture change. None should reuse the direct/relay registry or schema v7 transport counts as a proxy.

## Verification

- Inspected the production video writer path from `rx_video` through `Stream::send`, TCP protobuf serialization, `secretbox` encryption and async framed send.
- Searched the Host/core sources for per-thread/process CPU APIs, raw-socket TCP statistics and retransmission counters; none are connected to the route writer.
- Inspected the pinned `kcp-sys` safe API and its underlying KCP control block; only queue/window primitives are exposed to FarPane.
- Inspected `SessionKey`, `AuthedConn`, `AuthedConnID`, client `reconnect_count` and session cleanup behavior for parallel authenticated connections.

This is source-backed authority evidence only. No build or runtime result is claimed for this documentation-only step.

## Next step

Continue with an automatically measurable H2 item, starting with sleep-assertion state/ownership telemetry or another §15.1 local metric. The Mac mini real-session runner remains the required path for actual 1080p30/4K30 performance evidence; these three unavailable metrics must not block other safe automatic work or be fabricated to make that run pass.
