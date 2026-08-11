# H6.3m build-bundle single-Mac preflight

## Outcome

H6.3 的最新 `Build/FarPane.app` 已完成不启动 GUI 的 Mac mini 单机
preflight。旧 golden preflight 直接 reverse-check 最底层 Rust patch，在 H3–H6
后续 patch 已叠加时会误报；现改为调用独立只读验证器检查当前完整 patch 栈、
canonical bridge source 和 pinned RustDesk revision。

`installedSingleMacSmokeComplete=false`：当前运行的是
`/Applications/FarPane.app` build `20260808131034`，其 bundled Core 不含 Viewer
upload ABI。为避免覆盖正在运行的 App、制造多实例或改变 TCC identity，本步没有
停止、安装或启动 App。最新 build `202608111329` 保留在仓库 `Build/FarPane.app`。

## Key evidence

- 只读验证器确认 RustDesk pinned commit
  `6c578292e8ebbbec708b76986ba8c4bc7c509747`。
- 验证 current Viewer upload top layer、native read/list/download top layer、
  hbb_common secret-wipe 与 bounded-block layers 均可 reverse-check。
- `rdn_bridge.rs`、`rdn_host_bridge.rs`、`rdn_host_file_transfer.rs` 与仓库
  canonical source 逐字节一致。
- 回归测试在验证前后比较 RustDesk 与 hbb_common checkout 状态，确认验证器不修改
  working tree。
- 最新 bundle 的 Core 导出 `_rdn_client_file_transfer_upload_start`；当前运行的旧
  installed bundle 不导出该 symbol。

## Verification

- `python3 -m unittest Tests.ScriptTests.test_verify_rustdesk_core_source`：2/2。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：180/180。
- `zsh -n`、`git diff --check`：通过。
- `RDN_HOST_GOLDEN_APP=.../Build/FarPane.app Scripts/preflight-host-mode-h1-golden.sh`：
  `H1_GOLDEN_PREFLIGHT_READY`；fresh release build、stable codesign、App/Core UUID
  一致、sanitized diagnostic 1/1、真实 ScreenCaptureKit → hardware H.264 1/1。
- 最新 bundle executable 的 `--help` no-window smoke：退出 0。

## Next step

H6.3 产品开发代码保持完成；installed-new-build smoke 与双机传输继续记为未验证且
不阻塞开发。下一自动开发边界进入 H6.4 `selectDisplay` / revisioned display
mapping 架构与 ownership 审计。
