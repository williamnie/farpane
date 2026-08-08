# H4.1x Agent-owned sanitized media live log

## Outcome

禁用的 HostAgent 产品组合现在持有自己的媒体 live-log 生命周期：每条成功 route 在 Mini 用户目录的 `Library/Logs/FarPane/HostMedia` 创建独立 JSONL，记录 `routeStarted`、最多每秒一次的 periodic telemetry 和排空后的 `routeStopped`；pipeline 构造或启动失败也会留下单条 `routeStartFailed`。因此后续启用 Agent 后，即使 GUI 不在或意外断连，Mini 本地仍可保留脱敏性能证据。本步没有启用 Agent 入口，也没有用测试触碰真实用户日志目录。

## Key evidence

- `HostMediaPipelineRouteOwner` 新增 typed lifecycle observer；只有 pipeline 真正启动成功才发出 started，replacement/stop 完成 capture/encoder drain 后才发出 stopped，factory/start failure 只发出 startFailed。
- lifecycle callback 沿既有串行 route operation queue 发生，replacement 固定为 `old stopped → new started`；未激活即被 supersede/cancel 的 pipeline 不伪造 started/stopped。
- `HostMediaPipelineLiveLogCoordinator` 只在内存中用完整 route identity 做 exact correlation，不把 identity 传给 writer；旧 route 的迟到 stopped 不能封口当前 route。
- writer 继续复用既有 schema v3 allowlist，排除 local/peer ID、server、credential/key、display ID、路径、屏幕内容和 encoded payload；底层文件错误不保留、不输出，只累计 saturating failure count。
- 默认 writer 每条 route 的 periodic record 上限仍为 3,600，且 writer 自身强制至少间隔 1 秒；start/stop/failure lifecycle record 不受 periodic 配额影响。
- HostAgent 唯一 1 秒 timer 使用已动态验证的 non-reentrant polling gate；cancel 会先拒绝新 tick 并等待在途 JSONL write，再 drain SCK/VideoToolbox 触发最终 stopped，最后 terminal seal coordinator。
- Agent component snapshot 只增加 created/lifecycle/periodic/failure/rejection 计数与 active/cancelled 状态，不包含日志路径或 route identity。
- `RustDeskNativeApp.swift` 仍未创建 `HostAgentMediaPipelineOwner` 或调用 `HostAgentProcess.run`，所以 `--host-agent` 继续 fail closed；本步不会自动启动后台进程或写真实日志。

## Verification

- TDD RED：新增 lifecycle observer、recording protocol 和 coordinator 尚不存在时，定向测试按预期编译失败。
- 定向 lifecycle/coordinator/product composition：18 tests，0 failures。
- `swift test`：267 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一小步应继续 H4.1：在不启用产品入口的前提下，把 Agent 内部 registration/media component snapshot 收敛为后续 authenticated、versioned XPC 所需的明确 snapshot contract，或先补 Agent-owned live-log 文件 retention policy，避免长期 route churn 无界增加文件数。真实 Mini 日志、GUI 退出/崩溃原因、TCC、断线/锁屏/休眠及长时性能仍需新版可运行入口和真机验收。
