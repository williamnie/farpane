# FarPane Linux GPU 媒体重构（linux-host）：GUI 自身总线故障

2026-10-18。原始冻结 `.20261018.3` GUI/core，双用户、私有 Xvfb 与回环软件视频。未构建/安装产品，暂停中的 Warp 特判不在本候选中。

`exploratory` 的 11 项结果只证明 GUI 收到 SIGTERM、Viewer executable 消失及另一方向继续出图；不能由此证明僵尸进程已回收。`verified` 增加 Docker init 并核对整个 `/proc/<Viewer>` 消失，12 项检查通过，命令退出 0。

GUI 自身没有在总线中断后保持运行：它返回 -15，自己的出站连接结束。独立 Host 的同一入站会话和对端 Viewer 保留，真实新画面继续；同一路径新 bus ID 下重开 GUI，接入原 Host，无旧出站自动复活。正常关闭后的两个 Host、身份与策略保留。

`source` 是最终验证使用的 canonical 测试源码。两个结果目录各有原始阶段记录、二进制哈希、日志与私有截图；不把新源码快照冒充首轮源码。没有 GPU/root supervisor、用户桌面、输入法、音频/文件并发或内存验收。

方法与命令见[总线故障合同](../../../Linux/docs/desktop-bus-recovery.md#gui-自身总线中断的退出与恢复)。本轮不提交、推送或切换服务。
