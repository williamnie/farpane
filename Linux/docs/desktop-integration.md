# FarPane Linux GPU 媒体重构（linux-host）：桌面通知与激活

原生 Host 的桌面适配器使用已有 `dbus`/`dbus-crossroads`，不加载 GTK，不保持一个隐藏 GUI。仅普通用户的桌面会话启动；root、显式 greeter/非用户会话和缺少会话总线时禁用。该判断不代替后续登录会话授权与 root 监管验收。

Host 使用 `org.farpane.FarPane.Agent`；托盘对象位于 `/StatusNotifierItem`，静态 DBusMenu 位于 `/MenuBar`，支持 KDE 与 freedesktop 的 StatusNotifier 接口。图标来自同一 canonical FarPane 资产，提供名称和 32×32 ARGB 像素。注册状态表示 watcher 已接受注册，并不保证当前桌面真的显示托盘。

GUI 的 `org.farpane.FarPane` 名称仅由 GTK Application 持有。`show-home`、`show-connections`、`tray-menu` 三个无参数 action 都只打开/聚焦界面；已有 Viewer 不被替换。连接审批继续使用原先校验 release、UID 和 generation 的控制 socket，不增加 D-Bus 授权接口。重复打开复用现有主窗口/对话框。私有 X11 实测 `_GTK_APPLICATION_ID=org.farpane.FarPane`、`WM_CLASS=farpane`，菜单模板的 `StartupWMClass` 与实际 class 匹配。

从 `.5` 起，desktop 明确使用 `DBusActivatable=false`，启动器执行现有 Exec；应用仍保留同一 D-Bus 名称与 `.service` 显式激活入口。此选择修复已复现的短命 CLI 冷激活未交付问题，没有新增常驻启动器或改 Host。实际包的 CLI/GIO/GNOME/显式 D-Bus 与单实例检查见[冷启动证据](native-desktop-exec.md)。

`Linux/packaging/org.farpane.FarPane.service.in` 和 `.desktop.in` 的 `@FARPANE_RELEASE@` 由用户安装器替换为受管理的不可变 release 绝对路径。D-Bus 激活使用 `--gapplication-service`。[安装与回退合同](native-install.md)已实现每用户的菜单/图标/激活入口迁移及恢复，配合 root release 事务做隔离测试；宿主菜单/激活服务尚未迁移，真实桌面及服务切换仍待验收。

后续桌面验证：冻结 `.20261018.3` 的[私有 GNOME 实际菜单启动](native-desktop-launch.md)两轮显示独立品牌图标和首页，后端进程代际保留；使用真实 guest 内核键盘与 VKMS 截图。冷 `gio launch` 的激活交付失败另行保留，已有 GUI 的同命令及 GNOME 菜单可用。本项不替代其他桌面的任务栏、Alt-Tab、缩放、通知与焦点检查。此前宿主切换的实际范围见[实机维护记录](native-hermes-maintenance.md)。

后续[窗口生命周期](native-desktop-lifecycle.md)进一步验证私有 GNOME 的单实例、首页 Alt-Tab 品牌图标、关闭后 GUI 真正退出和原 Host 上重开；首次搜索前显式等待 7 秒。它不覆盖 Viewer 多窗口分组或其他桌面。立即安装后的索引就绪问题与冷 CLI 失败仍单列；缓存刷新尝试已因对照证据撤下，不改变安装器合同。

通知仅描述待批准请求，包含“查看请求”入口；不含密码。文字去控制字符、限制长度，通知标识绑定当前未授权连接。处理通知 action 时同时核对当前通知服务的 unique owner、通知 ID 与未决请求；退役服务和失效 ID 不触发激活。支持服务发送的 activation token，但真实 Wayland 桌面是否允许抢焦点仍须实测。点击通知不会批准连接。

授权、取消、断开或审批超时后关闭对应通知。未处理的请求继续由原 CM 的 30 秒计时拒绝。通知服务不可用、不支持 action、未显示通知或用户未处理时均不会改用其他认证策略。通知服务和 watcher 退出、重启、稍后出现时重新检测；Host 快照向授权页报告实际可用性。后续[Host 整条用户总线重建检查](desktop-bus-recovery.md)已通过：同一 socket 下四个新总线身份恢复托盘/通知，活动视频继续，无人处理请求仍超时拒绝。再后续 GUI 专用私有总线中断已验证 GUI 退出、Viewer 完整回收、独立 Host 原入站出图和新总线下重开；它不是 GUI 无缝存活，真实桌面与睡眠生命周期仍未验收。

所有桌面调用放在 Host 专用线程，普通服务调用限时 500 ms，GUI 激活限时 3 秒；不阻塞媒体或审批计时线程。操作队列 8 项、信号队列 64 项，最多跟踪 64 个待批准请求；每个请求每个提供者只发送一次通知，最多每 500 ms 发一条。重复点击按 500 ms 限流。通知本身不是可依赖的授权通道，漏通知或超时都保持原有拒绝策略。

隔离测试入口：`Scripts/linux/test-native-viewer.sh desktop`。使用独立容器、普通用户、两个私有 Xvfb 和私有 D-Bus；通知/watcher 是可控制的测试服务，Host、GTK GUI、Viewer、网络连接与审批按钮是真实实现。该测试不证明 GNOME/KDE 的真实通知样式、托盘扩展、桌面焦点策略、锁屏或发行版兼容性。

协议依据：[Desktop Notifications](https://specifications.freedesktop.org/notification/latest-single/)、[StatusNotifierItem](https://specifications.freedesktop.org/status-notifier-item/latest/status-notifier-item.html)、[StatusNotifierWatcher](https://specifications.freedesktop.org/status-notifier-item/latest/status-notifier-watcher.html)、[Desktop Entry D-Bus activation](https://specifications.freedesktop.org/desktop-entry/latest/dbus.html)。
