# H3.4j pointer semantic activity side-effect gate

- 日期：2026-08-08
- 范围：pinned RustDesk desktop `server/connection.rs` 与 canonical patch
- 结论：无效或 Native Host 平台不支持的 `PointerDeviceEvent` 不再写入全局 peer-input activity 状态

## Root cause

H3.4d/H3.4f 已分别建立 typed pointer normalization 和平台能力 gate，但 connection ingress 在两者之前调用 `MOUSE_MOVE_TIME.store(...)`。因此缺 union、非法 modifier 或 macOS Native Host 最终必为 no-op 的 touch/pan/scale wire event，虽然不会进入 input queue，仍会被 IPC `MouseMoveTime` 读作最近 peer input。

这使拒绝路径产生了可观察副作用，也让 semantic fail-closed 与 activity authority 不一致。mouse/key 路径已经先 normalization 再更新时间，pointer 是唯一例外。

## Implementation

- 新增内部 `normalize_supported_pointer_input`，把 wire normalization 与 Native Host/platform semantic capability 合并为单一 acceptance gate。
- 只有 gate 返回 typed `NormalizedPointerInput` 后才写入 `MOUSE_MOVE_TIME`、取得 display-mapping snapshot 并进入 input queue。
- malformed/unknown pointer、macOS/Linux Native Host 的全部 pointer kind，以及 Windows Native Host 的 pan kind都在 activity mutation 前返回。
- non-Native pinned upstream 行为保持；Windows Native Host 仍仅允许有真实 consumer 的 scale update。
- 未修改 protobuf、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- 新/扩展 capability test：1 passed，覆盖 malformed event、unsupported/supported scale、Native Host pan rejection 与 non-Native compatibility。
- pointer/mouse/key semantic、mapping epoch、permission epoch、adapter epoch、mouse release、single-session、session scope、Accessibility 与 Aqua-session 相关 Rust 回归：合计 19 passed，0 failed。
- 首次 fresh compile 发现新增 test fixture 缺 protobuf `special_fields`；补 `Default` 后同一测试通过，没有隐藏该失败。
- `Scripts/build-rust-core.sh` 首次按预期拒绝尚未同步的 canonical patch；机械同步后 release core 成功，生成 arm64 Mach-O dylib，保留 130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures。
- `swift build -c release --product RustDeskNative`：success。
- `connection.rs` 通过 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

本步只关闭 rejected pointer 对 activity 状态的污染，不新增 macOS touch/trackpad 注入能力，也不声称完成真实 pointer、多显示器或输入性能验收。pointer capability 若要显式反馈给 Viewer，仍需共享 protobuf 或 Host snapshot contract 决策。

## Next step

继续寻找不依赖 shared contract 的 H3 fail-closed/cleanup 小边界；Secure Input 策略、TCC/session UI 刷新、真实布局/IME/快捷键、多显示器与真机输入保留为已记录检查点。
