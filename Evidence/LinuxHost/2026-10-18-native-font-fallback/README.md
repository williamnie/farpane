# FarPane Linux GPU 媒体重构（linux-host）：动态字体原始证据

2026-10-18。冻结 `.20261018.5`，私有无 GPU 软件桌面。测试和结论范围见[动态字体实验收尾](../../../Linux/docs/home-font-fallback.md)。用户接受当前内存水平，进一步内存优化暂停，未采用产品字体改动。

- `observer-compile-failure/`：`run-_8501rx1`，诊断库弃用警告导致退出 1。
- `exploratory-home-only-warmup/`：`run-nguv3e9t`，退出 0，但动态路径未完整预热；`analysis-rejection.json` 确认新分析器拒绝将其作为正式结果。
- `full-path-warmup/`：`run-crzugzjg`，退出 0，完整动态路径预热后 A/B/B/A；`analysis.json` 是正式汇总。
- 每个运行均保存当时的 `inputs.json`、源码、退出码、原始日志和已有采样/截图；失败原样保留。39 份实际源码哈希核对通过。
- `analyze-native-home-fonts.py` 为本轮分析器；`validation.json` 保存验证范围；`environment-after.json` 保存安装指针和无遗留测试容器的只读检查。

生成的 `font-widgets.so` 不入证据目录，留在 Build；各成功运行 `run/test-binaries.json` 保存其哈希。GUI/core、字体输入与固定镜像均复用此前产物。实验观察库会占用少量内存，本轮 PSS 不作为普通产品预算。未使用用户桌面、硬件 GPU、实际远程中文输入或替换服务。没有新候选、提交或推送。

`SHA256SUMS` 覆盖本目录其他全部普通文件；后续复查不要覆盖这些原始记录。
