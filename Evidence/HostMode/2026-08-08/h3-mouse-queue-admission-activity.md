# H3.4n Native Host mouse queue-admission activity commit

- 日期：2026-08-08
- 范围：pinned RustDesk desktop `server/connection.rs` 与 canonical patch
- 结论：Native Host simulated mouse 与 cursor-only mouse 只有实际发送到 connection input queue 后，才提交对应 activity

## Root cause

mouse ingress 在 `input_mouse` 取得 permission snapshot/channel admission 之前写 `CLICK_TIME` 或 `MOUSE_MOVE_TIME`，而分支末尾总会重置 auto-disconnect。拒绝窗口包括：

- macOS Retina display/mapping 缺失或坐标越界；
- simulated mouse 的 effective input permission epoch disabled；
- input channel 已关闭；
- peer keyboard disabled 且 remote cursor 也未开启，实际没有任何 queue item。

cursor-only mouse 是合法的 `InputAuthorization::NonInjecting` 路径，应在成功入队时继续维持 auto-disconnect，但不应被 simulated-input permission gate误杀。

## Implementation

- `input_mouse` 现在返回 queue admission 结果：simulated path 缺 permission snapshot 或任一路径 channel send 失败均为 false。
- Native Host simulated mouse 只在 mapping 通过且 queued=true 后写 click/peer time；cursor-only queued=true 时继续更新 auto-disconnect。
- Native Host 无 simulated/cursor queue item、mapping 拒绝或 admission 失败时不提交 activity。
- non-Native desktop 保留 pinned upstream 的 activity 时序，包括 mapping 前 click/peer time；Android/iOS 原 auto-disconnect 更新显式保留。
- 未修改 mouse wire semantics、protobuf、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- 复用 Native Host activity queue-admission 四象限与 modifier admission policy；mouse/key/pointer semantic、pointer capability、mapping epoch、permission epoch、adapter epoch、mouse release、single-session、session scope、Accessibility 与 Aqua-session 相关 Rust 回归合计 21 passed，0 failed。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures。
- `swift build -c release --product RustDeskNative`：success。
- `connection.rs` 通过 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

本步把三类 desktop input 的 activity commit 都对齐到 Native Host queue admission，但不把 admission 冒充 final adapter 执行。TCC/session transition、真实 CGEvent 与多显示器 mapping 仍需要 lifecycle contract 或 Mini 真机证据。

## Next step

独立审计 physical modifier 的 typed Down/Up/Press 与 `pressed_modifiers` 状态机是否一致；若该内部语义已闭合，H3.4 自动空间将主要剩 shared UI/snapshot 与真机检查点。
