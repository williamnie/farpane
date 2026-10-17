# FarPane Linux GPU 媒体重构（linux-host）：真实输入与文本剪贴板

2026-10-16，`codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`，改动未提交。这是完整 GUI 的开发检查点，没有安装新 GUI、访问 GPU、操作宿主桌面或更改现有 FarPane/RustDesk。

## 改动

- 原生 GTK 键鼠、滚轮、坐标映射和输入法接入独立 Viewer。显示器负坐标、缩放黑边、按键原始值、拖动释放均有明确处理；系统快捷键独占必须收到桌面的实际授权。
- GUI 队列最多 64 条，只合并相邻鼠标移动；核心网络队列最多 256 条、累计 1 MiB，额度保留至实际异步发送完成。无法交付输入时停止会话，避免静默丢掉松键事件。
- 输入法过滤由 GUI 显式处理，不能吞掉已转发按键的释放；预编辑开始时释放已发出的组合键，中文提交一次。失焦、切换显示器、撤权、断开会释放已按下的键和鼠标键。输入法在 widget 销毁前解除绑定。
- 第一阶段剪贴板支持 UTF-8 文本，每次最多 8 KiB，双方向独立开关、默认关闭。仅活动窗口读写本机选择区，异步读取有期限和大小上限，策略 revision 取消旧任务；worker 不创建本机剪贴板监听器。压缩内容解码有窗口和输出上限。

## 实际结果

| 检查 | 结果与记录 |
| --- | --- |
| 核心单测 / Release | 11 通过，Release 3m25s；`native-input-sharing-build.log` |
| 协议 / GUI | 协议 18、GUI 3 通过；最终 GUI Release 9.77s；相关构建日志 |
| 真实输入 | 14 项检查，两次独立会话；`native-input-final-smoke.log`、`input/` |
| 文本剪贴板 | 两次会话均完成双向中文文本、8193 字节拒绝、关闭后不发送；`clipboard/viewer-*/clipboard-result.json` |
| canonical 重建 | pin、patch、overlay 和锁文件匹配；`native-input-source-verification.json` |
| staging 保护 | 4 通过，保留未知修改；`native-input-staging-tests.log` |

输入测试通过 XTest 向私有 GUI Xvfb 注入真实事件，经网络到另一个私有 Host Xvfb。`xev` 记录实际字符、Ctrl/Shift、中文“中”和鼠标事件；确认输入法预编辑字符没有发往远端，中文只提交一次，本机工具栏点击不变成远端点击。用 XQueryKeymap 确认切换到另一应用窗口后 Ctrl 已松开，并在 Ctrl 再次按住时关闭 Viewer，确认断开也释放了远端按键。两个 GUI 退出后同一 Host 保持运行，ID/revision/固定密码状态不变。

首轮测试发现输入法吞掉松键，以及销毁 widget 后才解绑输入法的问题，均已修复；原始失败记录保留在 `initial-failures/`。失焦夹具改用另一顶层窗口，模拟真实应用切换；直接聚焦 X11 根窗口的 NotifyAncestor 不是等价行为。最终两轮均无 GTK/GLib CRITICAL。

剪贴板测试用独立 X11 selection owner 实际持有/读取两个显示器的 CLIPBOARD。不是直接调用协议回复。测试用的文本、密码和配置均为容器合成值。该次总日志仍列通用 8 项会话检查，新增剪贴板结果以每个会话的 `clipboard-result.json` 为准；随后脚本已补充分类结果列表。

所有运行均在无外网、无 GPU、无宿主桌面和服务 socket 的容器内；使用两个私有 Xvfb 与实际 loopback TCP。PSS 仅是静态 640×480 软件模式样本，不是内存目标或 GPU 性能验收。

## 未验收与下一步

图片/HTML/RTF 剪贴板、Wayland/IBus/Fcitx 与实际系统独占、拖动与滚轮跨桌面矩阵、断网/撤权压力、GPU EGL 导入/颜色/完成同步、音频、文件传输、完整首页设备与共享管理、后台/SNI/通知、跨发行版包和资源预算仍未完成。不能把本轮文本和软件画面结果当作完整 GUI 交付。

复现：`Scripts/linux/test-native-viewer.sh input` 与 `Scripts/linux/test-native-viewer.sh clipboard`。`source-state.json` 记录源码/产物 hash，`SHA256SUMS` 校验本轮归档。以前的证据保持原样。
