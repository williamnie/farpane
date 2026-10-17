# FarPane Linux GPU 媒体重构（hermes）：双端并存证据

2026-10-17，`codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本轮使用既有 `.8` 包验证两个独立普通用户端点同时入站和出站的真实软件视频，不改应用、构建或安装版本。方法与九项结果见[检查说明](../../../Linux/docs/host-viewer-coexistence.md)。

- `runtime/20261017T083137Z/`：成功轮，九项检查、阶段进程身份、新画面截图、GUI/Host/Viewer 日志及实际程序哈希。
- `runtime/20261017T082703Z/`：首次夹具清理发生 Xlib I/O 退出，原日志保留；不计通过。
- `runtime/20261017T082816Z/`：配置命令拒绝入站断开，保留 traceback；后改用 GUI，没有修改权限。
- `runtime/20261017T082934Z/`：私有对话框坐标校准因输出目录属主未能写入，等待超时；不计通过。
- `logs/`：四次启动入口的原始输出；`canonical/`：最终测试、共享驱动与文档快照。早期失败轮源文件未逐次快照，不将最终代码冒充其原始版本。
- `native-build.json`、`bundle-build.json`、`deliverables.json`：既有候选来源与交付文件哈希，未重新构建。
- `host-state.json`、`containers.json`、`final-check.json`：服务/当前版本/FFmpeg 未变化、已无本轮容器、静态和证据检查；`SHA256SUMS` 覆盖本目录全部其他文件。

运行限定断网、4 CPU/12 GiB、两个私有 UID、四个 Xvfb。无宿主 GPU、桌面、配置或服务挂载；原有 RustDesk、FarPane 和服务器容器保持原状。GUI 真实按钮用于入站断开，鉴权配置接口用于 Host 开关。帧变化和 PID/start ticks 校验共同确认现有连接存活。

前两轮生成的四个日志原为 root 0600，归档前仅在隔离容器对这四个合成测试文件改为 0644，内容不变。成功轮已正确使用工作区属主。所有诊断和文档为后续增量，没有写入冻结的 `.8` 源码归档；其完整归档哈希继续核实不变。

本轮无产品修复，不代表 GPU 双向性能、真实系统监管、桌面切换、Mac 或完整 GUI 验收。候选仍未安装，真实维护窗口与首页 60 MiB 目标尚未通过。
