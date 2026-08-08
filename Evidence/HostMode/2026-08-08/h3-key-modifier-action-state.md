# H3.4o Native Host typed modifier action state

- 日期：2026-08-08
- 范围：pinned RustDesk desktop `server/connection.rs` 与 canonical patch
- 结论：Native Host physical-modifier cleanup state 由已授权入队事件的 typed action 决定

## Root cause

H3.4m 已保证 cleanup tracking 只在 `input_key` 成功入队后更新，但更新逻辑仍使用 pinned upstream `is_press`。这个布尔值用于旧 key projection：Linux modifier 会把 down 提升为 press，而其他平台 down 常为 false；它不是 typed `NormalizedKeyInput.action` 的持久状态。

在 macOS Native Host 中，这会产生相反的状态错误：

- typed `Down` 携带 `is_press=false`，成功入队后反而从 cleanup 集合移除，撤权或断线时失去最终 key-up；
- typed `Press` 携带 `is_press=true`，worker 实际会按顺序执行 down 与 up，cleanup 集合却仍把 modifier 视为按住，断线时制造多余 key-up。

## Implementation

- 在任何 legacy platform promotion 前捕获 typed key action。
- Native Host 只在 H3.4m 的 authorized queue admission 成功后按动作更新：`Down` 插入，`Up`/`Press` 移除，`Text` 不参与 physical modifier tracking。
- `Press` 的状态与 worker 的 ordered down+up 执行语义一致。
- non-Native desktop 保留 pinned upstream `is_press` compatibility，避免改变共享 upstream 行为。
- 未修改 wire key semantics、protobuf、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- Native Host typed modifier action state test：1 passed，覆盖 Down/Up/Press/Text 与 non-Native compatibility。
- modifier admission、activity admission、pointer capability、pointer/mouse/key semantic、mapping epoch、permission epoch、adapter epoch、mouse release、native remote、single-session、session scope、Accessibility 与 Aqua-session 相关 Rust 回归：合计 22 passed，0 failed。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures。
- `swift build -c release --product RustDeskNative`：success。
- `connection.rs` 通过 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

本步证明 typed action 与 cleanup state machine 的代码关系及完整构建链，不能代替 Mini 上真实 CGEvent modifier down、permission revoke、disconnect 与本地键状态验收。TCC/session transition 期间最终 key-up 的实际可达性仍属于已记录的 lifecycle/真机边界。

## Next step

继续审计是否还有不需要 shared HostSnapshot/UI 或真机决策的内部 H3.4 semantic fail-closed 边界；若只剩 Secure Input、TCC/session 状态同步、布局/IME/系统快捷键和多显示器，则转入明确检查点，不扩大共享 contract。
