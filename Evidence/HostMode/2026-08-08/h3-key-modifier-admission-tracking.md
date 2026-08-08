# H3.4m Native Host key modifier admission tracking

- 日期：2026-08-08
- 范围：pinned RustDesk desktop `server/connection.rs` 与 canonical patch
- 结论：Native Host physical-modifier cleanup state 只由已授权入队的 key event 更新

## Root cause

desktop key ingress 会根据 normalized physical modifier 与 action 更新 connection-scoped `pressed_modifiers`，之后才由 `input_key` 取得 permission snapshot 并尝试入队。`Connection::drop` 会对集合内每个 modifier 调用 `rdev::simulate(KeyRelease)`。

这形成两个相反的 fail-open 窗口：

- rejected press 可以把从未注入的 modifier 加入集合，断线时制造一次无对应 key-down 的本地 key-up；
- 已入队并跟踪的 modifier 遇到 rejected release 时会被提前移出集合，teardown 失去最终释放机会。

H3.4l 已提供真实 queue admission 结果，但此前只用于 activity commit，cleanup tracking 尚未消费它。

## Implementation

- 新增内部 `native_host_key_tracks_modifier(nativeHostActive, queued)` policy。
- key action 仍保持 pinned upstream 的 Press/Down/Up projection；只有 `input_key` 返回 queued=true 后，Native Host 才 insert/remove `pressed_modifiers`。
- rejected press 不再创建 teardown key-up；rejected release 不再删除已跟踪状态，使既有 disconnect cleanup 仍可释放先前已接受的 modifier。
- non-Native desktop 保留 pinned upstream 的 modifier-tracking compatibility。
- 未修改 wire key semantics、protobuf、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- Native Host modifier queue-admission policy：1 passed，覆盖 queued/unqueued 与 non-Native compatibility 四象限。
- activity admission、pointer capability、pointer/mouse/key semantic、mapping epoch、permission epoch、adapter epoch、mouse release、single-session、session scope、Accessibility 与 Aqua-session 相关 Rust 回归：合计 21 passed，0 failed。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures。
- `swift build -c release --product RustDeskNative`：success。
- `connection.rs` 通过 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

本步自动验证 admission policy 与完整编译链，不能代替 Mini 真机上 modifier down、撤权、断线与本地键状态的 CGEvent 验收。macOS final adapter 在 TCC/session transition 中的实际 key-up 可达性仍属于 H3.4h 已记录的 lifecycle/真机边界。

## Next step

继续审计 simulated mouse 的 queue-admission activity commit；之后若只剩 shared snapshot/UI、Secure Input、布局/IME/快捷键和多显示器真机边界，则停止自动扩展并清楚保留检查点。
