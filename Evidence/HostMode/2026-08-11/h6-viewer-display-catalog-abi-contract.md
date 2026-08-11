# H6.4b Viewer display catalog ABI contract

## Outcome

Viewer ABI 已从 v14 升至 v15，并建立 connection-scoped display catalog callback、
严格 Swift 投影和视频帧 tuple 门禁。本步只建立目录与帧归属，不增加 `selectDisplay`
命令、terminal selection event、产品 selector 或 Host 切换范围校验，因此不宣称
H6.4 产品完成。

## Implemented contract

- Rust 从 initial `set_peer_info`、dynamic `set_displays`、remote-follow
  `set_current_display` 与 `SwitchDisplay` echo 归一化目录及当前选择。
- 目录最多 64 项、名称最多 512 UTF-8 bytes；control character、非法 geometry、
  非 finite/非正 scale 或超限目录会整体投影为 typed unavailable，不保留 partial catalog。
- 每次连接分配非零 epoch；首次目录状态 revision=1，semantic duplicate 不推进，
  inventory/status change 推进 revision，selection-only change 保持 revision。
- `RDNEncodedVideoFrame` 绑定同一 `connectionEpoch + catalogRevision + displayIndex`；
  Rust 只发布当前可用选择的帧，Swift 在复制 callback-scoped bytes 前和排队交付前各复核一次。
- dedicated file-transfer session 不发布 display catalog；disconnect/worker exit 清除目录
  authority，迟到目录或帧 fail closed。
- Display name 只作为本地呈现字段，不参与 identity 或 diagnostics。Host ABI 保持 v17，
  RustDesk protobuf wire 与 Hermes 不变。

## Verification

- Viewer catalog Swift regression：3/3。
- Pinned Rust bridge focused regression：44/44（含 2 个新 display catalog tests）。
- Fresh arm64 Rust core build：通过，built core 报告 Viewer ABI v15。
- 全量 Swift tests：998/998。
- 全量 ScriptTests：181/181；H6.4 ownership audit 状态为
  `catalog-abi-implemented-selection-pending`，无 missing evidence/gaps。
- Pinned source verifier、`git diff --check` 与 fresh arm64 release build：通过。

## Remaining boundary

下一自动步骤为 `viewer-select-display-command-lifecycle`：增加 exact
connection/catalog-bound command admission 与唯一 terminal event，仍与产品 UI/input
quiescence、Host range validation 分开。双机多显示器、scale/rotation/hot-plug 与跨屏输入
现场验收继续记录为未验证且不阻塞开发。
