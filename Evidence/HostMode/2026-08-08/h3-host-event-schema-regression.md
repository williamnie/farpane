# H3 Host event schema regression 修复证据

- 日期：2026-08-08
- 范围：Host event envelope schema authority、Swift/CoreBridge contract tests
- 结论：Host event 恢复为独立 schema v1；HostSnapshot 保持 schema v2

## Root cause

H3.1b 为永久密码 policy 扩展 HostSnapshot 时，把共享常量 `SNAPSHOT_SCHEMA_VERSION` 从 1 升至 2。Rust `emit_bound_event` 当时也复用了该常量，因此所有 `snapshotChanged`、`commandResult`、media control/diagnostic 事件都开始携带 schema v2。

Swift `HostCoreEvent` 按既有独立事件合同严格要求 schema v1。回调收到 v2 后会在解码入口 fail closed，不会交给 App；这会阻断媒体控制和后续 H3.2 入站审批事件。此前 built-core 测试只证明回调收到非空 JSON，没有把真实事件再交叉验证为 Swift 可接受的 schema，因而未捕获 coupling。

## Implementation

- Rust Host bridge 新增独立 `EVENT_SCHEMA_VERSION = 1`。
- `emit_bound_event` 只使用 event schema；`snapshot_json` 继续使用 `SNAPSHOT_SCHEMA_VERSION = 2`。
- 增加始终运行的源码合同测试，锁定两个版本常量及各自 consumer。
- built-core Host lifecycle 测试现在解析真实 C callback 收到的每条事件并断言 schema v1；snapshot 同一测试继续断言 v2。
- Host ABI 版本、snapshot schema、event payload、Hermes、wire protocol、CI、依赖、数据库和凭据均未改变。

## Fresh verification

- `swift test`：113 tests，0 failures，4 built-core conditional skips。
- `./Scripts/build-rust-core.sh`：release arm64 core 成功；保留 130 个 pinned/upstream warnings，无编译错误。
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`：113 tests，0 failures，0 skips；真实 Host lifecycle/ABI 3/3 通过，C callback 事件全部为 schema v1。
- `swift build -c release`：通过。
- host bridge rustfmt、canonical/vendor mirror、两个 patch reverse-check、root/Vendor diff whitespace：通过。

## Remaining boundary

该修复只恢复现有 Host event transport，不新增 H3.2 产品行为。Rust pending-request broker、HostSnapshot pending recovery、一次性 approve/reject/expiry command 与 Swift 入站弹窗仍是后续独立步骤。
