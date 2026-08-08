# H3.4r typed absolute-drag held buttons

- 日期：2026-08-08
- 范围：FarPane Viewer pointer producer、pinned RustDesk Host mouse normalization 与 canonical patch
- 结论：typed Host mouse normalization 接受 absolute drag 的已知 held-button mask，同时继续拒绝歧义/未知组合

## Root cause

真实 producer 链明确要求 Move 携带 held buttons：

- `ViewerMetalView.sendButton` 在 down 后记录 `heldButtons`；
- `ViewerMetalView.sendMove` 把当前集合写入 `CorePointerEvent(kind: .move, buttons: heldButtons)`；
- Rust `rdn_client_send_pointer` 的 `pointer_mask` 允许 Move 携带合法 left/right/middle bit，并生成 upstream `MOUSE_TYPE_MOVE | (buttons << 3)`。

H3.4c 新增的 `NormalizedMouseInput::from_wire` 却只把 `MOUSE_TYPE_MOVE` 且 `buttons == 0` 识别为 `AbsoluteMove`。因此 click 的 down/up 可以入队，但 down 后移动会在 mapping、permission snapshot 和 adapter 之前被拒绝，所有 FarPane-to-FarPane drag 都会失去 move 阶段。

## Implementation

- absolute move 允许 left/right/middle/back/forward 的任意已知 held-button 组合，原 wire mask保留到 adapter。
- adapter 对 Move 不会重复 press 按钮；held mask只表达 controller 当前 drag 状态，真实 button state 仍由独立 down/up 与 ordered cleanup 管理。
- button down/up 继续通过 semantic button conversion 限定单 button。
- relative move、discrete/precise scroll 仍要求 buttons=0；未知 button 位仍 fail closed。
- 未修改 wire/protobuf、Viewer ABI、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- `normalizes_wire_mouse_semantics_before_queueing`：1 passed，覆盖 left+right held drag 可接受，以及 unknown held bit、scroll+button、multi-button down 继续拒绝。
- `cargo test --features rdn-native-core,rdn-native-host --lib`：122 passed，0 failed；覆盖 input cleanup/lease/epoch/mapping/adapter、mouse/pointer/key semantics、session/TCC/bridge 与其他 pinned lib 回归。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures；其中 AspectFit mapper 覆盖 drag 越界 clamp。
- `swift build -c release --product RustDeskNative`：success。
- touched Rust files 通过 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

本步恢复并自动验证 producer/normalizer contract，不能代替 Mini 上真实 CGEvent click-drag。用户回来后应至少验证窗口拖动、文本选择和跨画面边界 drag；多显示器映射仍是独立真机门禁。

## Next step

继续检查 typed mouse 的 button coordinate sentinel、multi-button 状态与 cleanup 是否保持同一语义；若无更多内部缺陷，则转向 shared UI/ABI 与真机检查点。
