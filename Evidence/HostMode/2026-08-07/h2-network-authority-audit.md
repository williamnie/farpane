# H2 route-scoped loss / reconnect / transport authority audit

- 日期：2026-08-07
- 范围：pinned RustDesk 1.4.9 inbound connection creation → authenticated connection registry → display route subscriber IDs
- 代码：本步骤只读审计，没有修改 connection contract、wire、ABI 或 Hermes
- 密钥：未读取、未输出、未写入

## Outcome

No existing production source can truthfully export route-scoped packet loss, reconnect count, or direct/relay transport for the current FarPane Host media route.

The exact display-route subscriber IDs returned by `GenericService::send_video_frame` can currently join only to `VideoQoS`, which is why H2.1.8 can safely export `TestDelay`-derived effective delay/RTT. The authenticated connection registry does not retain transport metadata, and the Host does not maintain an unambiguous reconnect counter.

These fields must remain unavailable. `response_delayed`, frame-controller timeouts, queue drops, new connection IDs, session-key reuse, and rendezvous registration retries are not substitutes for packet loss, media-session reconnect, or direct/relay classification.

## Key evidence

### Direct / relay

- Relay creation is authoritative at `rendezvous_mediator::create_relay` → `server::create_relay_connection`.
- Direct paths are separately visible at intranet/TCP punch, KCP UDP punch, IPv6 and direct-access listener branches.
- All paths converge on `create_tcp_connection`/`Connection::start` without a transport field.
- `ConnectionMeta` currently carries only control permissions and controlled context.
- `AuthedConn` retains connection ID, authenticated connection type, session key, sender and printer capability, but no direct/relay/KCP/TCP classification.
- Therefore the current display route's connection IDs cannot be joined to a transport fact after authentication.

### Reconnect

- `ui_session_interface.reconnect_count` belongs to the controlling/client session, not the controlled-side Host connection.
- A Host reconnect arrives as a new inbound `Connection` with a new connection ID.
- Session-key continuity cannot distinguish a network reconnect from a parallel or intentional new authenticated connection and would introduce identity/lifecycle sensitivity.
- Rendezvous registration retries describe Host-to-rendezvous availability, not an active media route reconnect.

### Loss

- The Host media route has no packet sequence/loss counter at its application boundary.
- Direct TCP, relay TCP and KCP reliability operate below the encoded-frame service; TestDelay history and response timeout expose delay/availability symptoms, not a packet-loss percentage.
- Rust queue backpressure and writer confirmation timeout are local/application events and must not be relabeled as network loss.

## Safe future implementation boundary

A truthful transport metric requires a new internal enum carried from every authoritative connection-creation branch through `ConnectionMeta` → `Connection` → authenticated connection registry, followed by an aggregate lookup restricted to the current display route's subscriber IDs. Tests must cover direct access, TCP punch/intranet, KCP direct and relay, plus mixed-subscriber aggregation and route teardown.

This crosses the shared connection metadata/registry and several creation paths. It should be implemented as its own reviewed step, not folded into telemetry by inference. Loss and reconnect need separate authoritative designs; neither should reuse the transport change as a proxy.

## Verification

- Exhaustive symbol/call-site search covered `accept_connection`, `create_tcp_connection`, `create_relay_connection`, direct/KCP/IPv6 branches, `ConnectionMeta`, `Connection`, `AuthedConn`, `AuthedConnID`, `reconnect_count`, TestDelay and frame acknowledgement paths.
- Current H2 patch reverse-check and canonical/vendor bridge sync remain independent of this audit.

## Next step

Keep loss/reconnect/transport absent from schema v6 and QualityController. If the internal transport metadata expansion is accepted as the next architecture step, implement transport only with complete branch coverage; otherwise proceed to the real two-machine H2 performance run and retain the missing metrics as explicit exit-gate gaps.
