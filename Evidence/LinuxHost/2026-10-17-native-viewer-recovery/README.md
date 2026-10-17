# FarPane Linux GPU 媒体重构（hermes）：Viewer 自动重连

分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本阶段完成，完整 GUI 交付仍进行中；没有安装、提交、推送或发布。

## 实际检查

- 离线 locked core/GUI Release、source receipt、63 个 canonical staging 文件及 pin/patch/overlay 核对通过。FFmpeg 静态库复用。
- 9 项 GUI 单测（含 3 项恢复策略）、38 项协议测试通过；1 项既有图形单测按环境要求跳过。实际 GTK 呈现另行验证。
- 原生无 GPU `--no-default-features --features farpane-native --lib` 与保留默认 features 的旧 `--features flutter,hwcodec,drm,farpane-linux,linux-gpu-media --lib` 检查通过。
- `20261017T020927Z` 的 7 轮真实 GUI/Host/Viewer 会话、8 项检查通过：观察到网络离线后暂停并用保存密码恢复画面；同 GUI 回收旧 worker；取消停顿的密码库读取；错误/缺失密码停止；实际 Host 断开按钮不重连；4 次实际替换连接后停止；服务器范围变化取消恢复。
- `20261017T021246Z` 文件回归 13 项通过，包含空文件实际上传/下载、错误密码、分页、批准、取消、哈希和回收。
- 同一开发包在 Ubuntu 26.04 `20261017T021416Z`、Ubuntu 24.04 `20261017T021445Z` 各通过 8 组包/私有库检查及两次真实软件视频连接。
- 宿主前后只读核对：现有 FarPane/RustDesk 服务状态和 PID、current、分支/HEAD 相同；四个 FFmpeg 静态库大小、mtime 和 SHA-256 相同。

产物：`Build/Linux/artifacts/farpane-native-dev-d0fb65c957b35a48743a82d2`，283 个清单条目。

tar.gz SHA-256：`c31db7c9c7eb19eb681c28302d209e0d063a4ade437a5e96e85212284465246a`。

原始 core SHA-256：`9a6cbbb4dca96c976356d634fab6ef60936f0247b2341ceeb22376a95d48ae1b`；GUI：`084241464d065df9df864c9828c46d866b530e99acaf2d239d499505eacb495e`。包内 core 的 RPATH 在副本中处理，实际包哈希以 artifact-build.json 为准。`runtime_ready=false`，尚未满足完整发布验收。

## 代码与回归范围

- 新 `Linux/gui/src/viewer_recovery.rs` 持有一次逻辑会话的显式授权、四次退避、实际呈现期限和凭据范围；没有全局自动读取密码库选项或常驻明文密码。
- `viewer.rs` 增加可取消的会话开关、密码库读取与结果失效、基于已观察 Host 状态的暂停；只有 after-paint 确认真实画面才重置预算。手动认证、2FA/安全确认和不可恢复故障保持人工操作。
- `app.rs` 复用既有先回收再启动的窗口替换路径，自动替换保留逻辑授权和当前音频开关；手动重试创建新授权范围。
- 原生协议及 `native/viewer_ui.rs` 转发现有核心重试判断，诊断只记录布尔值。没有修改共享 RustDesk 网络算法或扩大旧 feature 路径。
- `native/viewer.rs` 在排空控制事件前观察停止标志，避免结束事件刚入队就退出；`viewer_bridge.rs` 在帧 EOF 后给控制结束事件保留排空窗口，不从 EOF 推断重试许可。这个桥也用于文件 worker，因此做了实际文件回归。
- 既有隔离 smoke 入口增加自动重连驱动和实际 Host 断开按钮；配置 CLI 仍无断开入站连接权限。源码、overlay 哈希、文档同步，没有增加依赖、改变上游 pin 或重建 FFmpeg。

## 原始失败与修正

1. `20261017T015320Z`：帧 EOF 先结束控制桥，GUI 未收到核心结束/重试事件，自动恢复没有发生。修正控制通道排空和核心停止时的事件发送顺序。失败代码与构建记录保留。
2. `20261017T020044Z`：实际已经重新出图，但夹具仅等待后端离线，没有等待 GUI 约一秒快照刷新，就要求下一次重连暂停。改为先确认 GUI 已观察到离线再切断；不据此声称发生了媒体恢复失败，也不承诺尚未观察的网络状态立即生效。
3. `20261017T020225Z`：前五项通过，夹具尝试用配置 CLI 执行断开，按既有权限被拒绝。改为实际 GApplication 打开管理对话框并点击 Host 断开按钮；未放宽 CLI。另修正取消读取后仍显示“正在读取”的反馈。
4. 中间 build-2 为纳入第二项退出竞态修正而主动停止自己的隔离 builder，exit 137 与原因保留；不是通过的构建，也未停止宿主服务。

最终完整运行通过后没有再修改编译代码。截图已检查 `network/viewer-window.png`，可见真实画面与勾选的恢复开关。测试进度文件仅用于私有测试，不以该运行作为内存/CPU 基准。

## 证据与限制

`recovery-runs/` 保存三次失败、最终运行和文件回归；`package-runs/` 保存发行环境、加载闭包和视频运行；`logs/` 保存构建/单测/feature/打包/源码核对及宿主前后状态。截图仍在对应 Build 原始目录。`source-state.json` 记录 309 个 canonical 文件哈希；`SHA256SUMS` 覆盖本归档。

复现入口为 `Scripts/linux/test-native-viewer.sh auto-reconnect`、`files-empty` 和 `Scripts/linux/test-native-package.sh ARTIFACT [ubuntu-24.04]`，全部使用既有隔离镜像。不是宿主安装或服务切换命令，不需重建 FFmpeg。

本轮未操作真实系统电源/网络、桌面、密码库、GPU 或服务。真实 suspend/resume、跨机网络/中继、Mac/旧版、2FA、GPU/合成器故障、硬件音频、长稳与低内存仍须验收；首页 60 MiB 目标与最大剪贴板资源目标尚未通过。正式 deb/RPM、发布 CI、完整第三方许可证与对应源码交付仍有独立工作。
