# H4.1u Agent-owned ordered media-control ingress

## Outcome

HostAgent process composition 现在有一个 boot-lifetime、单路由的 typed media-control authority。只有通过 bounded Host event journal 的有序 Rust controls 才能到达未来的 Agent capture/encoder owner；终止会先关闭并 drain 该入口。当前 `--host-agent` 仍禁用。

## Key evidence

- `HostAgentMediaControlState` 不保存 raw JSON，只保留 pending/active route 的 connection epoch、codec epoch、display ID/revision，以及 saturating accepted/rejected counters。
- 非 media event 不影响 authority；无法严格解析的 `mediaControl` 进入固定 `invalidControl`，不调用 action。
- media numeric decoder 现在复用严格 UInt64 路径：拒绝 JSON boolean、非有限值、负数、小数和 UInt32 越界，不再把 `1920.5` 截断为合法 width。
- 单路由状态只允许 `startCapture → reconfigure → requestIdr/stopCapture`：start 的 connection/codec epoch 必须同时单调推进；reconfigure 必须 exact match pending route；IDR 必须 exact match active route；stop 可接受 Rust 现有省略 display revision 的 exact epoch/display 终止控制。
- 被 stop 的 route 仍保留 epoch watermark，旧 start replay 不能重新激活；错 epoch/display/revision、未先 start、旧 local event sequence 均 fail closed。
- accepted action 在 condition lock 外同步执行，避免回调重入锁；同一时刻最多一个 action。`cancelAndWait()` terminal 清空 route、拒绝后续控制，并等待在途 action 返回。
- `HostAgentProcess` 在 event journal 成功后先 refresh snapshot，再交给 media authority，最后才 forward 通用 event；调用方必须显式提供 `onMediaControl`，没有丢弃占位。
- termination preparation 固定先 `mediaState.cancelAndWait()`，再 cancel/drain snapshot polling，最后才进入唯一 Core stop attempt。
- `RustDeskNativeApp.swift` 仍不构造 media state 或调用 Agent runner；现有 App 内真实 ScreenCaptureKit/VideoToolbox pipeline 尚未迁移，本步不构成后台画面可用证据。

## Verification

- TDD RED：state/route/disposition 不存在时 4 个 lifecycle/cancel 测试编译失败；缺严格 route validation 时 missing revision 被误报 stale、fractional width 被截断接受；缺 boolean guard 时 `true` 被接受为 epoch 1；产品 source contract 在接线前失败。
- 定向 media-control state 5、既有 media envelope contract 1、产品 composition contract 1：7 tests，0 failures。
- `swift test`：246 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check：无 whitespace error。

## Remaining boundary

本步建立的是控制 admission/drain，不是媒体 pipeline owner。下一小步应把无 AppDelegate/UI 依赖的单路由 `HostMediaPipeline` owner 接到显式 `onMediaControl`：在同一 running Core owner 上设置能力、提交 access unit/encoder state，并让 termination 同步 cancel、等待 SCK/VT queues drain。之后仍需 authenticated XPC 与真实子进程媒体/signal smoke 才能启用入口。
