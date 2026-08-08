# H3.3f local block-input permission revoke cleanup

- 日期：2026-08-08
- 范围：pinned RustDesk `server/connection.rs` 与 canonical patch
- 结论：本机撤销 block-input capability 时会在 connection input queue 中同步解除 active runtime block

## Root cause

`ipc::Data::SwitchPermission { name: "block_input", enabled: false }` 原本只执行两件事：把 `conn.block_input` 改为 false，并向 Viewer 发送 `PermissionInfo(BlockInput, false)`。真正调用 `platform::block_input(false)` 的 `MessageInput::BlockOff` 只来自 Viewer option 或 plugin path，本机撤权不会触达 input worker。

因此数据流可以是：Viewer 请求 `BlockOn` → input worker 进入 active block mode → 本机撤销 capability → Viewer UI 收到 disabled，但 worker 仍保持 block mode。撤权后的新请求会被拒绝，却没有清理撤权前已经生效的 runtime state。

## Red-green evidence

1. 先新增 transition matrix 测试，要求只有 capability `true→false` 产生 `MessageInput::BlockOff`；缺 helper 的初始编译 RED 后，用旧行为 `None` 固定根因。
2. 行为 RED 稳定为 0 passed / 1 failed，失败断言精确是 expected `Some(MessageInput::BlockOff)`，actual `None`。
3. 最小修复保存旧 capability，在赋新值后仅对 `true→false` 把 `BlockOff` 发送到既有 `tx_input`。重复 false、同值 true 与 false→true 均返回 `None`。
4. 该 queue 与 Viewer `BlockOn` 使用同一个 FIFO：撤权前已接受的 on 后面一定有本机 off；撤权后的新 on 又被既有 `self.block_input=false` 检查拒绝。
5. 未修改 Host ABI、HostSnapshot/event/command、protobuf、Hermes、CI、根依赖、数据库或凭据。

## Verification

- RED `local_block_input_permission_revoke_enqueues_runtime_unblock`: 0 passed, 1 failed；`None` 与预期 `BlockOff` 精确不符。
- GREEN 同一测试：1 passed, 0 failed。
- disconnect cleanup：1 passed, 0 failed。
- input permission epoch：2 passed, 0 failed。
- effective input permission：1 passed, 0 failed。
- input adapter gate：1 passed, 0 failed。
- connection-scoped input release：2 passed, 0 failed。
- 相关 Rust 合计：8 passed, 0 failed；debug test build 只有 127 个 pinned/upstream warnings。
- `Scripts/build-rust-core.sh`: release core 成功，生成 arm64 Mach-O dylib；131 个 pinned/upstream warnings，无编译错误。
- built-core Host lifecycle/ABI：3 passed, 0 failed。
- built-core loader ABI smoke：1 passed, 0 failed。
- `swift test`: 109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`: success。
- `connection.rs` rustfmt、root/Vendor diff whitespace、canonical patch reverse-check 通过。
- clean pinned clone apply 后 13 个 canonical 文件逐一一致；bridge mirror 一致。

## Remaining boundary

- pinned macOS `platform::block_input` 当前直接返回 success 而不执行锁定；本步证明 connection/runtime 撤销路由，不构成 macOS block-input 功能验收。
- 下一步应审计是否要让 macOS 对该 capability fail closed，避免 Viewer 得到“允许/成功”但平台无行为的虚假状态。
- H3.3 的 active-session permission snapshot/revoke/disconnect 与 App rebuild 恢复仍需共享 Host contract。

## Next step

在不修改共享 Host schema/ABI 的前提下，审计并收敛 macOS block-input capability advertisement 与 success-reporting no-op；若不能在 pinned connection/platform authority 内安全完成，则记录为产品能力决策边界。
