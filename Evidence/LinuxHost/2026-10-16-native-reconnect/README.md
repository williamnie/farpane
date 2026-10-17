# FarPane Linux GPU 媒体重构（linux-host）：同窗口重连检查点

2026-10-16。失败或结束时提供重新连接；重试保持本次 ID/服务器快照，旧 worker 确认回收、旧 widget 退出后，下一次主循环才创建新 Viewer。取消/关闭窗口清除待连接请求，禁止新旧 owner 重叠。第二次连接请求的替换确认已实现，完整 D-Bus 激活场景仍待对接验收。

实际故障注入结果见 `20261016T132437Z`。两个私有 Xvfb 的真实 TCP 会话先完成认证和画面，再使用 pidfd 终止这个 GUI 创建的独立 Viewer worker；随后由真实重连按钮触发新会话。同一 GUI、不同 session、两个 worker 回收、两次实际呈现和 Host 保留均通过。没有操作宿主进程、桌面、原 RustDesk 或已安装 FarPane。

`20261016T132318Z` 是首次测试驱动失败：误将 GUI 主线程的 children 文件当成整个进程的子进程列表，检查失败发生在信号发送前。已改为稳定 pidfd + PPid/executable 检查；该失败原始记录保留。

GUI 单测和 Release 通过。重连变更后又验证实际键盘/中文 IME、工具栏不外发、应用失焦/断开松键；私有 Wayland 的两次 GPU 连接通过，VAAPI、共享 GLES context、完成 ACK 与正常退出仍成立。GPU 仅 renderD128、256×128 静态单路内容、12 Hz 私有输出，既有 FarPane 连接全程为零。最后一轮 GUI 日志无 GTK CRITICAL。

这不代表已完成断网/睡眠恢复、真实桌面 GPU 崩溃、20 轮资源稳定性或完整产品验收。保存了本次 source-state.json 和二进制哈希；实际输入回归日志列出 15 项检查，GPU 原始文件另存本目录。
