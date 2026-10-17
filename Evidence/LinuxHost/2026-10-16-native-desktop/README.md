# FarPane Linux GPU 媒体重构（hermes）：桌面通知、托盘与激活

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40b`。完整原生 GUI 继续开发，未安装、提交或部署本检查点；现有 RustDesk/FarPane 服务、配置、桌面未操作，Mac/xuanwu 未修改，FFmpeg 未重建。

## 实现

Host 内使用纯 D-Bus SNI、静态 DBusMenu 和桌面通知，支持 KDE/freedesktop watcher，使用 FarPane 图标。Host 不加载 GTK，也不保留隐藏 GUI。线程、队列、通知条数和调用均有边界；服务稍后出现、退出或换 owner 时重新检测。授权页显示实际状态，注册成功不等于真实桌面已显示托盘。

GUI 的标准 D-Bus action 自动启动/聚焦主窗口或本机连接管理，复用既有窗口。通知 action 只打开界面；批准仍经既有同 release、UID、generation 控制接口。通知校验 unique sender、ID 和当前待批准请求，过期事件不触发激活。通知缺失或无人应答继续由 CM 按 30 秒拒绝，认证策略不改变。

新增 canonical D-Bus service/desktop 模板。X11 实测 `_GTK_APPLICATION_ID=org.farpane.FarPane`，`WM_CLASS=farpane`；修正 desktop 的 `StartupWMClass` 与实际一致。仅在测试私有数据目录生成 D-Bus 激活入口；尚未实现完整原生安装器迁移。

截图检查另发现人工审批完成后，旧密码面板仍覆盖 Viewer。现已在等待审批/认证成功时清理旧密码 challenge、隐藏输入框、清空输入；等待审批时使旧密码库读取失效，已提交的保存候选仍仅在认证成功后处理。保留验证码 challenge 的现有路径；真实 2FA 仍未验收。

## 实际测试

最终二进制的运行（哈希均与 `source-state.json` 一致）：
- `20261016T185244Z`：desktop。
- `20261016T185454Z`：approval。
- `20261016T185342Z`：secrets。

桌面 26 项检查覆盖：稍后提供桌面服务、两种 watcher、ARGB 图标/DBusMenu、标准激活与单实例、主窗口/连接管理/右键菜单、关闭 GUI 后 Host 保留、新入站通知、伪造来源和无效 ID、服务换 owner、旧 owner/旧 ID 拒绝、查看通知不批准、实际允许后首帧、通知关闭、不支持 action、服务消失、无人处理超时、原身份/策略保留、Host 无 GTK 映射、X11 应用身份，以及等待审批/认证后没有旧密码面板。

采用普通用户、私有 D-Bus 服务、两台私有 Xvfb、真实 Host/GTK/Viewer 与容器 loopback。通知/watcher 为测试服务；其接收记录不是 GNOME/KDE 真正展示通知的证据。通知服务消失后约 29.4 秒收到终止结果（请求总审批计时仍是原 30 秒），没有帧或密码尝试，worker 回收。Viewer 保留失败页供重试，测试再实际关闭窗口；GUI 进程退出后同一 Host 存活。

入站允许/拒绝/超时三轮再次通过，超时轮确认管理对话框实际消失。密码库五轮实际连接、保存/读取/取消/手动连接/删除以及设备页操作回归通过。Host 生命周期、GUI 关闭/重开、离线 helper、配置 owner 与身份边界回归通过。22 项协议、4 项 GUI、5 项 staging 测试、native core/GUI Release、旧 Flutter/GPU 组合 check、52 个 canonical staging 文件、pin/patch/overlay/lock 核对通过。旧编译 warnings 和 Xvfb 无 DRI3 提示保留。

## 保留的失败与修正

- 初次 core check 的 Crossroads 接口名生命周期编译错误已修正；Release 通过。
- `183459Z`：测试只发 MessageDialog response，未真正关闭窗口。改为实际 close，并增加关闭状态检查。旧入站归档对“已关闭对话框”的描述证据不足，本轮重新验证；旧冻结归档不改写。
- `184003Z`：旧通用测试驱动在人工审批流程尝试一次合成密码，检查失败；服务端未绕过审批。修正该模式的测试输入。
- `184144Z`：审批超时与 worker 回收已发生，但测试错误等待失败页面自行退出。改为先确认回收，再实际关闭窗口，不改变产品保留失败页的行为。
- `184439Z`、`184657Z`：桌面协议/生命周期检查通过；后续截图发现旧认证面板残留，不能据这些旧运行宣称界面完整。最终运行新增实际 widget 可见性断言并检查截图。

## 资源与未验收

`memory-summary.json` 和原始 maps/smaps 记录不同采样时点：主窗口含管理对话框、与另一个 Viewer GUI 并存的管理窗口、两轮连接结束后的 Host。PSS 会受共享页归属和先前连接影响；这些值不能相加当作同时组合预算，也不能当作托盘的增量成本。没有后台 GUI 进程不等于整个产品低内存验收通过；首页 60 MiB 目标仍未通过。

真实 GNOME/KDE 的托盘/通知样式、Wayland activation token 与焦点、用户总线整体重建、后台注册/autostart、锁屏/greeter、root 监管、睡眠/网络恢复、2FA、富剪贴板、完整 HUD、实际 GPU/长稳预算、发行版 ABI、安装包/更新/回退仍待完成。`runtime_ready=false`，完整 GUI 交付目标保持进行中。

```sh
Scripts/linux/test-native-viewer.sh desktop
Scripts/linux/test-native-viewer.sh approval
Scripts/linux/test-native-viewer.sh secrets
Scripts/linux/test-native-host.sh
python3 -B Scripts/linux/prepare-native.py --check
```
