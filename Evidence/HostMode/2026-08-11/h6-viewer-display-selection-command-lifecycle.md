# H6.4c Viewer display-selection command lifecycle

## Outcome

Viewer ABI 已从 v15 升至 v16，并建立 exact display-selection command admission、
Rust pending-command authority、唯一 terminal callback 与 Swift strict projection。本步不接
产品 selector/input quiescence，也不修改 Host display-switch validation，因此不宣称 H6.4
产品完成。

## Implemented contract

- 请求必须携带 Viewer ABI v16、active desktop connection 的 exact nonzero epoch、严格递增的
  positive command ID、当前 available catalog revision 与 online display index；每连接最多一个
  pending selection。
- 函数返回值只表示 admission。选择当前 index 不发送 wire，立即产生 typed
  `alreadySelected`；其他选择复用 pinned RustDesk canonical `Session::switch_display`。
- 只有相同 catalog revision 下匹配 display index 的 `SwitchDisplay` echo 才产生 `selected`。
  catalog change、disconnect/worker exit 与 remote-follow/echo identity drift 分别产生 typed
  `catalogChanged`、`connectionClosed`、`remoteSelectionDrift`，并且只终结一次。
- C header、required shim symbol、Rust callback/state authority、Swift request/event validation 与
  callback delivery 同步升级。成功 echo 先发布当前 catalog selection，再发布 terminal event，
  为后续产品恢复输入保留一致 tuple。
- Host ABI 保持 v17；RustDesk protobuf wire、Hermes、CI、根依赖与数据库均未修改。

## Verification

- Viewer selection Swift regression：2/2。
- Pinned Rust bridge focused regression：45/45（新增 selection lifecycle test 覆盖 already-selected、
  canonical wire send、single-flight、duplicate ID、catalog change、remote drift、stale epoch/revision、
  out-of-range admission 与 disconnect terminal）。
- Fresh arm64 Rust core build：通过；required symbol gate 包含 `rdn_client_select_display`。
- 全量 Swift tests：1000/1000。
- 全量 ScriptTests：181/181；H6.4 ownership audit 状态为
  `selection-command-implemented-product-pending`，无 missing evidence/gaps。
- Pinned source bootstrap check 与 `git diff --check`：通过。
- Fresh arm64 release build：通过。

## Remaining boundary

下一自动步骤为 `host-display-switch-validation-lifecycle`：Host 在改变 monitor service subscription
之前拒绝 negative、out-of-range、offline 或 non-positive geometry display。随后仍需产品 selector 与
pending 期间 input release/pause。双机多显示器、scale/rotation/hot-plug、画面与输入现场验收继续
记录为未验证且不阻塞开发。
