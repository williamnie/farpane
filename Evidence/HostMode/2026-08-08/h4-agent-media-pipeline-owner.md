# H4.1v process-owned real media pipeline

## Outcome

HostAgent 的禁用产品组合现在持有一条无 UI 的真实 ScreenCaptureKit → VideoToolbox → Host Media ABI 路径。能力发布、压缩帧提交、编码器状态与 Core stop 都经过同一个 process-lifetime owner；退出先停止接收控制，再同步 drain 媒体管线。`--host-agent` 仍保持 fail-closed，因而本步不冒充后台真机验收。

## Key evidence

- `HostAgentMediaPipelineOwner` 不依赖 AppKit、AppDelegate 或窗口；它从 CoreGraphics active display 集合建立硬件 probe envelope，并用既有 `HostHardwareEncoderCapabilityDiscovery` 同时探测 H.264/H.265。
- capability 只经绑定的 `HostAgentProcessLifetime` 发布；媒体 access unit 与 encoder state 也从同一 lifetime 进入 Rust，没有第二个 `HostControlClient` 或旁路 Core handle。
- `HostMediaPipelineRouteOwner` 串行处理 reconfigure/stop，一次只强持有一条真实 `HostMediaPipeline`。换 route 会先失效旧 generation，再 cancel/stop 旧 SCK/VT；晚到 callback 被记为 reconfigure drop，不能进入新 Rust route。
- route identity 同时固定 connection epoch、codec epoch、display ID/revision 与 codec。codec/config 不符、空或 codec 不符的 access unit，以及 width/height 16...16384、FPS 1...240、bitrate 100000...100000000 之外的配置都在创建管线前拒绝。
- access unit 使用现有 AVCC framing；Rust submission drop 会保留脱敏 reason telemetry，并只对当前 generation 执行 keyframe recovery。
- runtime error 会发布固定 `runtimeFailed` 并排队停止当前 route；factory/start error 只发布固定 `startFailed`，不保留底层 Error。
- `HostScreenCaptureAdapter.cancel()` 现在是 terminal：无论正在等待 shareable content、准备 stream 还是等待 `startCapture()`，取消后都不能重新成为 current stream；`stop()` join 同一个 stop task。这个边界降低了断线或退出时遗留 SCK 工作导致进程异常退出/悬挂的风险。
- termination preparation 顺序为 media-control ingress cancel/drain → media pipeline cancel/drain → snapshot poll/coordinator cancel/drain → 唯一 Core stop attempt；停止后的 capability/submit/report 调用由 lifetime gate 拒绝。
- Agent status 目前只保留能力失败、管线失败和控制拒绝的 saturating 内存计数；不写 server/key、peer、屏幕内容、encoded bytes 或自由文本 Error。
- `RustDeskNativeApp.swift` 仍不调用 `HostAgentProcess.run`，`--host-agent` 固定 unavailable 行为没有改变；现有 App 内管线与 live telemetry writer 本步未删除或迁移。

## Verification

- TDD RED：route owner、Core media lifetime 与产品 wiring 不存在时定向测试失败；实现后覆盖 start/submit/state/IDR/stop、route replacement、旧 callback、backpressure recovery、start failure、cancel during start、非法 route/access unit 以及 Core stop 后拒绝媒体操作。
- 定向 Host pipeline/capture、route owner、Core/owned lifetime 与产品 source contract：26 tests，0 failures。
- `swift test`：255 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

本步尚未启用 Agent 入口，也没有 authenticated App↔Agent XPC、SMAppService 生命周期或真实子进程/TCC 媒体证据。下一小步应先把 Agent-owned media diagnostics/queue/writer/network/transport 聚合接入该 route 的 telemetry 与组件 snapshot，再进入 XPC snapshot-first 暴露；用户恢复测试环境后仍需验证锁屏/休眠、断线重连和 600 秒/30 分钟真机稳定性。
