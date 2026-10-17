# FarPane Linux GPU 媒体重构（linux-host）：开发暂停交接

2026-10-17（北京时间）。用户要求先提交、推送全部代码，再暂停任务，稍后继续。本记录随暂停提交保存；后续以 `codex/linux-host-gpu-media` 分支的实际提交和远端状态为准。暂停期间不继续开发、构建、测试、部署或发布，保留已安装 FarPane 运行。

## 已完成的当前状态

- GTK4/libadwaita 原生 GUI、独立 Host/Viewer、配置与身份、设备、输入/剪贴板/音频/文件、生命周期和打包入口均已有实现及分项隔离证据。
- linux-host 已在用户授权维护窗口切换到原生应用 `farpane-native-dev-e7508f297ef1d671172d7737`；旧 P1 release 保留。用户确认 Mac mini 入站画面与键鼠正常；实机后端为 GPU，编码引擎计数持续增长。
- 最新 `.11` Debian 候选携带最终安装器权限迁移修复，应用 payload 与 `.9` 相同；无需再次切换当前服务。10 项权限单测、25 项安装事务及真实包入口检查通过。
- 30 秒真实连接样本：全进程 CPU 合计约单核 7.43%、PSS 约 235 MiB，GUI 约 131 MiB。关闭 GUI 后同一连接保留，后台约 104 MiB。首页 60 MiB 目标尚未达到。
- RustDesk 由用户手动停止并禁用，本任务保持该状态。FarPane 的开机启用策略也保留此前关闭状态。

详细改动、包哈希、实机数据与边界见[维护记录](native-hermes-maintenance.md)、[当前候选](native-test-candidate.md)和[开发状态](gui-status.md)。原始记录位于 `Evidence/LinuxHost/`；应用、安装器、补丁和依赖 pin 以 `Linux/` 与 `Scripts/linux/` 为 canonical。

## 恢复时的入口

1. 先核对当前分支、工作区、已安装 release 和用户提供的新反馈；当前记录不保证暂停后的服务/PID仍相同。
2. 优先处理真实 GUI 的内存目标；实测与旧版配对性能尚未完成，不能将短时 GPU 连接样本当作性能验收。
3. 继续 Linux Viewer 到 Mac、真实音频/中文/富剪贴板/文件互操作、桌面交互、长稳与故障矩阵。真实回退、多用户、锁屏/休眠/重启和显示变化另按用户当时授权的测试范围执行。
4. 完整许可/来源审计、公开 CI/Release 和跨发行版验收尚未关闭。当前候选保持 `runtime_ready=false`，本次推送不等于公开发布。

宿主私有配置备份与生成产物仅在忽略的 `Build/Linux/` 中，不进入 Git。恢复时不要复制或公开私有备份，不要重建已经通过的 FFmpeg，不要唤醒旧开发线程，也不要仅为恢复进度而重跑既有大矩阵。
