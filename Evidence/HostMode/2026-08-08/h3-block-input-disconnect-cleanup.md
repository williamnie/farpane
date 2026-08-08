# H3.3e disconnect-safe local block-input cleanup

- 日期：2026-08-08
- 范围：pinned RustDesk `server/connection.rs` 与 canonical patch
- 结论：input channel 断开时会在 worker 退出前尝试解除本机 block-input，不再把本机输入保持在 blocked 状态

## Root cause

`handle_input` 用 `recv_timeout(500ms)` 驱动 input queue。既有 `Err` 分支对 `Timeout` 与 `Disconnected` 不加区分：只要 `block_input_mode=true` 就调用 `platform::block_input(true)`，之后才在 `Disconnected` 时 break。

因此数据流是：connection teardown 丢弃最后一个 `tx_input` → receiver 得到 `Disconnected` → worker 再次 block local input → worker 退出。退出后已没有 receiver owner 能够处理 `BlockOff`，存在会话断开后本机输入残留被锁的风险。该逻辑在 pinned upstream HEAD 中已存在，不是 H3.3d 引入的回归。

## Red-green evidence

1. 先新增期望状态机的定向测试。补齐当前行为的 helper 后，RED 稳定失败：`Disconnected + blocked` 实际返回 `InputReceiverErrorAction { block_input: Some(true), exit: true }`，期望为 `Some(false), exit: true`。
2. 最小修复只改 receiver-error decision：active Timeout 仍返回 `Some(true), exit: false`；active Disconnected 返回 `Some(false), exit: true`；inactive 情况不产生 platform call。
3. `handle_input` 消费该 typed action，先执行 `platform::block_input(false)` 再 break；不新增旁路 cleanup 或另一个状态 owner。
4. 未修改 block-input 授权策略、C ABI、HostSnapshot/event/command、protobuf、Hermes、CI、根依赖、数据库或凭据。

## Verification

- RED: 0 passed, 1 failed；失败值精确为 `Some(true)+exit` vs `Some(false)+exit`。
- GREEN `input_receiver_disconnect_releases_local_block_before_exit`: 1 passed, 0 failed。
- `input_permission_epoch`: 2 passed, 0 failed。
- `effective_input_permission`: 1 passed, 0 failed。
- `input_adapter_gate`: 1 passed, 0 failed。
- `native_host_input_release_tests`: 2 passed, 0 failed。
- 相关 Rust 合计：7 passed, 0 failed；debug test build 只有 pinned/upstream warnings，无编译错误。
- `Scripts/build-rust-core.sh`: release core 成功，生成 arm64 Mach-O dylib；release build 报告 131 个 pinned/upstream warnings，无编译错误。
- built-core Host lifecycle/ABI: 3 passed, 0 failed。
- built-core loader ABI smoke: 1 passed, 0 failed。
- `swift test`: 109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`: success。
- `connection.rs` rustfmt、root/Vendor diff whitespace、canonical patch reverse-check 通过。
- clean pinned clone apply 后 13 个 canonical 文件逐一一致；无 staged changes。

## Remaining boundary

- 自动测试覆盖决策状态机，release core 覆盖 platform call 的编译/链接；进一步审计确认 pinned macOS `platform::block_input` 当前是 success-returning no-op，不能据此声称 macOS 已支持 local block-input。
- 若后续实现真实 macOS block-input，应在可从第二会话恢复的 Mini 上补断线验收；当前无真实 macOS 锁定行为可供验收。
- local `SwitchPermission(block_input=false)` 对 active runtime 的立即退出语义已由 H3.3f 单独完成，见 `h3-block-input-permission-revoke.md`。
- H3.3 的 active-session permission snapshot/revoke/disconnect 与 App rebuild 恢复仍需共享 Host contract。

## Next step

H3.3f 完成 local permission revoke 与 active runtime 的一致性后，下一步独立审计 macOS no-op capability 是否应 fail closed，不与 HostSnapshot/schema 改动混在同一步。
