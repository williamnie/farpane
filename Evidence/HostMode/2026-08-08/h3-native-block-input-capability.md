# H3.3g Native Host block-input capability fail-closed

- 日期：2026-08-08
- 范围：pinned RustDesk `server/connection.rs` 与 canonical patch
- 结论：FarPane Native Host 不再在 macOS/Linux 上广告或接受 success-returning no-op block-input capability

## Root cause

`Connection` 原本直接把 `Self::permission(OPTION_ENABLE_BLOCK_INPUT, ...)` 写入 `conn.block_input`。该值只表示配置/provider permission，没有验证当前 platform implementation 是否执行真实阻断。

平台审计结果：Windows `platform::block_input` 调用系统 `BlockInput` API；pinned macOS 与 Linux 实现都无条件返回 `(true, "")`，但不做任何系统操作。因此 macOS Native Host 可向 Viewer 广告 permission=true，Viewer 请求又收到成功状态，实际本机输入完全不变。

## Red-green evidence

1. 先写四象限测试：configured=false 始终 false；Native Host + unsupported platform 必须 false；Native Host + supported platform 保留 true；non-Native upstream 即使 platform flag=false 也保持 configured=true。
2. 缺 helper 的初始编译 RED 后，以旧行为 `return configured` 固定根因；行为 RED 为 0 passed / 1 failed，精确失败于 Native Host + unsupported platform 仍为 true。
3. 最小 gate 为 `configured && (!native_host_active || platform_supported)`。connection 创建时用 native Host instance lifetime 和 compile-time Windows support 计算 capability。
4. 内部 `SwitchPermission` 也走同一 gate，避免未来本机控制入口把 unsupported capability 重新设为 true；forced false 会继续复用 H3.3f 的 runtime unblock transition。
5. Native macOS connection 因此在登录时发送 `PermissionInfo(BlockInput, false)`，远端后续 BlockOn 走既有 `No permission` 失败路径。非 Native Host 行为不变。
6. 未修改 platform implementation、Host ABI、HostSnapshot/event/command、protobuf、Hermes、CI、根依赖、数据库或凭据。

## Verification

- RED `native_host_block_input_capability_fails_closed_on_unsupported_platforms`: 0 passed, 1 failed；unsupported Native Host actual=true。
- GREEN 同一测试：1 passed, 0 failed。
- local revoke：1 passed, 0 failed。
- disconnect cleanup：1 passed, 0 failed。
- input permission epoch：2 passed, 0 failed。
- effective input permission：1 passed, 0 failed。
- input adapter gate：1 passed, 0 failed。
- connection-scoped input release：2 passed, 0 failed。
- native Host remote slot：2 passed, 0 failed。
- authenticated session scope：4 passed, 0 failed。
- 相关 Rust 合计：15 passed, 0 failed；debug test build 只有 127 个 pinned/upstream warnings。
- `Scripts/build-rust-core.sh`: release core 成功，生成 arm64 Mach-O dylib；131 个 pinned/upstream warnings，无编译错误。
- built-core Host lifecycle/ABI：3 passed, 0 failed。
- built-core loader ABI smoke：1 passed, 0 failed。
- `swift test`: 109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`: success。
- `connection.rs` rustfmt、root/Vendor diff whitespace、canonical patch reverse-check 通过。
- clean pinned clone apply 后 13 个 canonical 文件逐一一致；bridge mirror 一致。

## Remaining boundary

- 本步明确产品当前不支持 macOS local block-input，而不是实现该能力。未来如增加真实 macOS platform implementation，需要重新开启 capability 并补可恢复真机验收。
- H3.3 的 active-session permission snapshot/revoke/disconnect 与 App rebuild 恢复仍需共享 Host contract。
- H3.4 的 Secure Input、TCC、登录窗口、系统快捷键、布局/IME、多显示器与 touch 能力仍需后续自动审计或真机验收。

## Next step

继续选择不修改共享 schema/ABI 的 H3 fail-closed 小步骤；优先审计 macOS touch/pointer capability 的 no-op 边界，避免 normalized event 被误解为平台已支持手势注入。
