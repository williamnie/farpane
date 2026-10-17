# FarPane Linux GPU 媒体重构（linux-host）：Host / 原生首页对接

2026-10-16。基线 `b01c40bd7da588f0ec2add2947a9368289006792`，分支 `codex/linux-host-gpu-media`。所有改动未提交，完整 GUI 交付目标仍在进行。没有安装、替换、启停宿主 FarPane/RustDesk，没有打开宿主桌面或访问 GPU。

## 实际实现与边界

- `0016-native-host-runtime.patch` 和 `Linux/native/` 接入内置 CM、真实活动计数、精确 pidfd 进程选择、root 监管入口、受限配置与已鉴权控制接口；旧 `--cm`/`--tray` 自动拉起被隔离。GPU 代码仅增加租约/退役资源的活动计数，不改变转换和编码数据通路。
- 配置在首次懒加载前取得生命周期 flock；在线命令转发 agent，离线配置助手不启动 Host；revision 防止旧表单覆盖新设置。旧 Flutter FarPane 没有这个锁，因此旧 IPC 仍活动时拒绝迁移。只检查 FarPane 命名空间，不探测 RustDesk。
- 控制接口要求同 UID、SO_PEERPIDFD、相同 root-owned release 中的可执行文件，以及正确版本/角色/会话/代。消息、队列、并发数量和等待有界；本地 socket backlog 已满时连接立即失败。
- GTK 首页显示真实 ID、认证/密码状态和 GPU 状态。服务器、认证、固定密码、Host/GPU 开关、入站审批/撤权/断开有后端命令路径。固定密码不回显，永久密码模式不展示不可用的临时密码。
- 原生 GUI 的远程连接入口仍禁用；Viewer、设备管理、完整共享策略、通知/SNI 和最终打包未完成。`--build-info` 仍报告 `runtime_ready=false`。

## 检查结果

| 检查 | 结果 | 原始记录 |
| --- | --- | --- |
| native core Release | 通过，包含真实 Host 入口 | `native-runtime-release.log` |
| GTK GUI Release | 通过 | `native-host-gui-release.log` |
| 旧 Flutter/GPU feature 组合 check | 通过，无默认 feature 回归 | `native-host-legacy-check.log` |
| 协议/监督/帧/transport 单测 | 14 通过；含 backlog 饱和及错误 UID 拒绝 | `native-host-ui-checks.log` |
| GUI 会话状态模型 | 2 通过 | 同上 |
| staging 保留未知修改 | 4 通过 | `native-runtime-stage-tests.log` |
| core pidfd 进程身份 | 1 通过 | `native-process-tests.log` |
| GPU 租约/失败清理 | 2 通过；1 个需要实际 GPU 的截图测试未运行 | `native-host-lease-tests.log` |
| canonical 重建与 hashes | 通过，生成 checkout 对应 Linux 下的 pin/patch/overlay | `native-runtime-canonical.json` |
| 配置 CLI smoke | 10 项通过；全新私有配置，含并发写入、旧 revision、密码状态、旧运行时迁移拒绝 | `native-config-smoke.log` |
| 真正 Host/GUI 组合 smoke | 9 项通过；CM ready、在线转发、身份拒绝、重复 agent 拒绝、GUI 关闭保留 Host、离线 helper | `native-host-smoke.log` |

单元测试合计 23 项通过，1 项需 GPU 的测试明确跳过。`native-runtime-check.log` 是本阶段较早的 check；最终 core 以较后的 Release 编译和运行 smoke 为准。测试覆盖范围不同，不能把 CLI 配置 smoke 等同于所有界面按钮的交互验收。

## 隔离运行方式

`Scripts/linux/test-native-host.sh` 使用固定 builder 镜像，4 CPU/12 GiB、无网络、不映射 GPU/宿主显示/服务 socket。容器 root 只在临时 `/opt` 中组装不可变测试 release，随后普通 UID 在私有 Xvfb/D-Bus 下启动 Host 和 GUI。没有安装到宿主 `/opt` 或 `/usr`。

两个在线 GUI 循环各截图三个分区，关闭后同一 Host 仍运行；随后终止**测试容器内的** Host，再启动 GUI 验证离线配置助手。`runtime/gui-*/page-*-state.json` 证明数据来自 agent/config，且未输出设备 ID 或密码。截图中的设备 ID 是容器内生成的合成测试身份，不是用户正在连接的 linux-host ID。GUI/Host maps 无 GTK3/GDK3、Flutter、Sciter、AppIndicator，GUI 无 CRITICAL。

## 内存尚未验收

最新隔离样本：首页 PSS 117,238 / 109,590 KiB（114.5 / 107.0 MiB），离线首页 110,255 KiB；关闭两次 GUI 后 Host PSS 58,498 KiB（57.1 MiB）。见 `memory-samples.json` 和原始 `/proc` 记录。这些不是同时采集的总预算，没有 root 服务、媒体连接或显卡；PSS 分摊也会随其他进程生命周期变化。不能与正在传输的安装版直接作 A/B。

首页仍超过 60 MiB 目标。此前的 Xvfb/LLVM 初始化成本调查继续有效，完整资源验收仍需实际硬件、固定场景及所有 FarPane 进程一起计数。

## 未验收及继续工作

- 实际 root supervisor、登录/UID/显示变化、长连接与故障恢复；审批/撤权、文件任务和语音拒绝的真实通信；本阶段没有入站媒体连接。
- 配置落盘失败、两份旧配置文件之间的崩溃恢复；现有配置 API 的成功返回不能替代持久化故障注入。
- 完整共享方向/类型、文件接收根目录与确认、后台策略、音频源、设备管理、通知/SNI、睡眠/网络恢复。
- Viewer-only 边界、隐式配置写入隔离、VAAPI/DRM_PRIME/EGL/fence、输入/IME、音频、剪贴板、文件、HUD、诊断及退出释放。
- 内存目标、发行版 ABI、干净依赖闭包、安装/升级/回退、最终 GUI 发布包。此证据目录和 Build 下二进制都不是用户测试交付包。

`source-state.json` 记录 canonical 源码与两个二进制的 SHA256；`SHA256SUMS` 校验本目录全部原始材料。
