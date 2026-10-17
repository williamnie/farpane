# FarPane Linux GUI 重构规划内存采样

2026-10-16 15:22:29（Asia/Shanghai），使用现有 [sample-runtime.py](../../../Scripts/linux/sample-runtime.py) 只读采样约 5 秒。仅统计 `/opt/farpane/releases/` 下 FarPane 的进程，不控制进程、不读取截图或密码，不访问原 RustDesk 配置。

```sh
sudo -n python3 -B Scripts/linux/sample-runtime.py --seconds 5
```

`runtime-sample.json` 为原始输出；`SHA256SUMS` 记录其校验和。五个 PID 稳定，所有状态样本均有一条视频连接，后端为 GPU、generation=3。总 PSS 337,934 KiB（330.0 MiB），主窗口与连接管理窗口合计 209,396 KiB（204.5 MiB）。

这份短样本用于 [GUI 重构方案](../../../Linux/docs/gui-rewrite-plan.md) 的预算分析。它不是受控性能 A/B，不完整统计 GPU 内存，也不能证明重写后的节省量；CPU 数值仅为采样同期状态。未来正式对照需固定画面、帧率、编码与功能开关，并采集多轮及长期趋势。
