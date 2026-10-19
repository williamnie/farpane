# FarPane Linux GPU 媒体重构（linux-host）：原版输入短时对照窗口

状态：2026-10-19 用户明确批准本轮临时启停原版并恢复 FarPane；两组 30 秒采集与恢复均已完成。原版临时窗口为北京时间 **10:08:14–10:11:33**。FarPane `.8` 核心的中文缺陷仍未修复，没有安装新修复包。下文执行清单为本轮准备记录，不代表后续可自行重开窗口。

## 恢复后的客户端开关对照

用户重新连接 FarPane 后确认“Ubuntu 中文兼容输入”菜单可点击、未勾选；原版 B 时状态“不确定，没有看”。随后只勾选现有开关，用户反馈 Chrome 与 Warp 中文输入均正常。期间没有换包、切服务、新增按键采集或修改应用快捷键；服务复查仍为 FarPane root1604687 active / NRestarts0，原版 inactive。

只读 Mac 源码显示，兼容模式在非 ASCII `sendText` 成功后额外发送 Ctrl+Shift+V，并按设备 UUID 保存偏好。此行为与 B 中额外 Shift/Ctrl 形态吻合；但没有观察普通 V，原版开关未知，Mac 二进制未验证，因此只是来源解释的证据，不能反推原版 Shift+Insert 必然失败。用户本次验证了当前连接的可用性，没有专门覆盖连续提交、重复文字、重连后设置持久化。默认关闭仍失败，长期输入方案继续待讨论；不恢复暂停的应用名特判。用户结果、源码假设及边界分别保存在 `compatibility-toggle-user-result.json` 和 `mac-source-hypothesis.json`，已通过 OCS seq38 同步 Claude。

## 本次实测与恢复

用户先确认 FarPane 下“没中文，但是有空格”，切到原版 ID 26140219 后，在同一个 Mac 客户端、同一 Ubuntu Chrome 输入框报告“中文正常出现”。

| 观察项 | A：FarPane `.8` | B：原版 RustDesk |
| --- | --- | --- |
| 核心 | c403acbf | b7908e55 |
| 设备 | event7，root 1497504 | event6，root 1597708 |
| 白名单事件 | 6 个 | 16 个 |
| Shift-down / Insert-down / Insert-up / Shift-up | 1 组，66µs | 2 组，57/81µs |
| 紧随其后的 Shift-down / Ctrl-down / Shift-up / Ctrl-up | 无 | 每组均有，距前组开始 20.603/20.602ms |
| 初始/最终九键状态、采集结果 | 全松开；exit 0、无丢帧 | 全松开；exit 0、无丢帧 |

A 另有一组约 1.546 秒后的单独 Shift 按下/抬起。B 的两轮相隔约 19.432 秒。只采集了九个白名单键，没有普通字母键，因此不能把额外修饰键直接命名为 Ctrl+Shift+V 或认定其因果作用。它至少推翻了“成功原版与 FarPane 的九键形态相同”的推断，已通过 OCS seq34 交给 Claude 优先追查来源。

A 固定日志阶段有一次非 ASCII 提交，chars=2、released_modifiers=0，之后 clipboard written → ready → queued。B 两条 `clipboard updated on host` 出现在 UTC 02:10:02 / 02:10:10，晚于 B 采集结束 02:09:43，不能与窗口内成功提交关联。原版时间戳在时区前含空格，首次解析未兼容；修正后重新提取，空的窗口内阶段结果不作为“原版没有对应调用”的证据。

恢复后 FarPane root **1604687**、Host **1604822**；release、core/GUI SHA 均与窗口前一致，原版 inactive，两项开机策略仍 disabled。新 Host 只读活动接口正常，检查时尚无重新连接，不能据此声称恢复后已完成远程画面验收。没有采集任务遗留。

原版启动过程中，窗口前的 GUI 1360261 已退出，另起 `--no-server` GUI 1598067；还生成 sudo 辅助进程及本次 `--cm`。初次恢复检查因这两种未列入角色的进程拒绝执行宽泛 ExecStop。随后核对具体 PID、start ticks、UID、exe、辅助进程父链及 GUI scope，确定均为本次原版启动范围、没有无关匹配后，按用户授权的原版停止流程结束它们。**没有保留原版 GUI 进程**，不能称整轮原版界面未受影响；服务单元、配置、ID、密码和显示设置均未由本任务修改。

准备元数据脚本最初误假设 GUI 位于 `bin/`，在开始采集前失败；依据 manifest 改为根目录 `farpane` 后继续，保留此记录。原始过滤事件、用户反馈、日志阶段、失败保护与恢复校验见 [实机证据](../../Evidence/LinuxHost/2026-10-19-original-input-ab/README.md)。

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

服务切换与原版按键观察必须由用户批准具体窗口。本轮已批准并完成；再次执行仍须取得新的窗口授权。
