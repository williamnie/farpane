# H2.3.4 six-reason drop telemetry evidence

> 历史说明：本步的 schema v2 正确记录了当时 `captureSuperseded` 尚未 instrument。H2.3.5 随后按设计接入 capacity-2 raw-frame handoff，并以 additive schema v3 增加 queue depth；见 `h2-raw-frame-handoff.md`。

- 日期：2026-08-07
- 范围：单 route Swift capture/encode/Host Media submit drop 分类与显式 evidence schema v2
- 不包含：Hermes/Rust writer/transport 修改、真实网络拥塞、Instruments、性能结论或远端解码验收

## Outcome

- 固定六类原因：`captureSuperseded`、`encoderBackpressure`、`networkBackpressure`、`reconfigure`、`invalidFrame`、`shutdown`。
- 已接生产观测点的五类以非可选计数开始于 0；`captureSuperseded` 因当前没有应用层 raw-frame handoff，明确保持 `instrumented=false`，不伪造 0。
- 未知 Host Media code 进入 `unclassified`，不按错误字符串猜测；`classified`、`unclassified`、`total` 提供完整性核对。
- VideoToolbox 同步/异步 drop 会恢复下一帧 keyframe；异步回调携带归一化 PTS，drop 后 encode in-flight 收敛。
- route-stop JSON 以原 v1 allowlist 加一个 `drops` 顶层对象升级为 schema version 2；写入仍默认关闭、显式绝对 `.json`、原子发布且拒绝覆盖。

## Production source map

| reason | source | evidence state |
|---|---|---|
| `captureSuperseded` | H2.3.4 当时尚无应用层 raw-frame queue | `instrumented=false`, no count |
| `encoderBackpressure` | VT `FrameDropped` / encoder temporarily unavailable | instrumented |
| `networkBackpressure` | `RDN_HOST_ERR_BACKPRESSURE` | instrumented |
| `reconfigure` | stale epoch / old encoder generation output | instrumented |
| `invalidFrame` | invalid SCK/VT sample or known media validation reject | instrumented |
| `shutdown` | bad state / callback after route cancel | instrumented |

SCK `idle/blank/suspended/started/stopped` 表示未生成新的 complete frame，不计作 `captureSuperseded`。未知/未来 C ABI code 不映射到六类，避免假证据。

## Focused verification

```text
swift test --filter 'HostMediaTelemetryTests|HostMediaTelemetryEvidenceTests|CoreBridgeContractTests|HostH264EncoderTests|HostHEVCEncoderTests'
Executed 17 tests, with 1 test skipped and 0 failures.
```

本机硬件 H.264/HEVC 编码测试均实际运行并通过；跳过项是未设置 `RDN_CORE_LIBRARY` 的 built-core smoke，不属于本步改动回归。

## Remaining boundary

- deterministic 测试证明分类、聚合、序列化和当前硬编主路径，不构成真实 drop 发生证据。
- H2.3.5 已补生产源；仍需在强制 Rust queue full/正式拥塞场景中保存最新 schema JSON，核对 `unclassified=0`、IDR recovery 与远端持续解码。
