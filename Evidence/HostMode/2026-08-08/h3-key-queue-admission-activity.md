# H3.4l Native Host key queue-admission activity commit

- 日期：2026-08-08
- 范围：pinned RustDesk desktop `server/connection.rs` 与 canonical patch
- 结论：Native Host key 只有成功取得 permission snapshot 并发送到 connection input queue 后，才提交 click/peer activity 与 auto-disconnect 活动

## Root cause

desktop key ingress 已先做 H3.4e typed normalization，但随后会在 `input_key` 取得 effective permission snapshot 之前：

- Enter 写入 `CLICK_TIME`；
- 所有 canonical key 写入 `MOUSE_MOVE_TIME`；
- 分支末尾无条件重置 auto-disconnect。

`input_key` 在 permission epoch disabled 或 input channel 已关闭时静默返回。因此 permission 已撤销或 peer keyboard disabled 的 Native Host 会话仍可被未入队 key event 推进 activity authority。

## Implementation

- `input_key` 现在返回 queue admission 结果：缺 enabled permission snapshot 或 channel send 失败均为 false。
- H3.4k 的 activity policy 扩展为 mouse/key/pointer 可复用的 `native_host_input_commits_activity`。
- Native Host 只有 queued=true 才写 `CLICK_TIME`/`MOUSE_MOVE_TIME` 并重置 auto-disconnect；peer keyboard disabled 同样不提交。
- non-Native desktop 保留 pinned upstream 的 activity compatibility。
- 本步没有顺带改变 pressed-modifier tracking；该 cleanup state 仍在 `input_key` 前更新，独立留给下一小步审计。
- 未修改 protobuf、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- Native Host activity queue-admission policy：1 passed，覆盖 queued/unqueued 与 non-Native compatibility 四象限。
- pointer capability、pointer/mouse/key semantic、mapping epoch、permission epoch、adapter epoch、mouse release、single-session、session scope、Accessibility 与 Aqua-session 相关 Rust 回归：合计 20 passed，0 failed。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures。
- `swift build -c release --product RustDeskNative`：success。
- `connection.rs` 通过 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

本步将 activity commit 与 authorized queue admission 对齐，但不把 admission 冒充最终 CGEvent：permission/mapping/TCC/session 仍会在 worker 和 platform adapter 复核。physical modifier 的 connection cleanup tracking 仍可能在 queue admission 失败前变化，应作为独立内部 fail-closed 小步处理。

## Next step

优先收敛 Native Host key pressed-modifier tracking 的 queue-admission 边界；之后再审计 simulated mouse 的同类 activity commit。Secure Input、布局/IME/快捷键、多显示器保留为既有检查点。
