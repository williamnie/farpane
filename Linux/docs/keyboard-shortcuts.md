# 原生 Viewer 的独占键盘生命周期

2026-10-17。`.6` 的真实 GUI 已复现一个 Wayland 问题：请求一秒后按钮变为“独占未获授权”，但 compositor 仍保存请求；迟到的授权能使按钮再次变成“键盘已独占”。原始截图与 Wayland 请求/事件记录保留在 `Build/Linux/native-keyboard-smoke/20261017T073015Z`。这不是 mock 的状态测试。

## 实现

`Linux/gui/src/viewer_input.rs` 区分用户仍在请求与桌面已授权。实际收到 GDK `shortcuts-inhibited` 才显示“键盘已独占”。等待期间显示“请求独占…”，给桌面确认对话框 15 秒时间；再次点击、超时、权限撤回、窗口失活或断开均撤销 GDK 请求，同时清理计时器。迟到事件不能重新启用已取消的请求，旧计时器不能取消新请求。

独占按钮的鼠标点击保持画面焦点，避免“按钮先抢焦点→释放独占并重置按钮→同一次点击又重新请求”的顺序问题。键盘导航离开画面仍释放控制。撤权和取消会释放已发送的远端按键，窗口/会话退出沿用原有松键流程。没有修改核心输入协议或 Host GPU 链路。

## 隔离验证

入口为 `Scripts/linux/test-native-keyboard.sh ARTIFACT`；开发时 `--built` 使用当前已编译的 GUI/core。固定已有 Sway 测试镜像，4 CPU/12 GiB、断网，无宿主桌面、输入设备、GPU、音频或系统总线挂载。Host 采集私有 Xvfb，Viewer 在私有 Sway/pixman 真实连接、认证和呈现软件画面。

`native_wayland_fixture.py` 只连接 `/run/farpane-native-test/user/` 下的私有 socket。它通过 compositor 的 virtual keyboard/pointer 发送外部输入，通过 screencopy 获取实际合成画面；GUI 不启用 smoke 开关或内部点击。测试通过 Sway IPC 控制实际授权/拒绝，并检查撤销后 compositor 已找不到该请求。

检查覆盖：

- 超时后再授权不能启用独占；两秒后正常确认仍可授权。
- 即时授权、用户取消和 compositor 撤权。
- 快速取消再请求，跨越旧请求的 15 秒期限后新请求仍有效。
- 切换到私有空工作区、返回原窗口时不恢复旧独占。
- 断开时撤销请求、回收 Viewer，保留同一个 Host。

Sway 的实际拒绝/授权入口见[官方实现](https://raw.githubusercontent.com/swaywm/sway/master/sway/commands/seat/shortcuts_inhibitor.c)；virtual keyboard 的事件合同见[协议定义](https://raw.githubusercontent.com/swaywm/wlroots/master/protocol/virtual-keyboard-unstable-v1.xml)。运行使用本仓库锁定的镜像，在线源码仅用于理解接口，测试结果以本地产物和原始事件为准。

最终 15 秒版本的八项检查已于 `20261017T073523Z` 通过：实际画面匹配 269,216 个色块像素，Viewer 回收且 Host 保留；GUI SHA-256 为 `9e57d7b3540b4282bcf23837d2bd05fc082f5da45a729f9d8f0e09a61984a421`。此前 `073241Z` 是一秒超时的中间修复验证，七项通过，不混称最终八项结果。GUI Release 编译、9 项单测通过，1 项既有图形夹具测试按要求跳过。只修改一个产品源码文件并重编 GUI，核心与 FFmpeg 复用。

X11 的两次实际连接及键鼠/中文输入/松键回归通过。`.7` Debian 包在 Ubuntu 26.04/24.04 各通过六类 dpkg 检查，`.6 → .7` 后各两次软件视频连接成功。包 SHA-256 为 `809fecd71d5704bc6c77f081570013b91461c7e735996eb16e5cb804f873c5dd`。当前 [`.7` 候选](native-test-candidate.md)与[原始证据](../../Evidence/LinuxHost/2026-10-17-native-keyboard/README.md)分别记录交付和检查范围。

本轮完整源码归档为 `Build/Linux/source-bundles/farpane-native-source-71659d9e57af642ef0d2afc4.tar.gz`，SHA-256 `443004d556904ea1a6442047b7df27d068358a6985aea2347d697f6461d7a12d`，88,654 条目、1,082 个 vendor 目录。绑定新 GUI 与复用核心，没有重跑全套媒体冷构建；旧 `.6` 归档保持不变。依赖材料内容不变，仅更新构建绑定，完整发布审计仍未完成。

本检查不替代真实 GNOME/KDE 的确认对话框、物理快捷键、输入法/键盘布局、锁屏或用户桌面验收。产品仅支持绝对指针，未新增指针锁定。首页内存目标、真实 GPU 和完整发布门槛保持未完成。
