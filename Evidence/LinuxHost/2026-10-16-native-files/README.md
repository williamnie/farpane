# FarPane Linux GPU 媒体重构（linux-host）：原生文件连接与 GUI

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40b`。这是完整 GUI 开发中的文件检查点，尚未打包交付或安装。原 RustDesk、已安装 FarPane、宿主桌面/音频/显示、FFmpeg 静态库均未修改。本轮没有运行 GPU 探针，没有启动或切换宿主服务，没有 commit/push。

## 实现

- `0022/0023` canonical patches 接入 Host 和 Viewer 的独立文件登录类型、分页扩展、网络分流及传输层报文上限；`Linux/native/files.rs/file_host.rs/file_viewer.rs` 在专用线程执行文件 I/O，GTK/视频循环不等待磁盘。
- GUI 的共享目录、逐次确认、文件窗口、密码重试、分页、上传/下载、进度、取消、双端覆盖确认和入站撤权已接真实后端。文件连接独立于视频，最多一个文件窗口/worker；不初始化视频帧池、GLArea 或音频。其他设备请求不会复用当前文件连接。
- Native Host 文件权限默认要求明确选择私有共享根；保留旧运行时的原始文件选项，不静默开启无范围访问。用户 agent 的 UID/私有根替代旧 seat0 用户判断；root agent 不提供文件共享。真实 greeter/用户切换仍待验收。
- Host 至多四个文件 worker、每个八个任务，GUI 任务记录至多十六项；输入八项、输出四项队列，报文 320 KiB、数据块 128 KiB、目录页 128 项/16 KiB，有界 zstd 输出/窗口。到期清理同时覆盖文件 owner 和等待最后 Done 的 wire 状态。
- 撤权、断开和共享根变化使旧 worker 停止。成功的控制确认等待 owner/writer 清理；超时返回清理尚未结束，不能冒充完成。Viewer 正常退出也先等待文件线程清理，GUI 确认子进程回收后关闭窗口。
- 上传等待 Host 落盘 ACK；下载在本地 writer 提交后才报完成。Host 发送端只显示“已发送”，不宣称对端已保存。退出后未完成的 GUI 任务显示“已中断/已取消”。

## 真实测试

全部在临时 Docker 的 loopback、两个私有 Xvfb 和普通用户配置中运行，不挂载宿主桌面、音频、GPU 或服务 socket。矩阵测试用一条有界限速 loopback 转发链路，保证中途撤权可重复；它不是产品的额外服务。

| 原始目录 | 结果 |
| --- | --- |
| `154717Z`、`155347Z` | 保留失败报告：文件窗口遗漏普通密码提示，随后发现旧 seat0 用户判断导致文件登录结束；另外修复 worker 已退出后辅助窗口不能关闭的问题 |
| `160232Z` | 首轮通过：错误密码重试、1000 项目录的前两页、393233 字节上传/下载、两个真实 Host 确认按钮、确认前取消、相同 SHA-256、无临时文件、Host 配置和进程保留 |
| `160712Z`、`160923Z` | 测试驱动未等待 Host 拒绝快照更新，误点旧任务；GUI busy 保护阻止重复提交。后续等待旧任务终态并识别新任务，未绕过批准流程 |
| `161105Z` | 覆盖上传成功，本地下载覆盖对话框已出现；测试查错窗口集合，改用 GTK 顶层窗口检索 |
| `161245Z` | 覆盖/拒绝和真实文件撤权通过；随后发现 GUI 在 worker 退出后仍显示旧发送状态，补上终态转换 |
| `161436Z` | 最终矩阵通过：Host 拒绝覆盖保留原文件、覆盖 checkbox 默认未勾选、显式批准替换、本地覆盖对话框、原文件在确认前保留；16 MiB 上传在 Host 收到 4718592 字节后由实际撤权按钮终止，文件/临时文件清除、任务终态和 worker 回收通过，无 Host 控制错误提示 |
| `161507Z` | 最终空文件上传/下载通过，SHA-256 一致，无残留，Host 配置/身份保留 |
| `161541Z` | 最终音频/视频回归通过：两次真实软件视频呈现及 Opus 播放约 440 Hz，关闭/撤权后静音、重开恢复，私有 Pulse 故障后视频仍刷新；迁移选择 UI 也通过 |

上表前缀均为 `runs/20261016T…`，报告、进度事件、实际界面截图、maps/PSS 样本及日志保留。失败轮使用中间源码，不能当作最终二进制运行结果。`source-state.json` 固定最终 canonical 源码和两个开发二进制 SHA-256；可再生 `.bin`/音频样本只记录大小和哈希。

最终协议 21 项、文件存储 18 项、GUI 3 项测试通过；离线配置 27 项检查通过，覆盖私有目录创建/拒绝公开目录且不 chmod、配置 revision、旧设置保留及离线角色不能批准文件任务。staging 5 项测试、45 文件只读校验、pin/patch/overlay/lock 重建核对通过。native core/GUI Release、旧 Flutter/GPU feature 组合 check 通过；没有重建 FFmpeg。

## 资源与未验收项

最终矩阵在截图前采样：GUI PSS 127180 KiB（124.2 MiB）、文件 worker 11792 KiB（11.5 MiB）、Host 47307 KiB（46.2 MiB）。Host/文件 worker 的实际 maps 无 GTK3/Flutter/Sciter。该样本同时打开首页及文件窗口，不含 root 服务、视频或 GPU；不能据此宣称首页 60 MiB 或媒体组合预算达标。方案明确补入文件专用 worker 的额外进程成本。

仍须完成目录/多文件传输、Mac/旧 RustDesk 互操作、媒体和文件并存、断网/磁盘/报文限额/超时/所有撤权路径的实际故障矩阵、真实桌面与长稳。当前是单文件功能检查点；完整 GUI、跨发行版 ABI、桌面集成、完整安装包和用户验收均未完成。保留原可用版本，不安装这个未完成的原型。

```sh
python3 -B Scripts/linux/prepare-native.py --check
Scripts/linux/test-native-viewer.sh files
Scripts/linux/test-native-viewer.sh files-empty
Scripts/linux/test-native-viewer.sh files-matrix
Scripts/linux/test-native-viewer.sh audio
Scripts/linux/container.sh -c 'python3 -B Linux/tests/native_config_smoke.py'
```
