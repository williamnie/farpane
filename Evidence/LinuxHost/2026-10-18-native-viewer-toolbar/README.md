# FarPane Linux GPU 媒体重构（linux-host）：会话工具条原始记录

2026-10-18。产品变更、测试范围和产物见 [会话工具条](../../../Linux/docs/viewer-toolbar.md)。

- `builds/run-so3dj_lw`：首版 GUI 的实际输入、固定 builder、九项单测/Release 日志与哈希；随后实际布局失败，未交付此版。
- `builds/run-af0ohuw5`：修正占位后的 GUI 构建，另含 Debian 包测试命令/完整 stdout/结果。
- `runs/run-ucyca_pe`：第一组真实连接，工具条不可见但高度仍为 85；exit 1、截图与几何记录保留。
- `runs/run-jukivcjt`：九项外部 GUI/真实连接检查通过，exit 0；收起后高度增加、刷新、键释放、坐标与失败恢复都有实际证据。
- `deb/`：Ubuntu 24.04 `.5 → .6` 六组实际 dpkg 检查和升级后两次软件连接；不是宿主或真实 systemd 切换。
- `candidate/`：本轮 bundle 与依赖材料 manifest、编译/复用来源。生成二进制和 deb 只保留在 Build。
- `canonical/`：本轮相关实现与打包/检查入口；运行测试的精确源码另随各 run 保存。
- `validation.json`：产物哈希、单测数量和边界；Python 单测及第一次目录权限失败的 stdout 只在工具记录中，未伪造原始日志文件。

现有服务未切换，内存优化与应用特判中文方案未恢复。新 GUI 还没有实机/GPU、分数缩放或完整发行版验收；完整源码 tar 与 `.6` RPM 暂未更新。所有本轮构建与容器检查均已结束。
