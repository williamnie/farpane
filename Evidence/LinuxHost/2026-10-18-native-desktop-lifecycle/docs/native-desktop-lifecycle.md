# FarPane Linux GPU 媒体重构（linux-host）：GNOME 窗口生命周期

2026-10-18。冻结 `.20261018.3` 在真实 GNOME 50.1/Wayland 私有 VM 中完成菜单打开、单实例、Alt-Tab、关闭和重开检查。最后一组在首次搜索前明确等待 7 秒，7 项检查通过；这个等待只用于区分桌面应用索引的更新时序，没有加入产品或安装器。原始“安装后立即搜索无结果”仍保留为失败，不能称为已修复。

## 安装器尝试已撤下

早期首次搜索显示 No results，随后执行 `update-desktop-database` 再搜索成功。这个实验同时改变了缓存、时间和查询，不能证明缓存刷新有效。进一步对照如下：

| 组 | 包与操作 | 首次搜索 | 后续生命周期 | 原始总体结果 |
| --- | --- | --- | --- | --- |
| 1、2 | 原 `.3`，立即搜索 | 失败；第二组留有截图 | 未进入 | fail |
| 3 | 原 `.3`，失败后手动刷新并重搜 | 失败 | 7 项通过 | fail |
| 4 | 实验 `.4`，bind 内刷新返回 0，失败后另行刷新并重搜 | 仍失败 | 7 项通过 | fail |
| 5 | 原 `.3`，失败后只重新搜索，不刷新或改桌面文件 | 失败，重搜成功 | 7 项通过 | fail |
| 6 | 原 `.3`，首次搜索前等待 7 秒，不刷新、不预先启动 GUI | 成功，图标可见 | 7 项通过 | pass，仅此配置 |

GNOME 50.1 上游的 [ShellAppCache](https://raw.githubusercontent.com/GNOME/gnome-shell/50.1/src/shell-app-cache.c) 使用延后 5 秒的索引更新；[应用系统](https://raw.githubusercontent.com/GNOME/gnome-shell/50.1/src/shell-app-system.c)查找依赖该缓存。源码与第 5、6 组共同支持“首次查询早于索引就绪”的解释；没有测量本发行版每次内部缓存更新的时刻，7 秒也不是面向所有桌面的就绪保证。

实验 `.4` 没有修复原现象，已否决。其 Deb、安装器源码、失败日志和单测保留为证据，不能作为可安装的新候选。新增缓存辅助调用、JSON 字段、Deb/RPM 依赖及专用单测已从当前实现撤下；原安装器恢复原字节。没有将等待、重试或刷新加入产品。当前候选仍为 `.3`，linux-host 保持 `.1`。`withdrawal-check.json` 核对了六份安装/包装文件与原版本，以及 `.1`、`.3`、被否决 `.4` 的包哈希。

## 窗口检查的实际范围

成功组 `disk._nzag9jf/run.aocl2z_t` 的外层会话 `4162` 已退出 0，guest 正常关机。root PID 752/start 2694、Host PID 783/start 2915 在所有操作前后保持相同；用户身份、认证方式和固定密码设置状态也保持一致。没有真实远程会话，因此不能将这些检查扩大为“连接不中断”的新证据。

1. 用 guest 键盘进入 GNOME 概览搜索并回车，真实打开一个原生 GUI，确认总线 owner 属于同一 PID。
2. 再次通过菜单打开两次，仍为同一 GUI PID/start ticks。
3. 直接执行应用入口，同一 GUI 保留；完整 Wayland 客户端追踪只创建一个 `xdg_toplevel`，标题为 FarPane、app_id 为 `org.farpane.FarPane`。
4. 新建独立参考窗口，通过实际 Alt-Tab 在两个应用之间切换；参考窗口的焦点状态、屏幕截图与后续关闭目标相互核对。切换器显示一个 FarPane 品牌图标。
5. Alt-F4 关闭 FarPane：toplevel 被销毁、整个 `/proc/<gui>` 消失、应用总线 owner 释放，root/Host 保留。两次关闭各约 0.131 秒，计时包括发送按键和就绪检查，不是纯渲染延迟。
6. 菜单重开得到新 GUI PID 1212，原 GUI PID 1071 已完全消失，接入原 Host 和原身份。
7. 对重开后的实例再次菜单激活并关闭，同样保持单实例和完整退出。

成功组的首次搜索、首页、切换器、关闭后屏幕及重开首页已实际查看。初次首页与重复打开 PNG 相同，切回与重开 PNG 相同；两组之间 GNOME 顶栏时钟已变，不能称为全部逐字节相同。软件桌面离线显示“等待服务器”，不作为网络注册验收。`WAYLAND_DEBUG=client` 只写入该私有会话的 D-Bus 激活环境，结束时清除；应用与 desktop 文件字节未变。此组不测内存预算。

## 复现

```sh
python3 -B Scripts/linux/prepare-native-input-vm.py \
  Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5 \
  --stage desktop --maintenance-debs \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.1_amd64.deb' \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.3_amd64.deb' \
  --desktop-lifecycle-probe --desktop-index-settle-seconds 7
python3 -B Scripts/linux/run-native-input-vm.py PREPARED_DISK_DIRECTORY
```

省略 `--desktop-index-settle-seconds` 时默认为 0，保留立即搜索对照；首次搜索超时后的诊断重搜即使通过全部窗口检查，总体结果仍为 fail。不得改写之前的失败结果。`--desktop-launch-probe` 与本 profile 互斥，索引等待选项只能用于本 profile，且仅允许 0 或 7 秒。

测试核对独立内核、明确 maintenance/lifecycle 标记和唯一 guest VKMS card0，再访问键盘、截屏、总线或进程。只开放宿主 `/dev/kvm`，无网卡、宿主桌面/输入/GPU/用户总线或共享 home。4 vCPU、6 GiB guest，复用固定镜像/内核与原包，不重编 GUI/core/FFmpeg。16 项入口保护通过。

每组实际 guest 源码快照均对照磁盘元数据 SHA；原始 serial、命令、result、Wayland 日志、PNG 与未采用的安装器改动在[完整证据](../../Evidence/LinuxHost/2026-10-18-native-desktop-lifecycle/README.md)。现有独立源码归档与包不被测试文件更新重写。

## 仍未验收

立即安装即可搜索、冷 `gio launch`、实际 linux-host/KDE、Viewer 与多个窗口的任务栏分组、缩放、通知焦点、锁屏/休眠、多用户、真实网络/硬件 GPU、首页与组合内存预算仍未因此通过。按应用特判的中文输入方案继续暂停；本项没有中文输入测试。开发包已具备 GUI 与后端，但完整 GUI 交付和发布门槛尚未完成。
