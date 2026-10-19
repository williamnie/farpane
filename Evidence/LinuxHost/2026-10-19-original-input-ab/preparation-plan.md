# FarPane Linux GPU 媒体重构（linux-host）：原版输入短时对照窗口

状态：工具和执行清单已准备，尚未获得本轮服务切换授权，未启停 RustDesk、未打开原版 evdev。当前 FarPane `.8` 核心的中文缺陷仍未修复。本方案不是安装新修复包。

## 目的与已有证据

同一 Mac FarPane、同一 linux-host、同一应用，用户报告原版可直接输入中文，原生版失败。FarPane 首轮 30 秒观测有五组完整 Shift/Insert 内核事件；VM 的剪贴板同步正控制没有成功写入对端数据。此次要把“原版能输入”与当次原版后端/内核事件对应起来，不预设结果必然归因 DISPLAY 或剪贴板 owner。

Claude seq32 补充的三个实机 arboard 协议警告只证明各次初始化时没有获得 ext/wlr data-control，不能直接当作 native worker 当前状态。`clipboard-sync-vm/run.q2tpaj1z` 的 outer pass 是隔离运行完成，network result 为 recorded，不能称同步竞争回归通过。

## 已准备的观察入口

`Scripts/linux/observe-original-paste-keys.py` 使用既有 `Linux/diagnostics/paste_keys.py` 内核过滤与 FD 归属实现，只接受本机已核对的原版 launcher、核心库和 service 文件 SHA-256。`--check-baseline` 已通过，仅读这三份文件；不打开输入设备。10 项新保护测试和 11 项既有过滤测试通过。

采集入口需明确窗口标志、桌面 UID、已核对的原版 `--server` PID。要求 FarPane inactive / MainPID 0，原版 service active、没有 drop-in；验证 root/Host 的 UID、executable、角色参数、start ticks，及实际映射的原版核心库 inode/device。通过原版 root 的 uinput FD 查得其唯一键盘；使用只读 evdev、每 reader 内核九键掩码与二次解析过滤，不 grab、不注入、不保存其他键或正文。持有 pidfd，进程/设备/文件/服务代际变化立即终止，最长 60 秒，本窗口用 30 秒。

与 native 观察器不同，原版没有 NativeActivity 接口，**不能自动证明已认证连接 ID 或连接数量**。只在用户明确表示已连接原版、没有其他测试连接时采集。没有 uinput 或身份绑定失败就不打开其他设备；这可能是后端不同，记录为未采到，结合固定日志阶段判断，不能记为按键丢失。新的 CLI 尚未在运行中的原版上验收；共用底层过滤/FD 绑定已有私有 KVM 验证，本次准备未重复开启 VM 或读取宿主按键。

## 用户批准后执行，预计 3–5 分钟

1. 用户保持 Mac FarPane 原客户端、Ubuntu 同一 Chrome 普通窗口与同一输入框。记录当前 FarPane release、core/GUI 哈希、root/Host/GUI 代际与两项服务 active/enabled 状态。复核原版三文件基线；不修改服务器、ID、密码、输入法、显示模式或 Chrome 参数。
2. 在当前 FarPane 连接上运行已有 native 观察器 30 秒；ready 后用户提交一次约定中文，不按回车或手动粘贴。记录用户结果和既有日志的固定阶段，正文不留存。若当前没有连接，不暗中采集。
3. 停止 `farpane.service` 并确认 root/Host 退出，然后启动原版 `rustdesk.service`。不 enable/disable，不运行旧实验的 switch_runtime 脚本。用户连接此前成功使用的原版 RustDesk 身份；不改成 FarPane 的 ID，不重置密码。只接受同一个桌面会话，若原版连接需要换桌面/权限设置则停止并恢复 FarPane。
4. 核对原版 root 与唯一目标 UID 的 `--server` PID、映射核心和实际后端。用户确认连接后，以 `--uid 1000 --host-pid <经核对的PID> --seconds 30 --approved-test-window` 运行原版观察器；ready 后在同一输入框提交一次相同中文。保存九键、固定日志阶段与结果，最多一次窗口，不采集正文或所有键盘。
5. 无论成功、失败、采集拒绝或用户取消，都先结束观察器，停止本次启动的原版服务，再恢复 `farpane.service`。核对 `/opt/farpane/current` 和 core/GUI 哈希仍一致、只有新一代正确 root/Host、原版 inactive，开机策略保持原值。用户可重新连接 FarPane 原 ID 和固定密码。未更换安装包，因此不需要安装器回滚。

不等待用户无限期输入：超过约定短窗口未完成，先恢复 FarPane，保留阶段证据。恢复由当前前台执行流程处理，不创建定时任务或后台采集。若恢复失败，立即报告准确服务状态，不继续做其他测试。

## 原版停止命令的额外执行检查

已安装 `rustdesk.service` 的 ExecStop 使用 `/usr/bin/pkill -f "rustdesk --"`，范围不受 cgroup 限制。因此开始前与恢复前必须只读枚举其实际匹配对象，核对 exe、UID、角色和 start ticks；匹配范围必须仅包含本次启动的已验证原版服务/Host/子进程。已有 GUI PID 1360261 的当前命令不匹配该模式，不能把这次事实当作未来保证。

如果出现任何窗口前已有、未知或其他用户的匹配进程，**不调用这个宽泛 ExecStop**。保留清单，按已验证 PID/pidfd 处理本次进程的恢复需要另行明确方案；不能改服务单元、批量杀进程、忽略冲突继续切换。启动前发现此条件就不进入 B 段。不得为省事关闭已有 RustDesk GUI。

## 结果如何解释

- 原版成功、内核形态或后端不同：据实际差异建立最小复现；仍需区分角色、设备、修饰键与时序。
- 原版成功、九键形态相同：缩小到事件后续处理和剪贴板/初始化等差异，不直接等同于 X11 owner 根因。
- 原版也失败：本轮成功基准未复现，不能宣称已找到原生版独有原因；恢复 FarPane后根据新增事实调整。
- 原版不是 uinput 或观察绑定失败：仅保留能验证的阶段；不把“无事件记录”视为没发键。

服务切换与原版按键观察必须由用户批准此窗口。此前仅批准了 FarPane 的安装以及一次 native 30 秒观察，不包含这次 RustDesk 操作。
