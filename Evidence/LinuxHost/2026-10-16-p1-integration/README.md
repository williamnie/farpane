# FarPane Linux GPU 媒体重构（linux-host）：P1 隔离验证与安装证据

日期：2026-10-16 UTC。用户已允许先集成、build/安装，真实连接由其验收。

当前安装：`/opt/farpane/farpane`，artifact `farpane-p1-e9bb38076782-90876510-551585f0`。
GPU 已编译，默认关闭；独立 `farpane.service` 单元仅放置，未启动/enable/daemon-reload。
现有 RustDesk、宿主桌面/显示模式、配置/ID/密钥、主机 FFmpeg 均未操作。

- [实现与验收范围](implementation-and-acceptance.md)
- [最终产品适配器实测](logs/gpu-adapter-run-02.log)：XR24/AR24 各36帧，12 FPS、256×128，色块误差1，源覆盖/截图/PTS/IDR/失败销毁与FD回收通过。
- [核心测试原始结果](logs/gpu-tests-01.log)：49 scrap；414 root通过、4 ignored、1无显示光标失败；[Xvfb 补测](logs/gpu-cursor-xvfb-01.log)通过。
- [新状态测试](logs/gpu-state-test-01.log)：普通重建保留失败，明确重试/显示变化恢复，新旧代隔离。
- [feature-off 与最终 Release](logs/gpu-off-and-release-01.log)：66原DRM测试通过、1人工调查忽略，最终GPU核心构建成功。
- [Flutter 132项](logs/gpu-flutter-tests-01.log)、[settings 静态分析](logs/gpu-settings-analyze-01.log)、[6项准备/安装测试](logs/gpu-python-tests-final.log)。
- [最终实际 GUI](gui/settings-gpu.png)：仅容器内 Xvfb、无宿主显示/GPU/网络/服务挂载；默认关闭，未运行后台时提示正确。
- [干净加载](logs/gpu-clean-load-01.log)、[14个bundle ELF](logs/gpu-host-link-audit-final.json)、[最终源码一致性](logs/gpu-source-parity-final.json)、[prepare重入](logs/gpu-prepare-final.log)。
- [系统安装](logs/gpu-system-install-final.json)、[用户菜单/旧版本保留](logs/gpu-user-install-final.json)、[安装后核对](logs/gpu-installed-audit-final.json)。
- [旧两轮140条校验](logs/gpu-old-evidence-integrity.json)、[canonical文件清单](canonical-files.json)、[依赖锁](dependencies.lock.json)、[已安装artifact完整清单](installed-artifact-manifest.json)。

日志保留未成功尝试，包括后续补丁导致旧patch上下文检查失败、早期未完整应用接点的编译错误和无显示测试失败；它们没有被覆盖成成功结果。

这不是 scanout/真实连接验收，也不证明产品 CPU 降幅、Mac 颜色、端到端延迟或长稳。
下一阶段由用户在维护窗口启动 FarPane 并测试；[当前入口与启动步骤](../../../Linux/docs/application-status.md)。
