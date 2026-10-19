# FarPane Linux GPU 媒体重构（linux-host）：桌面入口冷启动

2026-10-18。原 `.3` 的冷 `gio launch` 曾返回 0，却没有把 Activate 交付到 GUI，GUI 约 10 秒后退出。新的桌面入口选择 `Exec` 启动，仍保留 GTK 的单实例和显式 D-Bus 服务。私有 GNOME 对照及 `.5` 实际包的五种启动方式复测通过，新入口的七项窗口生命周期检查通过。Ubuntu 24.04 的 Debian 升级与 Fedora 44 的 RPM 升级均通过，各完成两次软件视频连接；新包没有在宿主安装。

## 修改与依据

canonical `Linux/packaging/org.farpane.FarPane.desktop.in` 只将 `DBusActivatable=true` 改为 `false`，保持 Exec、图标、StartupNotify、WM_CLASS、desktop 文件名与应用 ID。桌面启动器因此执行同 release 的 `farpane`。GTK 在程序启动时创建首页，或向已有实例转交激活；不增加常驻启动器、shell 包装、计时器或隐藏窗口。

`org.farpane.FarPane.service` 仍使用 `farpane --gapplication-service`，Host 的通知/托盘 action 仍可显式激活 GUI，审批仍通过原控制 socket。没有删除 GUI 总线名称，也没有让任何总线探测自动创建窗口。这里 `DBusActivatable=false` 选择的是 desktop 启动器的入口，不代表停用应用本身的 D-Bus 能力。相关协议见 [Desktop Entry D-Bus activation](https://specifications.freedesktop.org/desktop-entry/latest/dbus.html)。

GLib 2.88 的 [gio launch](https://raw.githubusercontent.com/GNOME/glib/2.88.0/gio/gio-tool-launch.c) 调用应用启动后返回，[GDesktopAppInfo](https://raw.githubusercontent.com/GNOME/glib/2.88.0/gio/gdesktopappinfo.c) 对 D-Bus 使用异步方法和异步 flush。原始接收追踪已证明冷启动请求未到达 FarPane，延长调用者事件处理后可用；内部消息为何丢失仍属于推断，没有修改系统 GLib 或宣称已经定位某个 D-Bus daemon 缺陷。选择 Exec 避开的是这条短命启动器路径，不按 GNOME 版本或某个程序名增加特判。

## 冻结二进制与来源

`Scripts/linux/repackage-native-desktop.py` 只接受 Build 中已通过完整 manifest 验证的原生 bundle，逐项核对 160 份编译源码与 receipt、三份可执行/媒体文件与 build 记录。canonical 模板必须与旧模板仅相差上述一行，否则拒绝。结果只允许四个条目变化：desktop 文件、对应源码模板、新增重包装脚本，以及附带来源记录的 `build.json`。原编译 receipt 保持不变；并非给当前工作区补写一张“已编译”的凭据。

父 bundle 为 `farpane-native-dev-d393fd0cff634416807feae5`，manifest SHA-256 `7ec4f7e64dc80688225c5398f99d3f2931f9f2e6346f115469a64defb4b69ebd`。新 bundle 为 `farpane-native-dev-ec305482eaacd98258e28587`，manifest SHA-256 `ea282757ad9874d244c84fac80d72ea8ecf66c9c06126e42d3f29e54cb312db3`。GUI/core/libdrmtap 三份字节与父版本完全一致，FFmpeg 未重建；暂停中的 `0044` 和 `paste_target.rs` 未被引入。

新 Debian 候选 `Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.5_amd64.deb`，18,822,224 字节，SHA-256 `ef1ff54fa554e5d0bbfb1d8e0433bc686f3fabcecd6c99f9712c002461d34448`。解包后 3,132 条 manifest 与新 bundle 相同，七份安装工具与 canonical 源码相同。未包含已否决 `.4` 的缓存刷新代码和依赖。当前 linux-host 仍运行 `.1`，新包未在宿主 stage/activate。

```sh
python3 -B Scripts/linux/repackage-native-desktop.py \
  Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5
python3 -B Scripts/linux/package-native-deb.py \
  Build/Linux/artifacts/farpane-native-dev-ec305482eaacd98258e28587 \
  --version 0.1.0~dev.20261018.5
```

现有 `.3` 完整应用源码归档仍绑定相同 GUI/core/媒体源码；`.5` 另附本入口修改和重包装脚本，来源链在新 `build.json` 的 `desktop_repackage` 中。不能把旧归档单独称作包含 `.5` 的新入口，也不能直接重编当前仍带暂停草稿的工作区。这里仅复用已验证的应用，完整许可审计与独立完整源码重编门槛不因此关闭。

对应 RPM 为 `Build/Linux/rpm/farpane-native-candidate-0.1.0~dev.20261018.5-1.fc44.x86_64.rpm`，SHA-256 `075c5bbca66816541a18d2fb45b14f2a9c2c41ac4ef2f1b5020c847abd9b3ab7`，同一新 bundle，无事务 scriptlet。补充配方 `Build/Linux/source-bundles/farpane-native-desktop-recipe-20261018.5.tar.gz`（SHA-256 `fea0b91195ffa92f4a75d9bbc3e5a0c91c7f8cba6a7003c0514efcb78bc16529`）固定二十份实际包装源码/文档，并明确需要配合原 `.3` 完整应用源码归档；不是另一次完整源码编译。后续修改工作区文档不会重写这些冻结包。

## 启动方式对照

第一组 `disk.3trx7uwp/run.z9ihie2y`、会话 `10407` 已退出 0。使用原 `.3` 包，在明确标记的私有 VM 内临时只改普通用户 desktop 的这一行，测试结束后逐字节还原。冷 CLI、同步 D-Bus、保持事件处理的 GIO、已有 GUI 的 CLI 和 GNOME 搜索菜单五种方式均创建/保留可见首页，并在 16 秒观察期末仍有正确 GUI 总线 owner。已有 GUI 的 CLI 保留同一 PID/start ticks；各组的 root/Host 代际不变。

CLI 从没有交互启动 token 的私有测试进程发起，首页出现在 GNOME 概览缩略图中，不据此宣称它抢得键盘焦点；GNOME 菜单回车后正常关闭概览并显示首页。两张原始截图均已查看。新测试为 Exec 子进程的 stdout/stderr 使用文件，避免把继承的管道仍打开误认为 `gio` 命令未退出。独立启动过程、GUI 是否存活、总线身份和实际截图分别核对。

对照入口为 `--desktop-launch-probe --desktop-launch-transport exec`。实际新包复测必须省略后一个选项，使用包安装器生成的原始 desktop，不允许测试再改入口。对原生 Exec desktop，五种方式必须全部通过，不能沿用旧 profile 只要求 GNOME 菜单通过的弱条件。18 项隔离入口保护通过；初版测试 guard 的定位错误与修正日志一并保留。

## 实际新包检查

- `disk.y5iyeiaf/run.q3_wm5la`，会话 `55620` 退出 0：`.5` 经真实 dpkg/stage/activate/bind 后，原始 desktop 的五种启动方式全过；测试前后 desktop SHA 相同，没有临时替换入口。CLI 和菜单截图已查看，root/Host 代际不变。
- `disk.jej2433i/run.051ng0aa`，会话 `23759` 退出 0：首次搜索前等待 7 秒，七项生命周期全过。GUI 1069 完整退出后重开为 1212；root 756/Host 787 的 start ticks 保留，两次 Alt-F4 后整个 `/proc/<gui>` 和总线 owner 消失，各约 0.130 秒。精确 PID 的 Wayland journal 只创建一个 app_id 正确的 toplevel，并记录 destroy。Alt-Tab 品牌图标、重开首页、关闭后屏幕已查看。为了覆盖 Exec 子进程，诊断只在私有 GNOME 和 D-Bus 激活环境启用 Wayland 追踪；没有改变产品默认环境。
- `Build/Linux/native-deb-smoke/20261018T122029Z`，会话 `36209` 退出 0：Ubuntu 24.04 `.3 → .5` 六组 dpkg 检查通过，包括已提交版本保留、未完成维护拒绝配置、重试、卸载保留，以及升级后两次真实软件视频连接和 Viewer 回收。这里的存活进程是私有 shell 哨兵，不是真实 systemd 服务切换。
- `Build/Linux/native-rpm-smoke/run-v7vb66vj`，会话 `17242` 退出 0：Fedora 44 `.3 → .5` 七组 RPM 事务检查通过，含显式 stage、升级后两次软件视频连接、配置与卸载保留。不等同于 Fedora 内核/SELinux/桌面验收。

全部测试已经结束。原始对照、包、源码、PNG、journal、安装/连接日志在[本轮证据](../../Evidence/LinuxHost/2026-10-18-native-desktop-exec/README.md)。这些是独立软件桌面/回环测试，没有打开宿主桌面或中断现有连接。

## 尚未关闭

后续[图标诊断](native-desktop-icon.md)已补齐相同 CLI 入口的稍后冷启动、七秒等待和 Shell 内部关联记录。身份正确，等待未改善；已观察到关联更新后预览仍保留通用 GIcon，并另有名称与截屏不一致。新证据缩小问题范围，没有改变本页冻结 `.5` 包，也没有关闭首次图标问题。

冷 CLI 已能显示首页，但新安装后的该概览缩略图下方仍出现通用 GTK 图标；GNOME 搜索图标、稍后的菜单窗口与 Alt-Tab 品牌图标正常。不能把它说成所有桌面位置的图标都已正确，也尚未证明该现象和异步应用索引同因。首次安装的立即搜索、概览图标、KDE、通知焦点、实际用户连接及完整发布门槛仍需后续工作。本项不涉及中文输入、硬件 GPU 或内存优化；60 MiB 目标未改变。
