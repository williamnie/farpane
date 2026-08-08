# H3.4k Native Host pointer queue-admission activity commit

- 日期：2026-08-08
- 范围：pinned RustDesk desktop `server/connection.rs` 与 canonical patch
- 结论：Native Host 只有在 pointer input 成功取得 permission snapshot 并发送到 connection input queue 后，才提交 peer activity 与 auto-disconnect 活动

## Root cause

H3.4j 已让 pointer 在 typed normalization/platform capability 通过后才写 `MOUSE_MOVE_TIME`，但仍有两个拒绝窗口：

- `peer_keyboard_enabled()` 为 false 时不处理 pointer，分支末尾却无条件调用 `update_auto_disconnect_timer()`；
- platform 支持的 pointer（当前为 Windows scale）可能因 effective input permission epoch disabled 而无法取得 snapshot，原 `input_pointer` 静默返回，但调用方已经写了 `MOUSE_MOVE_TIME`，随后仍重置 auto-disconnect。

因此 semantic/platform gate 通过不等于输入已被授权接纳，Native Host 的活动 authority 仍可能被未入队事件推进。

## Implementation

- `input_pointer` 现在返回 queue admission 结果：缺 enabled permission snapshot 或 channel send 失败均为 false。
- 新增内部 `pointer_input_commits_activity(nativeHostActive, queued)` policy；Native Host 只在 queued=true 时提交 `MOUSE_MOVE_TIME` 与 auto-disconnect activity。
- permission 关闭、epoch disabled、input channel 关闭或未进入 pointer 分支时，Native Host 均不提交活动。
- non-Native desktop 保留 pinned upstream 的 activity 行为；Android/iOS 原有 auto-disconnect 更新显式保留。
- 未修改 protobuf、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- pointer capability/activity policy：1 passed，覆盖 Native Host queued/unqueued 与 non-Native compatibility 四象限，以及 H3.4j 的 malformed/capability cases。
- pointer/mouse/key semantic、mapping epoch、permission epoch、adapter epoch、mouse release、single-session、session scope、Accessibility 与 Aqua-session 相关 Rust 回归：合计 19 passed，0 failed。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures。
- `swift build -c release --product RustDeskNative`：success。
- `connection.rs` 通过 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

本步不改变 non-Native activity compatibility，也没有把 queue admission 冒充最终 CGEvent 执行：permission/mapping epoch 仍可能在排队后撤销，此时 final adapter 按 H3.4a/H3.4b 拒绝。TCC/session transition cleanup 与 UI limited 状态仍需要共享 lifecycle contract 或真机验收。

## Next step

继续审计 mouse/key 是否存在同类 Native Host queue-admission 前 activity commit，并一次只收敛一个可验证路径；Secure Input、布局/IME/快捷键、多显示器保留为已记录检查点。
