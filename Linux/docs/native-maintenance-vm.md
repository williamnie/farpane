# FarPane Linux GPU 媒体重构（linux-host）：真实 systemd 的私有维护验收

2026-10-18。既有容器安装测试使用服务管理器替身；本轮复用已缓存的私有内核/GNOME 虚拟机，以冻结 `.20261018.1` 和 `.20261018.3` Debian 包运行真实 dpkg、systemd/logind、root 服务、普通用户 Host 和 GUI。只新增测试与证据，没有重编或改写产品候选，没有执行暂停的中文输入方案。

最终同一冻结磁盘连续两次运行均通过下述六组检查：`run.k60ifgcg` 与 `run.7qibqyoe`。两次使用独立 overlay/boot ID，均正常关机并退出 0；没有遗留测试容器。

## 已验证的维护链路

1. 独立 guest 启动真实 systemd、PAM、logind 与 GNOME Wayland；UID 1000 为 seat0 的活动用户会话。
2. `.1` Debian 安装自动 stage；实际 `plan/activate` 建立服务单元与 release，普通用户 `bind` 安装菜单、两份图标和 D-Bus 文件。随后启动真实 root 服务/Host，通过用户总线 Activate 启动 GUI，核对其确切 PID 与 release。
3. 三个 `.1` 进程存活时安装 `.3` Debian。安装只暂存候选，旧 root/Host/GUI 的 PID、UID、start ticks 完全保留，新代没有运行进程。
4. 显式维护 activate 停止旧代，systemd 启动新 root 服务，新的 Host 对接同一登录会话。用户 bind 后，新 GUI 的实际总线 PID 指向 `.3`。
5. 按相同维护流程回退到 `.1`，再运行用户入口 `rollback`。旧版 root/Host/GUI 恢复，`.3` 没有残留可执行进程。
6. 最后 dpkg purge 删除候选与维护入口；已激活 `/opt` 副本与三个进程继续运行，另一个真实 systemd 哨兵服务及用户未知 autostart 文件不变。

在升级、回退和卸载后，检查本机身份快照、认证模式、固定密码状态、服务器、GPU 设置与设备列表一致；另对仅属于私有 guest 的 `enc_id/key_pair/password/salt` 字段做等值哈希比较。报告只列字段名与相等结果，不保存凭据正文。离线 guest 没有注册真实线上 ID，也没有用远端客户端验证固定密码登录；不将字段保留扩大为线上注册/认证验收。

系统单元在启动后仍为 disabled；手动启动服务没有被测试或安装器偷偷改成开机启用。所有维护动作都调用冻结包内真实命令，没有以测试替身替换 systemctl、loginctl、进程扫描或安装事务。

## GUI 启动时序与原始失败

最初三轮使用短命 `gio launch` 命令后直接采样：分别停在 GUI 就绪超时、包安装后进程集合变化、GUI 已有 PID 但总线名称还未注册。原日志保留，不能把它们当成已通过，也不能仅凭这些状态断言包安装重启了 GUI。

最终测试显式等待真实 `org.freedesktop.Application.Activate` 回执，再核对总线 PID 与进程身份；没有修改产品启动逻辑或让测试无条件重试/放行。该路径对应包声明的 `DBusActivatable=true`，并验证 desktop、D-Bus 文件和图标已绑定正确 release。本轮不把总线确认当成逐像素画面验收，没有自动点击 GNOME 应用菜单；早期 `gio launch` 路径未据此宣称已修复。

后续[独立桌面启动对照](native-desktop-launch.md)补齐了真实 GNOME 概览搜索、回车与首页截图，两轮均通过。GUI 接收侧追踪确认冷 CLI 的 Activate 未交付，而 GIO 事件处理、已有实例与菜单路径收到请求。它解释了早期进程采样不能代表窗口就绪，但仍保留冷 CLI 未通过及 daemon 内部原因尚未追踪的边界；没有重写本维护测试的历史结果。

## 复现与隔离

```sh
python3 -B Scripts/linux/prepare-native-input-vm.py \
  Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5 \
  --stage desktop --maintenance-debs \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.1_amd64.deb' \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.3_amd64.deb'
python3 -B Scripts/linux/run-native-input-vm.py PREPARED_DISK_DIRECTORY
```

入口沿用已有虚拟机准备器，但 `scenario=maintenance` 与输入 profile 分开：不启动文字目标，不调用中文协议/按键测试，也跳过启动时的 uinput 微测。产品服务自身仍在 guest 创建正常的输入设备。维护 controller 在任何写入或服务操作前检查专用内核参数、marker、guest boot ID 绑定、真实 systemd PID 1、root UID 和明确 maintenance 场景；外层运行器另核对 guest 与宿主 boot ID 不同。两项新增保护与八项既有入口保护均通过。

固定内核 7.0.0-38 与 Ubuntu 26.04 用户态来自既有缓存；4 vCPU、6 GiB guest、10 GiB 容器内存，维护场景总时限 300 秒。VKMS 模块只装入 guest，GNOME 使用软件渲染；唯一开放的宿主设备是 `/dev/kvm`，没有网卡、共享目录、宿主输入/GPU/显示/总线或服务 socket。每次运行使用新 qcow2 overlay，原磁盘只读，guest 最后正常关机。

准备器记录两个包的 SHA、实际生成的 systemd 单元哈希、测试源码、镜像和公开内核 pin。此轮没有替换固定镜像或重建 FFmpeg，新增测试不在历史冻结应用源码包内。

原始失败、成功、systemd journal、精确进程代际及源码快照见[维护 VM 证据](../../Evidence/LinuxHost/2026-10-18-native-maintenance-vm/README.md)。linux-host 当前安装和一条已认证入站保持不变，未 commit/push/发布。

## 未关闭项

本轮不包含维护期间真实远程连接/Viewer、回退到旧 Flutter P1、事务中断后的整机重启恢复、多用户/greeter、线上 ID 注册或实际宿主回退。KDE、Fedora SELinux、硬件 GPU/音频、首页 60 MiB、24 小时长稳以及中文输入缺陷也没有因此通过。完整 GUI 交付目标继续进行。
