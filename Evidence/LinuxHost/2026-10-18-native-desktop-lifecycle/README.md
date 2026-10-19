# FarPane Linux GPU 媒体重构（linux-host）：GNOME 生命周期原始证据

2026-10-18。冻结 `.20261018.3` 的原生首页在实际 GNOME/Wayland 私有 VM 中通过 7 项窗口生命周期检查。首次搜索前显式等待 7 秒的第 6 组通过；第 1–5 组的初次查询失败和总体 fail 全部保留。不以诊断重搜通过覆盖初始失败。

实现、原理、边界和复现命令见[窗口生命周期](../../../Linux/docs/native-desktop-lifecycle.md)。`summary.json` 是从原始结果提取的汇总；`withdrawal-check.json` 记录被撤下的安装器尝试与包哈希。既有冻结包/应用源码、已安装 `.1`、宿主服务与桌面均未改。

| 目录 | 原磁盘 / 运行 | 实际操作与结果 |
| --- | --- | --- |
| `failed-1` | `disk.l516wia9` / `run.plpoo8tx` | 原 `.3` 首次搜索失败，无截图，未运行后续检查 |
| `failed-2` | `disk.f_5f6qzl` / `run.g764hygq` | 同样失败；截图确认 No results |
| `diagnostic-3` | `disk.st0qfkve` / `run.41tcnqvn` | 失败后刷新数据库并重搜，后续 7 项通过；因混入时间和新查询，不能归因为刷新 |
| `rejected-candidate-4` | `disk.gjrbxwae` / `run.uzizapma` | 实验 `.4` 在 bind 时刷新成功仍首搜失败；该包不采用 |
| `control-5` | `disk.lj7cc53o` / `run.4eo6blio` | 原 `.3`，失败后不刷新、不改桌面文件，重搜即成功，7 项通过；总体 fail |
| `settled-6` | `disk._nzag9jf` / `run.aocl2z_t` | 原 `.3`，首搜前显式等待 7 秒，未预先启动 GUI或刷新；首次搜索与 7 项检查全部通过 |

全部运行已终态。第 5 组会话 `61126` 退出 1，第 6 组 `4162` 退出 0；第 6 组 guest 正常关机，测试容器删除，没有待续句柄。16 项入口保护见 `desktop-lifecycle-guards-2.log`。早期 `desktop-lifecycle-guards-1.log` 为 15 项。

每组包含 `serial.log`、`result.json`、`command.json`、`disk.json`、guest 日志、实际测试源码及清单。截图来自 guest VKMS mapped frame，未采集宿主。完整 Wayland 追踪最多 1 MiB/文件，PNG 最多 1 MiB/张，哈希逐项核对。成功组初次首页与重复打开 PNG 相同，切回与重开 PNG 相同；两组顶栏时钟不同，不是四张全部相同。第 5、6 组的初始搜索与切换器、关闭后画面已查看，第 6 组初次与重开首页也已查看。共核对 138 条源码清单记录及其 guest 模块 SHA；旧清单以 source 为根，新清单使用明确 source 前缀，两种路径均按各自版本解释，未修改旧清单。

`rejected-candidate-4/attempted-installer-source/` 保存被撤下的实现、包装配方、README 和缓存单测。实验 Deb 位于 `Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.4_amd64.deb`，SHA-256 `e1bbdc32012603ed3af8805537ac15da24f6ab97977a1c559f541aa98cdb5dcf`；包内 GUI/core/媒体与 `.3` 一致，只尝试修改安装器及依赖。该包从未在宿主安装、暂存或激活，不能作为修复版供测试。缓存单测与原安装器回归通过只证明其局部逻辑，不能推翻真实 GNOME 的失败结果。撤下后六份源码与原版本逐字节一致。

`desktop-lifecycle-host-activity.json` 是宿主只读观察：原 `.1` Host PID 70886，入站 1、pending 0、file_jobs 1、media_owners 2，idle=false。这里 file_jobs 包括 CM owner，不能直接解读为正在传文件。未进行硬件 GPU 测试。

没有真实远程会话/中文/内存预算验收；GNOME 搜索延迟与冷 `gio launch` 失败仍开放。未采用的缓存刷新、原来的应用特判输入草稿、其他用户改动均有明确处置边界，未回滚别人的工作。原始磁盘与 overlay 留在 Build，不复制到证据目录。
