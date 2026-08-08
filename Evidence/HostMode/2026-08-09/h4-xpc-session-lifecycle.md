# H4.3e4c App-side XPC session lifecycle composition

## Outcome

新增独立 App-side XPC session lifecycle，把 H4.3d3 snapshot-first client 与 H4.3e4b polling owner 组合为一条明确的 snapshot-first 生命周期，并通过 typed projection sink 输出 identity reset、initial snapshot、event、authoritative resync 与 terminal reason。

## Key evidence

- 产品 factory 只创建一个 `HostAgentXPCSnapshotClient`；同一 client 在 initial snapshot 成功交付后才用于创建并强持有一个 `HostAgentXPCEventPollingOwner`，没有第二 XPC connection、cursor 或 peer identity authority。
- 生命周期状态固定为 idle、starting、delivering initial snapshot、polling、failed 或 cancelled；`start()` 只能成功一次，polling owner 启动失败会按 invalid-state fail closed。
- identity replacement callback 在 initial snapshot 前投影一次 reset，避免旧 peer 的 UI intent 被新 peer 继承；typed sink 不接触 wire decoder、Mach service 或 `NSXPCConnection`。
- event batch 与 authoritative resynchronized snapshot 原样接收 e4a/e4b 已完成 correlation 的 typed result；生命周期仅同步自己的观察 cursor，不解释或执行 command result。
- cancel、connection end 与任一 terminal client/poll result 都先停止 polling owner，再取消 snapshot client，最后只向 sink 发送一次脱敏 terminal reason；迟到 client/poll callback 在 terminal state 下被忽略。
- 独立 recursive delivery gate 串行化 projection 与 terminal notification。并发测试阻塞一个已接受 event 的 sink delivery，确认 connection end 必须等待 event 完成后才能发布 terminal，顺序稳定为 event → terminal。
- production relay 对 lifecycle 使用 weak reference，避免 client callbacks 与 lifecycle 构成 retain cycle；lifecycle deinit 仍幂等 cancel。
- 本步没有接入 SwiftUI、App background readiness 或旧 in-process `HostControlClient`，没有自动重连、Host command 或顶层 Agent enablement，因此不把独立 composition 冒充产品已自动订阅或后台 Host ready。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 lifecycle、typed client/owner protocol 与 projection sink 尚不存在而编译失败；实现后转绿。
- session lifecycle focused：8 tests，0 failures；覆盖 snapshot-before-poll、identity reset 顺序、initial failure、poll start failure、cancel、connection end、并发 delivery/terminal 线性化与 source boundary。
- 完整 `swift test`：429 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过；本步新增/修改内容的 secret-shape scan 为 clean（设计文档中已有值未读取、未输出且不属于本步 diff）。

## Remaining boundary

下一步 H4.3e4d 建立 App-owned background projection authority，把 snapshot/event/resync 映射为单一可观察 component state，并明确 terminal/identity replacement 时如何 fail closed；在 registration/Agent enablement 尚未落地前，仍不将它接入产品 readiness 或 SwiftUI 自动启动路径。
