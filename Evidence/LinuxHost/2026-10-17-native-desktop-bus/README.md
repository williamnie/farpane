# FarPane Linux GPU 媒体重构（linux-host）：Host 用户总线重建证据

2026-10-17，`codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。使用 `.9` bundle 原始 GUI/core，在无外部网络、无 GPU、无宿主显示/服务挂载的容器运行，十项检查通过。方案、结果与边界见[专项说明](../../../Linux/docs/desktop-bus-recovery.md)。

原始运行 `20261017T093347Z`，工具 handle 83019，退出 0。四个私有总线实例具有不同 bus ID；同一个 Host 恢复桌面注册与通知，实际 GTK 允许按钮批准并出画面，已授权连接在总线断开时继续呈现新帧；未批准请求在约 30.112 秒后拒绝且没有画面。测试控制 GUI 与 Viewer 的总线没有重启，不把它们当作 GUI 自身总线恢复通过。

- `runtime/`：原始输出、进程哈希、能力/请求状态、提供者记录、实际 GTK 截图和会话结果。
- `canonical/`：本轮测试入口、夹具和对应文档副本。
- `run.log`：实际执行输出。
- `final-check.json`：测试原始数据与 `.9` 程序的绑定核对、文档/语法检查。
- `host-state.json`、`deliverables-unchanged.json`：现有服务、FFmpeg、容器和候选文件未变化的检查。
- `SHA256SUMS`：其余证据文件校验和。

没有产品修改、编译、打包、宿主安装或服务切换；旧产物和所有未提交工作保留。真实桌面/GPU/Mac 互操作、性能、长稳、维护切换与完整发布审计仍未验收。新增测试尚不在冻结 `.9` 源码归档中，后续实际打包再纳入。
