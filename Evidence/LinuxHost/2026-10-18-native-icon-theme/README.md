# FarPane Linux GPU 媒体重构（linux-host）：图标主题与概览刷新证据

2026-10-18。冻结 `.20261018.5` 包与私有 GNOME 50.1/VKMS，只有宿主 `/dev/kvm` 开放给独立 guest。结论与限制见[图标加载与概览刷新](../../../Linux/docs/native-icon-theme.md)。

- `lookup-before-later-windows/`：`disk.kgoombvw/run.f6h9ci2t`，运行会话 `2993` 退出 0。安装前独立主题及每次截图后新主题加载实验；不能排除诊断影响后续缓存。14 PNG、九次相等 RGB 比较、六个启动场景。
- `lookup-after-overview-cycle/`：`disk.88dsfh_m/run.pop6p4ka`，运行会话 `12050` 退出 0。移除提前初始化，首次 CLI 与同窗口概览重开截图均先于加载探针；PID 855 保持，品牌恢复。18 PNG、十二次相等 RGB 比较、六个启动场景。
- 各目录保留 `serial.log` 原始日志、解析出的主题/关联 JSON、PNG、运行结果、截图比较、磁盘输入记录及当时实际测试源码。46 份源码哈希已复核，生成磁盘/overlay 仅在 Build。
- `analyze-native-desktop-captures.py` 保存本轮分析器；它核对 PNG 哈希及实际像素，明确不把截图一致写成品牌验收。
- `guard-tests.log` 保存六项入口保护测试；`environment-after.json` 保存未变化的安装指针及无遗留测试容器。

这不是产品修改、真实宿主修复或完整 GUI 验收；没有构建应用、重打包、切换服务、GPU 或远程中文输入测试。未采用内存/字体优化。`SHA256SUMS` 覆盖本目录其他全部普通文件。
