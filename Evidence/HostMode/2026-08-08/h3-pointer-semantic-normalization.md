# H3.4d typed pointer/touch semantic normalization

- 日期：2026-08-08
- 范围：pinned RustDesk `connection.rs` / `input_service.rs` 与 canonical patch
- 结论：pointer/touch wire event 到 platform adapter 的 typed semantic boundary 已自动实现并验证；pinned macOS adapter 仍不注入 touch gesture，因此本步不宣称 macOS 触控能力完成

## Outcome

desktop Host 现在会在 connection queue 前把 protobuf `PointerDeviceEvent` fail-closed 转换为 `NormalizedPointerInput`。其 semantic kind 只能是 scale update（包含明确的 gesture-ended 状态）、pan start、pan update 或 pan end；typed value 连同 permission epoch、display-mapping epoch 与 connection id 一起进入 input queue，再由 platform adapter 接收。

这补齐了 pointer/touch 范围的 `protocol event -> normalized semantic event -> HostInputAdapter` 内部边界，但没有虚构平台能力：pinned macOS `handle_pointer_` 对 touch gesture 仍是 no-op；Windows 既有 scale-to-Ctrl-wheel 路径继续消费规范化后的 wire projection，pan 行为保持 upstream 现状。

## Key evidence

1. 缺失 outer pointer union、缺失 inner touch union以及未来未知的 non-exhaustive union variant 均 fail closed，不能进入 input queue。
2. pointer modifier 与 mouse 共用 canonical authority，只接受 Alt/Control/Shift/Meta；unknown 或重复 modifier fail closed。
3. scale wire 单位沿用 producer 的千分比增量，semantic boundary 将单事件限制为 `[-1000, 1000]`；规范化后 `scale == 0` 明确标记 gesture ended。
4. pan update 是 delta 语义，x/y 单事件限制为 `[-10000, 10000]`；pan start/end 坐标保持原值，因为 wire 没有 display id/revision，且 pinned macOS 当前不消费该坐标，不能擅自套用 mouse display mapping。
5. raw `PointerDeviceEvent` 不再直接存入 desktop connection queue；worker 与 macOS main-queue adapter 持有 `NormalizedPointerInput`，H3.3b permission epoch 与 H3.4b mapping epoch 仍在其前后复核。
6. 没有修改 protobuf、C ABI、HostSnapshot、Hermes、CI、根依赖、数据库或任何凭据。

## Verification

在 pinned RustDesk 1.4.9 worktree，以项目 vcpkg root 和 `rdn-native-core,rdn-native-host` features 运行：

- `normalizes_wire_pointer_semantics_before_queueing`: 1 passed, 0 failed。
- `normalizes_wire_mouse_semantics_before_queueing`: 1 passed, 0 failed。
- `retina`: 1 passed, 0 failed。
- `input_mapping_epoch`: 2 passed, 0 failed。
- `input_adapter_gate`: 1 passed, 0 failed。
- `input_permission_epoch`: 2 passed, 0 failed。
- `remote_mouse_button`: 2 passed, 0 failed。
- `native_host_remote_slot`: 2 passed, 0 failed。
- Rust lib test 报告 127 个 warning；release core 报告 131 个 warning，其中新增的 `kind` dead-code warning 如实反映 macOS 尚无 gesture consumer，没有编译错误。
- `Scripts/build-rust-core.sh`: release core 成功，arm64 Mach-O dylib 生成。
- built-core Host lifecycle/ABI: 3 passed, 0 failed。
- built-core loader ABI smoke: 1 passed, 0 failed。
- `swift test`: 109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`: success。
- canonical patch 与 13-file generated diff 一致；reverse-check 成功，clean pinned clone apply 后 13 个受控文件逐一一致，`connection.rs` / `input_service.rs` rustfmt check 成功。

## Remaining boundary

- pinned macOS adapter 不实现 pan/scale 的 CGEvent 或其他系统注入；是否将 Viewer gesture 映射为滚动/缩放，以及 TCC 行为，属于后续平台能力决策与真机验收，不能由 normalization 测试替代。
- Host 入站 `KeyEvent` 仍直接使用 upstream protobuf，尚需独立 semantic normalization 与 layout/system-shortcut audit。
- pointer wire 没有 display id/revision；H3.4b 只能丢弃 Host queue 期间 mapping 已变化的事件，无法证明 controller 发送时坐标属于当前显示器。
- Secure Input、登录窗口、系统快捷键、键盘布局、辅助功能/输入监控权限与真实多显示器注入仍需真机验收。
- HostSnapshot/revoke/App rebuild 的共享 schema 检查点仍未解决。

## Next step

继续 H3.4e：审计 Host 入站 `KeyEvent` 的 union、mode、modifier、unicode/raw-key producer/consumer，建立内部 typed key semantic 与 fail-closed normalization；保持 protobuf/Host ABI 不变。若键盘布局或系统快捷键无法由现有 wire 无歧义表达，则记录为共享 contract/真机边界，不猜测实现。
