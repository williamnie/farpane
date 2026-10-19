# FarPane Linux GPU 媒体重构（linux-host）：GNOME 菜单启动检查

2026-10-18。冻结 `.20261018.3` 在私有 GNOME 50.1/Wayland 虚拟机中，两轮均能通过概览搜索 `farpane` 找到独立图标，按回车后显示原生首页。本轮补齐[维护 VM](native-maintenance-vm.md)此前只有 D-Bus 确认、缺少真实菜单与屏幕观察的部分。应用、Debian 包和 linux-host 当前安装均未改变，中文输入方案仍暂停。

## 实际启动对照

每组从启动命令或菜单操作开始观察 16 秒，核对精确 release 的 GUI PID、UID、start ticks 和用户总线 owner；最后直接读取 guest VKMS scanout 截图。两轮原始 PNG 均已查看，GNOME 搜索结果显示 FarPane 品牌图标，菜单启动后的首页包含设备连接和本机共享控件。离线 guest 显示“等待服务器”符合测试环境，不构成线上注册或真实连接验收。

| 入口 | 第一轮 | 第二轮 | 范围 |
| --- | --- | --- | --- |
| 冷启动 `gio launch desktop` | 命令退出 0，GUI 约 10.112 秒消失，没有首页 | 约 10.098 秒消失，没有首页 | 失败现象保留，未宣称修复 |
| GIO DesktopAppInfo，保持事件处理 2 秒 | 首页在概览缩略图中出现，观察期末 GUI 存活 | 同样通过 | 用于比较启动调用者生命周期，不证明获得键盘焦点 |
| GUI 已存在时执行 `gio launch` | 未测 | 同一 GUI PID/start ticks 保留，收到新 Activate | 只覆盖已运行实例 |
| GNOME 概览搜索、回车 | 首页出现，观察期末 GUI 存活 | 同样通过 | 实际菜单路径，没有替换为直接总线调用 |

每轮四类/三类启动之间仅结束本轮创建的 GUI，使用确切 executable/UID/start ticks 加 pidfd。真实 root 服务与 Host 的整个进程代际在各组间保持相同。测试结束后 guest 正常关机，外层命令退出 0，测试容器已删除。

## 激活请求交付的证据

第一轮未加 GUI 诊断环境。第二轮仅在私有用户总线的激活环境增加 `G_DBUS_DEBUG=message`，从 journal 按确切 GUI PID 导出完整消息日志；包内二进制、`.desktop` 和 `.service` 文件原样使用。总线监视器另记录发往应用的 Activate 与应用名称的 owner 变化。

- 冷启动 CLI：总线监视器看见 Activate，但 GUI 接收日志中该方法调用为 **0**；随后 GUI 的总线名称消失。
- 保持事件处理的 GIO：GUI 接收 **1** 次 Activate，并显示首页。
- 已运行实例的 CLI：同一 PID 的累计日志接收 **2** 次，其中第 1 次是前一组 GIO，第 2 次来自新 CLI；不能把累计数写成重复处理同一个请求。
- GNOME 菜单：新 GUI 接收 **1** 次 Activate，带 GNOME 的启动/激活 token，首页可见。

这将早期失败定位到冷启动激活请求未交付给 GUI，解释了为何只观察进程存在或命令退出 0 不足以判断首页已打开。调用者过早结束、尚在激活中的请求被丢弃是当前推断；本轮未追踪 D-Bus daemon 内部队列，不能进一步宣称某个上游函数已被证明有缺陷。产品启动逻辑没有修改，冷启动 CLI 路径仍明确记录为失败。维护测试继续等待同步 Activate 回执；菜单可用性以本轮独立实测为依据。

## 复现与隔离

```sh
python3 -B Scripts/linux/prepare-native-input-vm.py \
  Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5 \
  --stage desktop --maintenance-debs \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.1_amd64.deb' \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.3_amd64.deb' \
  --desktop-launch-probe
python3 -B Scripts/linux/run-native-input-vm.py PREPARED_DISK_DIRECTORY
```

此选项使用 maintenance 场景，安装上述第二个冻结包，实际执行 guest 的 dpkg、stage/activate、用户 bind 和 root/Host 启动，然后只运行桌面启动对照，不执行维护升级循环或中文测试。第一轮磁盘 `disk.jmotezfd`、运行 `run.7xzmuu96`；第二轮磁盘 `disk.xs0xblij`、运行 `run.kbajf23f`。第二轮外层会话 `75912` 已退出 0，没有待续跑句柄。

测试沿用固定镜像/公开内核、独立 boot ID、无网卡、无宿主桌面/总线/输入/GPU 挂载和仅 `/dev/kvm` 的设备边界。4 vCPU、6 GiB guest、10 GiB 容器上限。新模块在任何键盘、采集库、进程操作或 D-Bus 调用前核对 maintenance 标记、明确的 `desktop_launch_probe` 和唯一 VKMS card0。3 项新增保护加 10 项既有保护全部通过。

测试键盘只在 guest 创建，等待 GNOME 实际打开该 evdev 后，发送 Escape、Super、ASCII `farpane` 和回车。截图使用冻结 libdrmtap 0.5.8 的 CPU mapped frame，只读取 guest `/dev/dri/card0`；格式、尺寸、长度有界，每张 PNG 限 1 MiB。运行器严格核对名称、base64 和 PNG 头后保存到本轮独立目录。没有物理 GPU 工作、宿主屏幕采集或用户剪贴板读取。

程序与包复用已有冻结字节；新测试位于 `Linux/tests/`，入口位于 `Scripts/linux/`，磁盘/overlay/cache 位于 `Build/`。实际 guest 源码逐项对照磁盘记录中的 SHA，原始失败现象、总线接收追踪、截图和运行命令保存于[桌面启动证据](../../Evidence/LinuxHost/2026-10-18-native-desktop-launch/README.md)。历史源码归档与包未重打。

## 尚未覆盖

本项通过的是私有 GNOME 搜索图标与菜单启动、首页显示、16 秒观察及后台代际保留。实际 linux-host 菜单、KDE、任务栏/Alt-Tab 分组、缩放、通知抢焦点、锁屏/休眠、多用户、真实网络连接和硬件 GPU 没有因此通过。GUI 60 MiB 与组合内存预算、中文缺陷及完整 U5 发布门槛继续保留；`result=pass` 只指菜单启动检查，不表示表中 CLI 冷启动成功。
