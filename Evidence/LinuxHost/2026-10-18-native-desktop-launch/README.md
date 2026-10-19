# FarPane Linux GPU 媒体重构（linux-host）：GNOME 桌面入口证据

2026-10-18。使用冻结 `.20261018.3`，补齐真实私有 GNOME 概览搜索、品牌图标、回车启动及首页屏幕观察，并追踪先前短命 `gio launch` 的失败。没有改动应用、重新构建包或切换 linux-host。中文输入方案仍暂停。

## 结果与含义

| 证据目录 | 磁盘 / 运行 | 实际结果 |
| --- | --- | --- |
| `observed-1/` | `disk.jmotezfd` / `run.7xzmuu96` | 菜单与持续处理事件的 GIO 启动成功；冷 CLI 的 GUI 约 10.112 秒退出 |
| `traced-2/` | `disk.xs0xblij` / `run.kbajf23f` | 同样成功；冷 CLI 约 10.098 秒退出；已存在 GUI 时的 CLI 复用同一进程 |

两个运行均已退出 0、guest 正常关机。每组总共观察 16 秒（包含启动调用），通过精确 PID/UID/start ticks 与总线 owner 确认 GUI。整个比较中 root/Host 的代际不变。成功范围是实际 GNOME 搜索和菜单显示首页；CLI 冷启动失败在 `summary.json` 中单列，不能因外层 `result=pass` 被计为通过。

已查看两轮的 `launch-search.png`、`launch-menu.png` 和第一轮的 `launch-cli.png`：搜索结果为 FarPane 独立图标；菜单成功后显示品牌首页、设备 ID 输入与共享控件；CLI 冷启动后屏幕仍在 GNOME 概览，没有 FarPane 窗口。图中 ID 属于离线合成 guest，非 linux-host 的实际身份。所有 11 张 PNG 的 SHA 与 guest 原始结果逐项一致。

两轮 `launch-gio.png` 也已查看：首页在 GNOME 概览的窗口缩略图中可见，概览没有关闭。因此该路径只确认窗口创建和存活，没有宣称拿到键盘焦点；菜单回车后的截图则已离开概览、正常呈现主窗口。

第二轮加私有激活环境 `G_DBUS_DEBUG=message`，程序/桌面入口原字节未变。GUI 接收侧 Activate 数量为：冷 CLI 0、GIO 1、已有 GUI 的累计日志 2、菜单 1。累计 2 包含前一组 GIO 与后一组 CLI 各一次。总线监视器看见冷 CLI 的发送，但 GUI 没有收到该调用；因此现有证据定位到激活请求交付，不支持把它描述为首页显示后崩溃。发送端过早结束导致待交付请求丢弃仍是推断，D-Bus daemon 内部队列没有追踪。未修改产品来绕过此现象，CLI 冷启动路径保持未通过。

## 保存的材料

- 两轮各自的 `serial.log`、`result.json`、`command.json`、`qemu.log`，保留完整外层与 guest 结果。
- `journal.log`、核心服务/Host 日志、`desktop-launch-bus.log` 和每组观察时间线从 serial 的 JSON 逐字解出；第二轮另有 4 份 GUI PID 的完整 D-Bus 收发日志。
- 直接来自 guest VKMS scanout 的 PNG，原始 base64 同时保留在 serial；没有修改截图。
- 两轮 `disk.json`、`prepare.log`、`source/`、`source-manifest.json`。guest 测试源码逐项匹配磁盘记录的 SHA；第二轮源码快照在运行结束后从未改变的 canonical 文件复制并核对。外层入口、固定镜像 pin、systemd/PAM 模板和入口保护也保存快照。
- 外层准备/运行日志与两份保护日志。13 项保护全部通过，非专用 guest 在键盘、采集库和命令操作前拒绝。
- `summary.json` 区分菜单通过与冷 CLI 失败，并保存各组 PID、截图和收到的 Activate 数。
- `SHA256SUMS` 覆盖本目录文件；不归档 8 GiB 根磁盘或 qcow2 overlay。

第二轮 trace 最长约 45 KiB，低于 200,000 字节导出边界；没有因原来的 30,000 字符日志尾部限制而丢掉早期 Activate。GUI 已存在时的日志按整个 PID 生命周期累计，分析已据此扣除前一组请求。

## 范围

固定 Ubuntu 26.04 用户态、GNOME 50.1、公开内核 7.0.0-38 与 guest VKMS，软件渲染；每轮独立内核/boot ID、无网卡，唯一宿主设备 `/dev/kvm`。仅 guest 内创建测试键盘，输入 ASCII 搜索词，不执行中文修复路径。CPU 4 核、guest 6 GiB、容器 10 GiB；未接触宿主屏幕、输入设备、物理 GPU、服务、ID 或配置。

本轮不覆盖线上认证/远程连接、实际 linux-host 菜单、KDE、任务栏与 Alt-Tab、缩放、通知、锁屏/多用户、内存预算或中文缺陷。完整目标继续进行，程序仍为开发候选。复现与具体边界见[桌面启动检查](../../../Linux/docs/native-desktop-launch.md)。
