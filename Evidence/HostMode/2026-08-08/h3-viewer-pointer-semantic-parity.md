# H3.4s Viewer pointer producer semantic parity

- 日期：2026-08-08
- 范围：FarPane Rust Viewer pointer producer、Host typed mouse contract 与 bridge mirror
- 结论：Viewer ABI 在发出 wire event 前拒绝 Host 必然丢弃的 scroll+button 组合

## Root cause

`rdn_client_send_pointer` 先调用 `pointer_mask`，成功后无异步结果反馈地调用 `session.send_mouse` 并返回 0。旧 `pointer_mask` 只做两类验证：未知 button 位拒绝，Down/Up 必须恰好一个 button；Move、Scroll、PreciseScroll 都可携带任意已知 button 组合。

H3.4c/H3.4r 的 Host typed contract 更严格且有意明确：absolute Move 可携带 held buttons 表达 drag；scroll 和 relative-like operations 不接受 button mask。因此 Scroll/PreciseScroll+button 在 Viewer ABI 返回 success 后必然被 Host 静默拒绝，status 与真实可达行为不一致。

## Implementation

- `pointer_mask` 对 Scroll/PreciseScroll 要求 buttons=0，否则 `rdn_client_send_pointer` 返回 validation error。
- Move 继续接受 left/right/middle 的任意已知 held-button 组合，保持 H3.4r drag producer contract。
- Down/Up 继续要求恰好一个 button；未知位继续在 kind-specific projection 前拒绝。
- Vendor bridge 与 `CoreBridge/RustDeskPatch/rdn_bridge.rs` mirror 同步。
- 未修改 ABI shape、wire/protobuf、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- `maps_semantic_pointer_masks_without_exposing_wire_types`：1 passed，新增覆盖 Move+left+right 可接受、Scroll+left 与 PreciseScroll+right 拒绝。
- `normalizes_wire_mouse_semantics_before_queueing`：1 passed，证明 Host 端相同 contract 继续成立。
- `cargo test --features rdn-native-core,rdn-native-host --lib`：122 passed，0 failed。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures。
- `swift build -c release --product RustDeskNative`：success。
- bridge mirror 逐字一致；Rust 2021 rustfmt、canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

本步修正 status=0 与 Host no-op 的自动可证明缺陷，不等同于真实 scroll/drag CGEvent 验收。用户回来后仍应在 Mini 验证普通滚轮、触控板精确滚动、按住拖动和释放。

## Next step

继续检查 Viewer key/text producer 与 Host typed normalization 是否存在同类 caller-success/remote-no-op；若无，则转向 shared UI/ABI 和真机检查点。
