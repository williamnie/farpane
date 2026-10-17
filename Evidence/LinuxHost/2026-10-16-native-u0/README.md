# 原生 GUI U0 第一阶段证据

这份归档证明依赖拆分、协议/状态决策测试和隔离 GUI 渲染原型的进展，**不证明完整 GUI、Host/Viewer 集成或内存目标验收通过**。状态与下一步见 [gui-status.md](../../../Linux/docs/gui-status.md)。

- `native-core-check-02.log`、`native-core-release-02.log`：无 legacy UI feature 的核心编译通过。核心仅开放构建信息入口，其余运行角色暂时明确拒绝。
- `native-core-dependency-tree.txt`：native 普通依赖树不含 GTK3、Sciter、旧托盘、winit/softbuffer。不能以当前构建信息入口的 ELF 闭包代替完整运行核心的加载检查。
- `native-legacy-check-01.log`：既有 Flutter/GPU feature 组合仍能编译。
- `native-tests-final-01.log`：13 项协议/帧/监管决策测试与 2 项 GUI 会话状态测试通过；`native-prepare-tests-01.log` 有 4 项 staging 保留未知修改/拒绝路径越界测试。
- `native-source-parity-02.json`：pin + canonical patch/overlay 重建校验通过。
- `native-gui-release-02.log`：三个页面在独立 Xvfb/D-Bus 中渲染并截图；maps 无 GTK3、Sciter、Flutter。构建字体环境曾缺失中文，现已补齐且人工查看截图。
- `smoke/standard` 是 Cairo renderer、GDK 正常初始化；`smoke/no-graphics` 额外禁用 GDK GL/Vulkan，仅用于分离开销，不可作为 Viewer 运行方案。
- `native-memory-analysis.json` 保留原始 PSS 与主要映射归因。首页分别约 119.2/54.8 MiB；60 MiB 目标尚未通过正常图形路径。后续页样本可能含截图导出后的分配器保留。
- `manifest.json` 记录最终已构建开发二进制与锁文件哈希。截图/内存样本来自等价代码格式化前构建；格式化后 Release 再编通过，未把截图当成完整业务验收。

测试没有网络、GPU 节点、宿主显示、原服务 socket 或用户配置挂载；所有测试容器已退出。没有安装、替换或启停在线 FarPane/RustDesk，没有 commit/push。已有 FFmpeg 9.0.2 缓存原样复用。
