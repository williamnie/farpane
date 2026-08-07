# Host Mode H1 Golden Connection 验收步骤

本步骤只补 `docs/host-mode-design.md` §26.4 的真实控制端门禁，不替代已有自动测试。必须使用另一台机器上的 FarPane Viewer；同一 Mac 自连、合成 fixture 或仅看到 Host `ready` 均不算通过。首轮可使用只消费 HEVC 的旧版 FarPane，随后再用新版 FarPane 补 H.264 回归。

## 前置条件

- 先构建并安装本分支最新的稳定签名 App；预检默认验证 `~/Applications/FarPane.app`，也可用 `RDN_HOST_GOLDEN_APP` 指定将要启动的 App；
- 在被控端仓库运行 `Scripts/preflight-host-mode-h1-golden.sh`，必须得到 `H1_GOLDEN_PREFLIGHT_READY`；脚本会核对实际 App executable/Core 的 Mach-O UUID，且在产物不一致、签名不稳定、真实 SCK/硬编测试被 skip 时 fail closed；
- 启动刚通过预检的同一个 App，Host 首页显示“可被连接”；
- 屏幕录制权限已授予 FarPane；
- 控制端 FarPane 配置同一 Hermes ID Server 与 hbbs 公钥；
- 验收前隐藏 FarPane 临时密码，截图和日志不得包含本机 ID、密码、公钥或服务器私钥。

## 操作

1. 在控制端使用 FarPane 首页显示的本机 ID 和一次性临时密码建立会话。
2. 等待控制端出现单显示器桌面画面，并在 FarPane 首页依次确认状态至少到达：
   - `控制端已订阅，正在准备画面…`；
   - `媒体帧已进入 Rust 发送链路`；
   - `媒体帧已获远端确认`。
3. 如果控制端提供 `Refresh`（中文为“刷新画面”），手动触发一次；旧版 FarPane 没有该按钮时，可由 Viewer 解码恢复自动发出 Refresh 请求，以 Host 显示“远端请求刷新，正在生成关键帧”为准。
4. 确认 Host 随后显示 `刷新关键帧已发送`，且控制端在同一会话、无需重连即可继续显示并更新画面。
5. 在控制端断开连接，确认 FarPane 回到“可被连接”，采集和编码停止。

## 通过标准

| 门禁 | 权威证据 |
| --- | --- |
| active subscriber | FarPane 出现当前 route 的订阅/采集状态 |
| SCK→VT→ABI→Rust writer | `媒体帧已进入 Rust 发送链路` |
| RustDesk transport ACK | `媒体帧已获远端确认`；该单行状态可能被后续刷新状态覆盖，未看到时记录为未观察，不据此否定已经可见的远端画面 |
| decoder/framing 互操作 | FarPane 控制端实际持续显示正确画面 |
| Refresh→IDR | 手动刷新或旧 Viewer 自动恢复后，Host 依次显示请求刷新与 `刷新关键帧已发送` |
| 恢复有效 | 同一控制端会话无需重连即继续显示动态画面 |
| teardown | 断开后 Host 回到 ready，SCK/VT 停止 |

`mediaDiagnostic` 只证明 writer/ACK 边界，不能单独证明 decoder 已渲染；远端可见画面必须人工确认。验收结果填写 `Evidence/HostMode/2026-08-07/h1-golden-connection-template.md`，失败时记录停在哪个状态和 FarPane 控制端版本，不记录敏感值。
