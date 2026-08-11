# H6.4a multi-display selection ownership audit

## Outcome

H6.4 当前尚未实现，且下一步必须先经过 Viewer ABI 检查点。Pinned RustDesk
已经提供 display inventory、`Session::switch_display`、Host service subscription
切换及 connection-scoped input-mapping generation；缺口位于 FarPane native
Viewer：ABI v14 丢弃 initial/dynamic display catalog 与 selected-display callbacks，
帧只携带裸 display index，产品 UI 也没有选择入口。

机器审计将下一合同冻结为 Viewer ABI v15；Host ABI 保持 v17，RustDesk protobuf
wire、Hermes、CI、依赖与数据库均无需改变。本步只审计，没有修改共享 ABI 或产品
行为，也不宣称多显示器切换完成。

## Current authoritative chain

1. Pinned Host display service 在登录时把 `displays + current_display` 写入
   `PeerInfo`，之后以约 300 ms cadence 在 inventory 发生变化时发送新的
   `PeerInfo.displays`。
2. Pinned Viewer `Session::switch_display` 已通过 canonical
   `Misc::SwitchDisplay` 发送 index，并同步更新 capture subscription。
3. Host `Connection::handle_switch_display` 切换 old/new monitor service；macOS
   connection 同时推进现有 input-mapping generation，使切换前排队输入无法越过。
4. Host `SwitchDisplay` echo 与 `VideoFrame` 使用同一 video channel；Viewer io-loop
   先消费 echo/reset，再处理后续帧，可作为选择完成的远端权威。
5. Host media `displayRevision` 是 per-display route reconfigure authority；H3 input
   mapping generation 是 Host connection 内部 authority。两者都不能充当 Viewer
   catalog revision。

## Confirmed gaps

- `BridgeUi.set_peer_info`、`set_displays`、`set_current_display` 当前均为 no-op；
  `switch_display` 只更新宽高。
- Viewer C ABI/Swift shim 没有 display catalog callback、selection command 或 terminal
  selection event。
- `RDNEncodedVideoFrame` 只有裸 `display`，没有 connection/catalog binding。
- Host 当前先把 `s.display` cast 为 `usize`，没有在改变 service subscription 前显式
  拒绝负数、越界、offline 或非正 geometry。
- Viewer UI 没有 selector，选择期间也没有 release/pause input 生命周期。

## Frozen next contract

- Viewer ABI v15 引入 per-connection monotonic catalog；identity 固定为
  `connectionEpoch + catalogRevision + displayIndex`。display name 仅用于本地呈现，
  不参与 identity，也不得进入 diagnostics。
- Initial `set_peer_info` 原子安装 inventory/current selection；dynamic
  `set_displays` 只替换 inventory，不能信任兼容字段 `current_display=0`；
  `set_current_display` 处理 remote-follow，`switch_display` 处理 authoritative echo。
- `selectDisplay` request 必须包含 ABI、connection epoch、positive unique command ID、
  exact catalog revision 与 display index。同一 connection 至多一个 pending command；
  C return 只表示 admission，所有 admitted command 必须恰有一个 terminal event。
- 选择当前 index 不能依赖远端不会发送的 echo：Rust 直接产生
  `alreadySelected` terminal event，但仍不允许 Swift 从函数返回值推断完成。
- catalog 变化、disconnect、malformed echo 或 identity drift 必须终止 pending command；
  matching remote echo under unchanged revision 才能成功。
- inventory 上限 64，display name 上限 512 UTF-8 bytes；malformed catalog 整体拒绝，
  semantic duplicate 不推进 revision，semantic change 必须推进。
- 帧绑定相同 connection/catalog/selected-index tuple；Swift 丢弃不匹配帧。产品在
  pending selection 期间先 release 并暂停输入，只有 matching terminal success 后恢复。
- Host 在切换 service 前必须再次验证 index、online 与 geometry。仍只选择一个显示器，
  不启用 multi-capture，也不更改 Host ABI/wire。

## Machine-readable audit

`Scripts/audit-host-multi-display-selection-ownership.py` 先运行只读 current patch-stack
verifier，再审计 exact pinned upstream source、tracked Rust/Swift bridge、Viewer UI 与
设计文档。输出 schema
`farpane-host-multi-display-selection-ownership-audit` v1，当前状态为
`abi-checkpoint-required`，8/8 ownership evidence、8/8 confirmed gaps 和 8/8 source
anchors 均成立。

## Verification

- RED：focused regression 只因审计器缺失而失败。
- GREEN：`python3 -m unittest Tests.ScriptTests.test_host_multi_display_selection_ownership_audit`
  为 1/1。
- `python3 Scripts/audit-host-multi-display-selection-ownership.py`：
  `abi-checkpoint-required`，无 missing evidence/gaps。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：181/181。
- Python compile、`git diff --check`：通过。
- `swift build -c release --arch arm64`：fresh production build 通过。

## Remaining boundary

下一自动步骤为 `viewer-display-catalog-abi-contract`：只建立 ABI v15 catalog/event/
frame binding 与 strict Swift projection，尚不接 UI 选择动作。之后再独立实现 selection
command/Host range validation、产品 selector 与 input quiescence。双机多显示器切换、
排列/缩放/旋转/热插拔和输入坐标验收继续记为未验证且不阻塞自动开发。
