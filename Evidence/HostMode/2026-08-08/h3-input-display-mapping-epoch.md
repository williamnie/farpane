# H3.4b connection-scoped input display-mapping epoch

- 日期：2026-08-08
- 范围：`Vendor/rustdesk/src/server/connection.rs` 与 canonical RustDesk patch
- 结论：自动实现与自动验证完成；真机多显示器、缩放切换和 TCC/CGEvent 行为仍待人工验收

## Outcome

macOS connection 现在为 mouse、pointer/touch 以及仅显示远端光标的 queued task 捕获 connection-scoped display-mapping generation。输入 worker 与 macOS platform adapter 的最终 gate 都要求 generation 仍为当前值；显示列表/scale、当前 display 或 connection lifetime 改变后，旧 generation 的 task fail closed。

该 generation 只保护 Host 内部“规范化坐标到 platform execution”的时间窗口，不复用媒体 `displayRevision`，也不声称修改 RustDesk wire protocol。当前 `MouseEvent` 没有 display id/revision，native media route 的 revision 也不是输入授权 authority。

## Key evidence

1. `InputMappingEpoch` 从非零 generation 开始，单调递增；到达 `u64::MAX` 后进入永久无效的 0，避免 wrap-around 让旧 snapshot 再次有效。
2. macOS absolute mouse 在入队前必须同时取得当前 mapping snapshot 和有效 Retina display/scale；缺 display、非有限 scale 或非正 scale 会直接拒绝。wheel、trackpad 与 relative move 不依赖 absolute mapping，保持 delta 语义。
3. `AuthorizedInput` 同时携带 permission snapshot 与可选 mapping snapshot；worker 消费前复核一次，进入异步 macOS main queue 后 adapter gate 再复核一次。
4. display list/scale 变化、选中 display 切换、来自 display service 的 `SwitchDisplay` 更新以及 connection teardown 都会 advance mapping epoch。相同 display list 不旋转 generation，避免无意义丢弃。
5. cursor-only `NonInjecting` task 不受 keyboard permission revoke 误伤，但会受 mapping epoch 约束，因此旧坐标不会在新显示映射上绘制。
6. 没有新增或修改 C ABI、protobuf/schema、Hermes、配置根、CI、根依赖、数据库或凭据处理。

## Verification

在 pinned RustDesk 1.4.9 worktree，以项目 vcpkg root 和 `rdn-native-core,rdn-native-host` features 运行：

- `input_mapping_epoch`: 2 passed, 0 failed；覆盖 current/stale/re-advance/saturation，以及 injecting/cursor-only queued message。
- `retina`: 1 passed, 0 failed；覆盖 display-list change detection、Retina absolute mapping、relative delta、missing display 与 invalid scale。
- `input_adapter_gate`: 1 passed, 0 failed。
- `input_permission_epoch`: 2 passed, 0 failed。
- `remote_mouse_button`: 2 passed, 0 failed。
- `native_host_remote_slot`: 2 passed, 0 failed。
- Rust lib tests 编译仍报告 pinned/upstream 的 127 warnings；没有新增编译错误。
- `Scripts/build-rust-core.sh`: release core 成功，arm64 Mach-O dylib 生成；现有 130 warnings。
- built-core `HostBridgeContractTests`: 3 passed, 0 failed。
- built-core loader ABI smoke: 1 passed, 0 failed。
- `swift test`: 109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`: success。
- 根与 Vendor `git diff --check`: clean。
- canonical patch reverse-check 成功；在 clean pinned clone 中 apply 后 13 个受控文件逐一与当前 Vendor 一致，`connection.rs` rustfmt check 成功。

第一次直接运行未带项目 `VCPKG_ROOT` 的 Rust test 因系统 Homebrew `libyuv` 不存在而停止；随后使用与正式 build script 相同的项目 vcpkg root 重跑并通过。该失败是依赖定位方式，不是代码或测试失败。

## Remaining boundary

- RustDesk `MouseEvent` wire payload 尚无 display id/revision；controller 在发送前后发生 display 语义变化时，Host 无法从 payload 恢复事件原始 display authority。
- absolute coordinate 的完整 bounds/clamp/sentinel 语义仍由 upstream payload 约定承担，本步只对缺失/无效 Retina mapping fail closed。
- 仍没有独立 typed semantic Host input event；当前 adapter 消费 upstream protobuf event。
- Secure Input、登录窗口、系统快捷键、键盘布局、辅助功能/输入监控权限降级，以及真实双显示器/缩放切换必须在 Mac mini 真机会话中验收。
- HostSnapshot/current permission/revoke/App rebuild 属于尚未决策的共享 schema 边界，本步未扩大范围。

## Next step

继续 H3.4c：只读审计并收敛 upstream mouse/pointer 的 absolute bounds、button sentinel、relative/trackpad 与多显示器坐标合同；若可在内部边界安全固化，则增加 semantic normalization 与 fail-closed tests。任何需要新增 wire/schema/Host ABI 的内容留作明确架构检查点。
