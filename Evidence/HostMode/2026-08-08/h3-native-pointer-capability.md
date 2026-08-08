# H3.4f Native Host pointer/touch capability fail-closed

- 日期：2026-08-08
- 范围：pinned RustDesk desktop `server/connection.rs` 与 canonical patch
- 结论：FarPane Native Host 不再把最终 adapter 无法执行的 pointer/touch semantic 送入输入队列

## Root cause

H3.4d 已在 connection ingress 把 `PointerDeviceEvent` 规范化为 scale update 与 pan start/update/end，但 platform consumer 的真实能力并不对称：pinned `handle_pointer_` 只有 Windows `ScaleUpdate` 会调用 `handle_scale`；macOS、Linux 的全部 pointer kind，以及 Windows pan kind 都会落入 no-op 分支。

因此 macOS Native Host 之前仍会更新时间、取得 display-mapping snapshot、进入 input worker 和 macOS main queue，最后无行为结束。typed normalization 只保证 payload 合法，并不代表平台具备该能力。

## Red-green evidence

1. 先写 Native Host/platform support 四象限测试；缺 capability helper 的初始编译 RED 后，以旧的 allow-all 行为确认 behavioral RED：unsupported Native Host 仍为 true，0 passed / 1 failed。
2. 继续按最终 consumer 收敛到 semantic kind：Native Host 只有 platform 明确支持且 kind 为 `ScaleUpdate` 才可进入 adapter；即使在 Windows，pan kind 也必须 false。non-Native pinned upstream 行为保持不变。
3. connection 先执行既有 `NormalizedPointerInput::from_wire`，再以 Native Host instance lifetime、compile-time Windows scale capability 和 normalized kind 做 gate；拒绝发生在 mapping snapshot、input queue、auto-disconnect timer 之前。
4. macOS/Linux Native Host 因此拒绝全部 pointer/touch semantic；Windows Native Host 仅保留实际实现的 scale update。普通 mouse/key 输入不受影响。
5. 未修改 protobuf、Viewer producer、Host ABI、HostSnapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- RED `native_host_pointer_input_fails_closed_on_unsupported_platforms`：allow-all 旧行为为 0 passed, 1 failed；失败点是 unsupported Native Host 仍为 true。
- GREEN 同一测试：1 passed, 0 failed，覆盖 unsupported scale、supported scale、Windows-style pan rejection 与 non-Native compatibility。
- pointer semantic normalization：1 passed, 0 failed。
- input mapping epoch：2 passed, 0 failed。
- input permission epoch：2 passed, 0 failed。
- input adapter gate：1 passed, 0 failed。
- connection-scoped input release：2 passed, 0 failed。
- native Host remote slot：2 passed, 0 failed。
- authenticated session scope：4 passed, 0 failed。
- 相关 Rust 合计：15 passed, 0 failed；debug test build 只有 pinned/upstream warnings。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings，无编译错误。
- built-core Host lifecycle/ABI：3 passed, 0 failed。
- built-core loader ABI smoke：1 passed, 0 failed。
- `swift test`：109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`：success。
- `connection.rs` 以 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- clean pinned clone apply 后 13 个 canonical 文件逐一一致。

## Remaining boundary

- 本步明确 macOS Native Host 当前不支持 trackpad/touch gesture 注入，而不是实现该能力。若未来增加 CGEvent/Accessibility-backed platform adapter，需要按 semantic kind 重新开放 gate 并做真机验收。
- 当前 wire 没有独立 pointer capability advertisement/negative acknowledgement；新增该反馈会触及共享 protobuf 或 Host snapshot contract，本步不猜测扩展。
- Secure Input、TCC、LoginWindow、布局/IME、系统快捷键和真实多显示器输入仍需后续自动审计或真机验收。

## Next step

继续 H3.4 的不改共享 contract 小步骤：优先审计 macOS Secure Input/TCC/LoginWindow 的可自动 fail-closed 边界；真实输入和多显示器保留给 Mini/MBP 真机验收。
