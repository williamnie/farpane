# H3.4c typed mouse semantic normalization

- 日期：2026-08-08
- 范围：pinned RustDesk `connection.rs` / `input_service.rs` 与 canonical patch
- 结论：mouse wire event 到 macOS input adapter 的 typed semantic boundary 已自动实现并验证；pointer/touch、keyboard 与真机 CGEvent 行为仍属后续

## Outcome

desktop Host 不再把任意 protobuf `MouseEvent` 直接排入 platform adapter。Rust session 在 network message handler 内先转换为 `NormalizedMouseInput`，其 kind 只能是：

- absolute move；
- relative move；
- single-button down/up（left/right/middle/back/forward）；
- discrete scroll；
- precise scroll。

typed value 连同 permission epoch、display-mapping epoch 和 connection id 一起穿过 connection input queue；macOS main-queue adapter 接收并持有该 typed value，最终才投影回 pinned Enigo/rdev 所需的 `MouseEvent`。这建立了 §12.1 中 mouse 范围的 `protocol event -> normalized semantic event -> HostInputAdapter` 实际边界。

## Key evidence

1. unknown/reserved type 6/7、zero-button down/up、multi-button transition、move/scroll 携带 button bits 均 fail closed，不能到达 adapter。
2. mouse modifier 只接受 canonical Alt/Control/Shift/Meta，unknown 或重复 modifier fail closed。
3. relative delta 在 semantic boundary 限制为 `[-10000, 10000]`；input service 原有 clamp 继续作为 defense in depth。
4. discrete/precise scroll 与 FarPane Viewer C ABI 的既有合同一致，限制为 `[-120, 120]`。
5. absolute move 现在必须落在当前有效 display rectangle；display dimension overflow、非正 width/height、缺失 display、非有限/非正 scale 均 fail closed。
6. button event 的 `(0,0)` 保留为 upstream compatibility sentinel，因为旧客户端可能不携带按钮坐标；单按钮语义仍会验证。真实 `(0,0)` 也保持有效，未伪造新的 wire sentinel。
7. cursor-only task 同样必须先通过 semantic normalization 和 mapping epoch；keyboard permission disabled 时不会借 cursor path 绕过 malformed-event validation。
8. 没有修改 protobuf、C ABI、HostSnapshot、Hermes、CI、根依赖、数据库或凭据处理。

## Verification

在 pinned RustDesk 1.4.9 worktree，以项目 vcpkg root 和 `rdn-native-core,rdn-native-host` features 运行：

- `normalizes_wire_mouse_semantics_before_queueing`: 1 passed, 0 failed。
- `retina`: 1 passed, 0 failed。
- `input_mapping_epoch`: 2 passed, 0 failed。
- `input_adapter_gate`: 1 passed, 0 failed。
- `input_permission_epoch`: 2 passed, 0 failed。
- `remote_mouse_button`: 2 passed, 0 failed。
- `native_host_remote_slot`: 2 passed, 0 failed。
- Rust lib test/build 仍报告 pinned/upstream 的 127/130 warnings；没有新增编译错误。
- `Scripts/build-rust-core.sh`: release core 成功，arm64 Mach-O dylib 生成。
- built-core Host lifecycle/ABI: 3 passed, 0 failed。
- built-core loader ABI smoke: 1 passed, 0 failed。
- `swift test`: 109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`: success。
- canonical patch reverse-check 成功；clean pinned clone apply 后 13 个受控文件逐一一致，`connection.rs` / `input_service.rs` rustfmt check 成功。
- 根与 Vendor `git diff --check`: clean。

## Remaining boundary

- `PointerDeviceEvent` 的 pan/scale union 与 modifiers 尚未建立相同 typed normalization；下一步不能把 mouse-only 结果冒充全部 pointer 完成。
- key event 仍使用 upstream `KeyEvent`，虽然 Viewer C ABI 已是 semantic key 输入，Host 入站还需要独立 audit/normalization。
- wire `MouseEvent` 没有 display id/revision；H3.4b 只能隔离 Host 内部 queue 期间发生的 mapping change，不能恢复 controller 发送时的显示语义。
- `(0,0)` 同时可能是真实坐标和 legacy button sentinel；若要彻底消除歧义，需要 protocol/schema 决策，本步未扩大范围。
- Secure Input、登录窗口、系统快捷键、键盘布局、辅助功能/输入监控权限与真实多显示器注入必须真机验收。

## Next step

继续 H3.4d：审计 `PointerDeviceEvent` 的实际 pan/scale producer/consumer，建立内部 typed pointer semantic 与 modifiers/数值范围的 fail-closed normalization；保持 protobuf/Host ABI 不变。若 upstream union 无法无歧义表达所需语义，则记录为共享 contract 检查点而不猜测。
