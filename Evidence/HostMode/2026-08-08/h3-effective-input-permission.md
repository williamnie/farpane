# H3.3d authorization-bound effective input permission

- 日期：2026-08-08
- 范围：pinned RustDesk `server/connection.rs` 与 canonical patch
- 结论：input permission epoch 已从“本机 keyboard policy 单一开关”收紧为完整 authenticated Remote display-session authority；两端撤销均会汰汰已排队输入

## Outcome

修改前，connection 创建时会直接根据本机 keyboard policy 把 input epoch 设为 enabled，安全性主要依赖预认证 `on_message` 控制流不把输入交给 queue。另外，Viewer 通过 option 设置 `disable_keyboard` 后会拒绝新事件，但没有旋转 epoch，撤销前已排队事件仍可以通过 worker/platform gate。

现在 epoch 默认 disabled，只在下列五个条件同时成立时 enabled：

1. connection 已完成认证；
2. scope 是 Remote control；
3. display service 已就绪并完成 session subscription；
4. 本机 keyboard capability policy 允许；
5. Viewer 没有设置 `disable_keyboard`。

## Key evidence

1. 任一前置条件缺失都不能生成 permission snapshot；file-transfer、terminal 与 view-camera session 不会被本机 keyboard policy 误启用。
2. 认证成功但 display enumeration/service subscription 失败时仍保持 disabled，不以 `authorized=true` 单独开放输入。
3. 本机 `SwitchPermission` 与 Viewer `disable_keyboard` 走同一同步函数；任一方撤销都旋转 generation，已排队的 mouse/pointer/key snapshot 立即失效。
4. enabled→disabled 在旋转 epoch 后向同一 input queue 排入 connection-scoped `Release`，复用 H3.3a 有序 key/button cleanup；同值更新不重复旋转或重复清理。
5. cursor-only non-injecting message 仍不受 keyboard permission 误伤，但继续受 authenticated message scope 与 display-mapping generation 限制。
6. 未修改 C ABI、HostSnapshot/event/command、protobuf、Hermes、CI、根依赖、数据库或凭据。

## Verification

- `effective_input_permission`: 1 passed, 0 failed，覆盖五条件真值矩阵、预认证 disabled、ready 后启用与 Viewer disable 对 queued key 的汰汰。
- `input_permission_epoch`: 2 passed, 0 failed。
- `native_host_input_release_tests`: 2 passed, 0 failed。
- `input_adapter_gate`: 1 passed, 0 failed。
- `session_scope`: 4 passed, 0 failed。
- 相关 Rust 合计：10 passed, 0 failed；debug test build 报告 127 个 pinned/upstream warnings，无编译错误。
- `Scripts/build-rust-core.sh`: release core 成功，生成 arm64 Mach-O dylib；release build 报告 131 个 pinned/upstream warnings，无编译错误。
- built-core Host lifecycle/ABI: 3 passed, 0 failed。
- built-core loader ABI smoke: 1 passed, 0 failed。
- `swift test`: 109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`: success。
- `connection.rs` rustfmt 与 root/Vendor diff whitespace check 通过。
- canonical patch reverse-check 通过；clean pinned clone apply 后 13 个受控文件逐一一致；无 staged changes。

## Remaining boundary

- 该 authority 仍是 Rust connection-internal；HostSnapshot 尚无 active connection/current capability，App 重建后不能显示或撤销它。
- 本步用定向回归证明 epoch cutover 与 queue/adapter contract，未在真实 CGEvent backlog 下操作 Viewer disable 或本机 revoke；这需要 Mini 上已授权的 Accessibility/Input Monitoring 会话。
- `authorized`/display-service-ready 仍来自 pinned connection lifecycle；未新增共享 Host schema，也未将内部布尔状态冒充为 App 可恢复的 immutable permission snapshot。

## Next step

继续审计 H3 中不需要修改 HostSnapshot/event/command 的安全小步骤；H3.2 native pending approval、H3.3 App revoke/session recovery 与 H3.1 permanent-password ABI 仍是共享合同检查点，不在自动托管中猜测字段。
