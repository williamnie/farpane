# H3.4g Native Host Accessibility TCC fail-closed

- 日期：2026-08-08
- 范围：pinned RustDesk `server/connection.rs`、`server/input_service.rs` 与 canonical patch
- 结论：macOS Native Host 的 keyboard/mouse injection capability 与最终 adapter 现在以实时 Accessibility TCC 查询 fail closed

## Root cause

pinned macOS adapter 已提供无提示的权威查询 `AXIsProcessTrustedWithOptions(false)`，但 Host connection 的 `keyboard` capability 只读取本机配置；mouse/key/pointer 在 permission epoch 通过后也直接进入 macOS main queue 和 Enigo/rdev。Accessibility 未授权时，Native Host 因而仍向 Viewer 暴露 keyboard permission，并把事件送到最终 platform adapter，依赖系统静默拒绝。

这与设计 §10.1 的“Accessibility 缺失时输入能力强制关闭”和 §12.1 的 platform adapter fail-closed 不一致。Input Monitoring 只影响特定输入模式/完整键盘兼容，设计要求标记 limited，不是本步的硬门禁。

## Red-green evidence

1. 先写 configured/nativeHost/trusted 四象限测试；缺 helper 的初始编译 RED 后，以旧 configured-only 行为确认 behavioral RED：Native Host + untrusted 仍为 true，0 passed / 1 failed。
2. 最小 policy 为 `configured && (!nativeHost || accessibilityTrusted)`：普通 pinned upstream 行为不变，只有 live Native Host on macOS 使用权威 TCC 查询。
3. connection 创建时用该 policy 计算 `keyboard`；缺权限时既有 `PermissionInfo(Keyboard, false)` 会通知 Viewer。本机 `SwitchPermission(keyboard=true)` 也不能绕过 TCC。
4. macOS main queue 的 simulated mouse、pointer 与 key 在 Enigo/rdev 前再次调用无提示 TCC 查询，覆盖授权在事件排队后被撤销的窗口。cursor-only `simulate=false` 路径不需要 Accessibility，保持可见。
5. 未请求系统弹窗，未修改 TCC 数据库、Input Monitoring policy、protobuf、Host ABI/HostSnapshot、Hermes、CI、根依赖、数据库或凭据。

## Verification

- RED `native_host_accessibility_permission_fails_closed_when_untrusted`：configured-only 旧行为为 0 passed, 1 failed；失败点是 Native Host + untrusted 仍为 true。
- GREEN 同一测试：1 passed, 0 failed，覆盖 untrusted rejection、trusted allow、non-Native compatibility 与 configured=false。
- effective input permission：1 passed, 0 failed。
- input permission epoch：2 passed, 0 failed。
- input adapter epoch gate：1 passed, 0 failed。
- input mapping epoch：2 passed, 0 failed。
- mouse/key semantic normalization：2 passed, 0 failed。
- connection-scoped mouse release：2 passed, 0 failed。
- native Host remote slot：2 passed, 0 failed。
- authenticated session scope：4 passed, 0 failed。
- 相关 Rust 合计：17 passed, 0 failed；debug test build 只有 pinned/upstream warnings。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings，无编译错误。
- built-core Host lifecycle/ABI：3 passed, 0 failed。
- built-core loader ABI smoke：1 passed, 0 failed。
- `swift test`：109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`：success。
- 两个 touched Rust 文件以 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- clean pinned clone apply 后 13 个 canonical 文件逐一一致。

## Remaining boundary

- 自动测试证明 policy 与真实调用链编译运行，但不能代替 Mini 上实际撤销/重新授予 Accessibility 后的 CGEvent 验收。
- 最终 adapter 会立即丢弃 TCC 撤销后的事件，但 connection permission snapshot/UI 状态尚不会由 TCC change 主动刷新；这需要 HostSnapshot/event contract 或 platform permission monitor，属于被禁止在本步擅改的共享边界。
- TCC 在 key-down 与 key-up 之间撤销时的系统级按键状态、Secure Input、LoginWindow/锁屏、Fast User Switching 与输入性能仍需后续设计或真机证据。

## Next step

继续一个不改共享 contract 的 H3.4 小步：审计现有 macOS lock/prelogin 检测的 fail-open 错误语义与 Native Host ingress，能自动收敛则补内部 gate；若需要 platform session monitor/shared snapshot，则记录为用户回来后的架构检查点。
