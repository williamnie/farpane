# FarPane Linux GPU 媒体重构（hermes）：配置事务与 Viewer 基础层

2026-10-16。分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本轮所有改动仍未提交。未安装或替换宿主应用、启停宿主服务、读取用户密码、操作宿主桌面或使用 GPU。FFmpeg 9.0.2 静态库继续复用，没有重建。

完整原生 GUI / 后端对接 / 安装包目标仍在进行。这里是开发检查点，**不是可交付的完整 Viewer 或安装包**。既有方案评审已收敛，延迟到达的 ocs seq 2 没有重新启动评审或开发者会话。

## 本轮改动

- `0017-native-durable-configuration.patch`、`native_config_store.rs`：配置候选先持久化，再替换内存。两个旧 TOML 文件使用加密恢复记录、文件与目录 fsync、同目录原子 rename；全新安装另有幂等初始化标记。准备前失败不增加 revision；准备完成后失败要求进程恢复，避免后台旧状态覆盖事务。记录不能指定任意文件，损坏记录被拒绝且不回显内容。
- `0018-native-viewer-boundary.patch`、`native_viewer_config.rs`：第一次配置访问前设置不可逆 Viewer 模式，只接受 GUI 提供的公开 ID/服务器快照。禁用旧配置与 PeerConfig 的磁盘读写、密码保存、隐式迁移；会话偏好留在内存。网络服务器、公钥和 NAT 参数直接读取快照；主 IPC 连接/监听入口拒绝 Viewer 访问 Host/CM/root 服务。
- `Linux/native/protocol/src/frame_socket.rs`：有界 AF_UNIX SOCK_SEQPACKET + SCM_RIGHTS 帧/归还通道。对象数量与元数据一致，FD 默认 CLOEXEC；解析失败、截断和消息类型错误自动关闭接收 FD。通道经已认证控制连接传递；并行单测的 FD 泄漏计数使用独立子进程。
- `viewer_decode.cpp/.h`、`Linux/native/decode.rs`：可构建的 H.264/HEVC VAAPI→DRM_PRIME 适配。只接受已打开的 DRM render FD，不访问显示/主节点；分离 R8/GR88 层，保留原 AVFrame 与映射引用，最多出借 3 帧。固定 surface 上限 23、对齐像素上限 2560×1600；错误停止当前代，不自动换池继续提交。颜色元数据保留、缺省显式标记，HDR/不支持矩阵/原点裁剪拒绝。该适配尚未挂到 worker 和 GUI，尚未验证真实解码或 GPU 内存。
- `verify-sources.py`：从独立 hbb_common pin 重建子模块中的被修改文件，修正此前只从 RustDesk 顶层 git 对象读取的遗漏。源码、补丁、pin/hash 都在 Linux 下；构建副本和缓存仍在 Build 下。

## 实际检查

| 检查 | 结果 | 原始记录 |
| --- | --- | --- |
| native core Release | 通过，3m23s | `native-viewer-foundation-release.log` |
| hbb 配置事务及 Viewer 只读边界 | 5 通过，含一个供父测试启动的子进程入口 | `native-foundation-regression.log` |
| core 颜色/FD/进程身份/Viewer 网络与 IPC 边界 | 5 通过，含一个子进程入口；没有 GPU | 同上 |
| 原 Host GPU 租约与初始化失败清理 | 2 通过；需要真实 GPU 的 1 项忽略 | 同上 |
| 旧 Flutter/GPU feature check | 通过，legacy 行为仍可构建 | 同上 |
| 轻量协议、监管、FD、transport | 17 通过，默认并行测试 | `native-foundation-gui-tests.log` |
| GUI 状态模型 / Release | 2 通过 / 编译通过 | 同上 |
| staging 保留未知修改 | 4 通过 | `native-foundation-stage-tests.log` |
| 配置 CLI smoke | 13 项通过；写失败、加密记录恢复、损坏记录拒绝等 | `native-foundation-config-smoke.log` |
| Host/GUI smoke | 9 项通过；两轮 GUI 关闭保留同一 Host，离线 helper 亦通过 | `native-foundation-host-smoke.log`、`runtime/` |
| canonical 重建 | 62 个 patch/overlay 文件匹配；锁文件匹配 | `native-viewer-foundation-canonical.json` |

单测程序报告合计 35 通过、1 项真实 GPU 测试忽略。配置 smoke 与 Host/GUI smoke 分列，不等同于所有交互功能验收。`validation-commands.sh` 保存本轮 core 检查命令，须通过隔离 `container.sh` 入口运行。协议与 GUI 使用 `native-container.sh`；Host/GUI smoke 只在临时容器内组装 root-owned release，然后降为普通用户运行私有 Xvfb/D-Bus，不连接宿主显示、GPU、服务 socket 或网络。

## 未验收项与后续

- **Viewer 仍未接通。** 当前 `--viewer` 入口、认证/重连、实际 codec 能力协商、GPU 导入 modifier 协商、GtkGLArea/EGL 分平面 shader、完成 fence 与 watchdog、受限软件兼容模式均需要继续实现/接入。GUI 的连接按钮仍禁用，`runtime_ready=false`。这次测试不包含真实传输、解码、画质或延迟。
- 出借帧只能在从未提交给 GUI 或完成 GPU 读取后归还。通道 HUP 不是完成证明。FFmpeg READ 映射内部的 `vaSyncSurface` 和驱动销毁可能阻塞；worker 监管及实际驱动完成语义尚未验证。
- 固定 23 surface 是开发上限，不是内存目标已达成。实际 DPB、显存、池大小优化及 Viewer 240 MiB 总预算仍待原型验证；不能静默放宽原方案预算。
- 完整设备管理、共享策略、通知/SNI、音频源、后台运行、睡眠/网络恢复，以及 Viewer 输入/IME、显示器选择、音频、剪贴板、文件传输、HUD/诊断仍在完整交付范围内。
- 实际 root 监管、用户/显示切换、入站审批/撤权与文件任务、长连接和故障恢复，发行版 ABI/干净依赖、安装升级回退及最终发布包尚未验收。

当前私有 Xvfb 首页 PSS 为 117,662 / 108,561 KiB（114.9 / 106.0 MiB），仍高于 60 MiB 目标。完整原始内存、maps、状态与截图在 `runtime/`，提取值在 `memory-samples.json`。这些非同时样本没有真实媒体/root/GPU，不能相加或直接与在线安装版做 A/B。

`source-state.json` 记录本轮 canonical 源码与 core/GUI 二进制 SHA256；`SHA256SUMS` 校验本目录。上轮证据保持原样，不用本轮源码或产物替换旧记录。
