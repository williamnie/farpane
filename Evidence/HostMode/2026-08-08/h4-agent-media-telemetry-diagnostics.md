# H4.1w Agent-owned route telemetry diagnostics

## Outcome

禁用的 HostAgent 产品组合现在拥有 route-scoped 媒体诊断 authority：Rust 已有的媒体 ACK、encoded queue、writer timing、QoS network 和 transport 聚合会在通用事件转发前进入同一 SCK/VT route telemetry。当前 route 停止后仅保留一条有界 final telemetry，供后续 authenticated XPC component snapshot 使用；本步没有定义或启用 XPC。

## Key evidence

- `HostAgentMediaPipelineOwner.consume(_:)` 只识别五个既有 typed media diagnostic event；非媒体事件忽略，已识别但严格解析失败的事件只增加 saturating rejection count。
- numeric decoder 对全部五类诊断统一拒绝 JSON boolean、负数、小数、非有限值及既有字段上限之外的数值，避免 `true` 被解释成 epoch 1。
- media dispatch/ACK/refresh 必须 exact match connection epoch、codec epoch、display ID/revision、codec，且 framing 必须为本地编码路径实际使用的 AVCC；refresh dispatched 还必须同时携带 keyframe 与 parameter sets。
- queue/writer/network/transport 只通过 `HostMediaPipelineRouteOwner` 更新 exact route 的 `HostMediaTelemetry`，继续复用现有 capacity、monotonic cumulative counts、sample availability 和 complete transport partition 校验。
- owner 在 current pipeline 与 last completed snapshot 之间增加仅在 stop drain 期间存在的 retiring telemetry；因此 Rust 的 `routeStopped` final sample 即使与异步 SCK/VT stop 重叠也不会丢失或误写下一 route。
- completed history 固定只保留一条；更旧 route、未知 route、finalization 后追加或内部不一致样本全部 fail closed，并保留 rejected telemetry update count。
- 普通 control/diagnostic admission 使用最多 current/desired/retiring/completed 四个 identity 的轻量查询，不在 Host event callback queue 调用完整 telemetry snapshot 或排序 encode latency samples。
- typed component snapshot 包含 lifecycle/capability 状态、能力失败、pipeline start/runtime failure、控制/诊断接受与拒绝计数、pending lifecycle operations，以及 active/final aggregate telemetry；不含 server/key、peer、屏幕内容、encoded bytes payload 或底层 Error。
- termination 将 owner 置为 cancelling 后等待已进入的 diagnostic consumer，再 cancel/drain route pipeline；停止后的新诊断不能进入 telemetry。
- 修复了 `reconfigure(new) → immediate stop(new)` 的竞态：排队的新 route 被取消时，同时停止已被它逻辑替代的旧 active pipeline，不再遗留采集。
- `RustDeskNativeApp.swift` 仍不创建该 component snapshot 或调用 `HostAgentProcess.run`，`--host-agent` 继续 fail closed；本步也未迁移本地 live telemetry writer。

## Verification

- TDD RED：新增 route telemetry API/snapshot 不存在时测试编译失败；queued replacement immediate stop 回归测试随后真实复现旧 active route 仍存活，再经定向 Green 验证修复。
- 定向 route owner 10、五类 diagnostic decoder 5、产品 source composition 1：16 tests，0 failures。
- `swift test`：260 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一小步应让 Agent 自己持有按 route 创建、每秒有界写入并在 stop/failure final flush 的 sanitized live telemetry writer，使无需复制 HUD 文本即可直接读取 Mini 本地日志；之后再把 component snapshot 放入 authenticated/versioned XPC snapshot-first 合同。Agent 入口启用、SMAppService、真机 TCC/断线/锁屏/休眠及长时性能验收仍未完成。
