# FarPane Linux GPU 媒体重构（linux-host）：分配器与驻留诊断

延续[二十轮生命周期检查](../2026-10-17-native-lifecycle/README.md)，此轮给测试观察库补充 glibc `malloc_info` 原始 XML，核对每个内存区和总计，区分 PSS 驻留变化与分配器报告的空间变化。`.5` GUI/core、默认 allocator、已安装服务和全部旧候选保持不变。

成功运行：`Build/Linux/native-lifecycle-smoke/20261017T063156Z`，2 轮预热 + 20 轮测量，约 173.73 秒。同一私有普通用户 GUI/Host，640×480 Host、1020×720 GTK Cairo GUI，外部 XTest 操作实际连接/密码/断开/关窗口。22 个 Viewer、软件帧映射全部回收，GUI/Host FD 固定 13/40（GUI 多一个诊断 socket）；窗口关闭后 Host 保留。

| 预热后至末轮 | 结果 |
| --- | --- |
| GUI PSS 最大 / 最终增量 | 1,648 / 1,636 KiB |
| 最后十个采样间 GUI PSS 增长 | 400 KiB |
| allocator 内存区个数 | 59，保持不变 |
| allocator system 总空间增量 | 4,096 字节 |
| 报告的非空闲区 + mmap 净 / 最大增量 | 44,957 / 48,701 字节 |
| mmap 总量变化 | 0，始终 1,527,872 字节 |
| 观察到的 GObject 存活数 | 2,681 → 2,677，无类型净增长/计数溢出 |

报告的非空闲区按 system 减去 free bin 总量计算，可能包含线程缓存、分配器管理开销等，不能当成精确活分配。这里没有从有限样本断言“无泄漏”或将余量全部归因缓存。结论仅为：此轮大部分驻留增量没有对应同等规模的新 allocator 总空间或非空闲字节增长。保留 `persistent_growth_ruled_out=false`、`product_memory_budget_accepted=false` 和完整计划验收 false。

首次尝试 `20261017T062936Z` 在 GUI 初始首页解析 XML 时失败，尚未进入第一轮连接。glibc 2.43 的 XML 省略了 fast 项，旧解析器假定存在。原 XML 与 traceback 保存在 `failure/`；修正为允许 fast 缺失后，其他字段/类型及逐区和总计继续严格检查，23 份实际报告全部解析并校验通过。失败和后续成功是两个不同输出目录，未覆盖原记录。

`canonical/` 保存结束时的 C 观察库、Python 驱动/分析和文档。观察库在原隔离 builder 内用 `-Wall -Wextra -Werror` 编译，不安装任何主机库，不编译 FFmpeg/core/GUI。仅使用 `malloc_info`，没有调用 `mallopt`、设置 tunables 或主动 trim。公共 GObject 构造器仍使用弱通知，不额外持有对象；诊断开销不进入产品性能结论。

`runtime/` 保存完整 XML/逐区 JSON/对象 JSON、每轮资源数据、基线/末轮完整 smaps 和日志。其余 raw smaps、私有截图和观察共享库保留在 Build，大小/哈希见 `retained-in-build.json`。`allocator-analysis.json`、CSV 和图均来自同一成功运行，未与未加观察库的上一轮混合。

每次运行实际程序哈希与 `.5` 相符：GUI `482a3d8d69a31199de48b2d4a368c21101d79a1bb902404223282990f6221cc0`，core `4e0ac6b78fcc2e630aa52fe2485dc727bd1a5f45c3597e8b3daf970264cf3ced`。最终核对包括旧产品 receipt、独立源码构建、四份产品 FFmpeg 库、`.5` 三项交付、source8295，以及两个宿主服务的 PID/状态/当前 release；结果见 `final-check.json`。

未改变产品行为、打包新候选、安装、启停服务、操作桌面、commit/push/deploy 或联系其他代理。维护窗口确认仍待回复；真实桌面/GPU/长稳与首页 60 MiB 门槛仍未通过。新的诊断入口不在此前冻结的 source8295 中；旧归档不重写。

复现与统计范围见 [viewer-lifecycle.md](../../../Linux/docs/viewer-lifecycle.md#分配器明细与驻留增量)。`SHA256SUMS` 是本地证据索引，不是发布者签名。
