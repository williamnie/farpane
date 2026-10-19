# FarPane Linux GPU 媒体重构（linux-host）：以原版输入路径为基准

2026-10-19（北京时间）。用户明确提供对照：同一个 FarPane Mac 客户端，连接同一台 linux-host 的原版 RustDesk，在同一个应用中可以直接输入中文；连接 FarPane 则失败。另一次 FarPane 测试在提交后手动 Control+V 可以贴出中文。

这要求先检查 Linux 重构相对已工作路径的差异。暂停“默认换 Ctrl+Shift+V / 每设备快捷键设置”的二选一，不把应用名特判、让用户选择快捷键或修改应用绑定作为当前修复方案。输入核心仍由 `claude-08da8438` 负责；Codex 本轮只读核对安装来源、冻结源码与运行元数据。未修改产品、启动构建或切换服务。

## 已核对的基准

- 本机包为 `rustdesk-unattended-wayland 1.5.0`。实际 Rust 核心在 `/usr/share/rustdesk/lib/librustdesk.so`，不是 Flutter launcher `/usr/share/rustdesk/rustdesk`。
- 核心 SHA-256 `b7908e555b0ad96f78b6398a470be0f0c9e07f3ccedb8acfb9ee565c63312896` 与此前只读实验 manifest 的 `original_library_sha256` 相同，原始核心仍保留。这个匹配证明基准文件身份，不单独证明二进制的每一项编译来源。
- FarPane 当前 release `9a76a6c2af66e3955470ea24`、GUI `0.1.0-dev.20261019.1`、`.8` 核心 `c403acbf…`。比较使用 `.8` 编译副本 `Build/Linux/core-updates/run-0q_7wu96/rustdesk`；活动 checkout 含暂停的 0044，不能把它当作已安装代码。
- 上游比较对象从只读 Git 对象 `fada664df7a294d1d1a9ca3e7cd3637069122f17` 导出。`Build/Linux/src/rustdesk` 本身没有 Git 仓库，不能在其中运行 `git rev-parse HEAD` 后把外层 FarPane HEAD 当成 RustDesk pin。

## 源码对比结果

以下行号针对上游 pin 的 `src/server/input_service.rs`：

| 位置 | 原版基线行为 | 当前比较结果 |
| --- | --- | --- |
| `process_seq`，1919 | Wayland + uinput 时，ASCII 走键序列，非 ASCII 整段走剪贴板 | `.8` 保留分支，新增 0045 修饰键准备与诊断 |
| `input_text_via_clipboard_server`，2081 | Shift-down、Insert-down、Insert-up、Shift-up | `.8` 保留同一按键顺序，新增 0043 清理与日志；没有 0044 |
| `wayland_use_uinput`，2558 | `!is_x11() && is_server()` | 判定函数未变，但 native Host 的进程角色和发现初始化与 Flutter 启动路径不同 |
| `wayland_use_rdp_input`，2564 | `!is_x11() && !is_server()` | 需要确认用户原版成功连接究竟走哪一分支 |
| `libs/enigo/src/linux/nix_impl.rs` | X11/custom keyboard 分发 | 与 `.8` 源码字节相同 |
| `src/server/rdp_input.rs` | Portal 输入；非 ASCII 也有剪贴板路径 | 与 `.8` 源码字节相同；不能假设 Portal 不使用粘贴 |
| `src/server/uinput.rs` | IPC → 虚拟键盘映射及发出事件 | 映射/emit 主体未改；native 新增会话授权检查、传输超时/重连及状态查询 |

因此“换一个粘贴快捷键”尚不能解释回归。优先比较原版成功连接与 FarPane 的**后端选择、进程初始化、事件含义与实际传输**，再决定最小修正。0036 的 `guarded_input`、0037 的有界传输、0043/0045 的修饰键，以及 native 会话发现是差异清单，不是已确定根因。

## 运行证据的边界

观察时原版只有 GUI 进程，FarPane 有 `--server` Host；原版 GUI 环境是 DISPLAY `:0`，FarPane Host 是 `unix:/tmp/.X11-unix/X1`，二者均标识 Wayland。这些当前状态不能反推用户成功测试时的状态，更不能据此重改 DISPLAY。

原版历史日志同时包含 GUI 的 Portal 阶段和 server 的 UInput keyboard created 阶段；目前尚未与用户那次成功提交对应。只导出预设阶段的计数/时间，不导出日志正文、按键或剪贴板内容。需要先建立成功会话与后端的可靠对应；如果必须重新启动原版做真实 A/B，应先准备具体对照步骤并按既定维护窗口边界取得授权。

Control+V 成功说明这次中文已经送到 Ubuntu 且目标可读取。它不能区分自动按键没有正确送达，还是应用收到后没有执行，也不能证明 Mac 所有事件在两条连接中完全一样。仍未确认根因、没有新修复包、不宣称已恢复中文。

原始差异及哈希见 [2026-10-19-native-upstream-input](../../Evidence/LinuxHost/2026-10-19-native-upstream-input/README.md)。旧实验目录、原版 RustDesk、显示模式、Mac 源码和当前 FarPane 会话均保持原状。

## 首次内核观察后的复核（2026-10-19）

用户批准的 30 秒观察已结束，[五组完整 Shift/Insert](native-paste-key-observer.md)进入 FarPane 自己的虚拟键盘事件流，用户仍无中文。该窗口没有 Ctrl/Alt/Meta 事件，初始九键均松开；它只覆盖这一设备，不能推断整个 seat 的修饰键、焦点、输入法或应用消费状态。因此不能把“按键发送侧完全排除”作为结论，也不根据微秒级跨度添加等待。

`.8` 的 `src/clipboard.rs:457` 先写 CLIPBOARD，失败会向上传播；成功后再写 PRIMARY，后者失败仅记录警告，仍返回成功。`set_text_clipboard_with_owner_sync` 直接返回此结果。因此 `clipboard written` 不能单独证明 PRIMARY 成功，更不能证明目标已读取。这修正了此前“同时写两个选区”的简写，但还不是 PRIMARY 导致故障的证据。Chromium 具体入口的快捷键与 selection 映射仍没有在对应源码上核实，不以记忆判断。

01:50 UTC 的只读 `/proc` 元数据确认：同一 Xwayland PID 3858（display `:0`）持有公共 X0 的 `-listenfd 4/5` 和文件系统 X1 的 `-initfd 7`；abstract X1 监听者是 gnome-shell PID 2262。两条地址不是两个独立 X server，但连接入口确实不同；这个事实既不能证明语义相同，也不能证明它导致回归。不得把 `unix:/tmp/.X11-unix/X1` 自动替换为 `:1`。

Claude 的原版服务 A/B 建议尚未执行。切换两套程序会同时改变后端、进程初始化、输入设备和剪贴板上下文；即便九键形态相同而原版成功，也只能缩小范围，不能直接锁定 clipboard owner 或 DISPLAY。原版成功会话仍应核对实际后端；若不是 uinput，不能把“未观察到事件”当成丢键。目前观察器只验证 FarPane 的服务和已认证 Host，不能直接传入原版 PID 绕过身份检查。

本轮仅保存源码片段、哈希、X11 socket 元数据与服务状态，没有读取剪贴板、重新捕获按键、改产品或切服务。FarPane 的正确单元为 `farpane.service`，active / PID 1497504 / NRestarts 0；RustDesk inactive。初次误查 `farpane-native.service` 的空单元结果已丢弃。证据位于上述目录的 `post-capture-review/`。下一步先由输入核心负责人继续核对原版启动/后端差异，并评估隔离环境对照；宿主原版服务 A/B 仍须准备工具、恢复步骤并取得明确窗口授权。

## 剪贴板同步竞争假设的前置核对

OCS seq27 提出 Mac 的 Clipboard 消息可能在 Seq 写入与应用粘贴之间覆盖选区。这仍是假设。seq28 已安排 Claude 在现有隔离 VM 补测，不修改产品或宿主；覆盖无同步、提交前、提交后、前后都有，并区分空值和不同非空合成内容。发送时序只能称模拟，不能称已复现真实 Mac 时序；必须先证明消息被允许且实际写入。

对 `.8` 冻结源码的只读核对发现：

- 本轮开始读取的 wire 测试登录带 `number(8,2)`，在 pin 协议中是 `disable_clipboard=Yes`。既有四例没有覆盖入站剪贴板同步，不能用于排除这类竞争。
- Host 的 `--server` 启动 `host_clipboard`，不依赖首页是否有 Viewer。接入补丁是 `0029-native-host-clipboard.patch`；`0040` 修改解码和大 buffer 释放，不能把整个 Host 剪贴板替换归到它。
- native `connection.rs` 不订阅旧 `clipboard_service`；已授权入站 Clipboard/MultiClipboards 经权限检查进入 `Link.receive`，由独立 worker 写入。原版 `clipboard updated on host` 位于旧 `do_update_clipboard_`，不能拿这条日志在 native 中缺失当成“没收到同步”。
- Wayland 下同步 worker 仅选原生 data-control，要求 `ext_data_control_manager_v1` 或 `zwlr_data_control_manager_v1`；缺少能力会失败，不回退 X11。这与 Seq 的 arboard 路径不同。尚未在本轮测量实际 Host 的能力；VM 和实机都须验证后端条件，不能只发包后观察“没有变化”。
- wire 解码拒绝原始空正文和解压后的空正文；Reader 会忽略含 `application/x-farpane-clipboard` 或 `dyn.com.rustdesk.owner` 的 offer。这些保护存在于冻结源码，但尚未证明真实桌面上的完整行为。

以上发现经 seq29 补充给 Claude，证据为 `post-capture-review/native-clipboard-source-review.json`。五个 clipboard canonical 文件与 `.8` 副本一致；`mod.rs` 含其他草稿差异，本轮依据冻结副本核对 Host 启动。没有修改产品，没有启动实机 owner/正文采集。只读 MIME/owner 变化不能单独确定覆盖来自 Mac；即使人工插入晚到消息能覆盖，也还需与原版语义和真实失败时序对应，不能据此宣称根因已确认。

后续结果（OCS seq30/32）：VM `run.q2tpaj1z` 开启接收后的正控制仍贴出 Seq 基线，未应用对端 Clipboard；五种顺序只出现提交内容。判为覆盖前提未成立，不能把 outer pass 计为竞争测试通过。实机 arboard 三次初始化报告无 ext/wlr data-control，属于当时该库的探测结果，不直接证明 native worker 当前能力。测试证据在 `2026-10-19-native-input-fix/clipboard-sync-vm/`。已准备[原版短时对照窗口](original-input-ab-window.md)与受限观察入口；尚未授权或执行服务切换。

最新实机 A/B 已在随后取得的明确授权下完成并恢复：FarPane 无中文、有空格；原版同一 Chrome 能显示中文。原版实际绑定其 root uinput 设备，不再只依赖历史日志推测后端。原版两组 Shift/Insert 后均多出约 20.6ms 后的 Shift-down / Ctrl-down / Shift-up / Ctrl-up，而 FarPane 没有；两边均无丢帧。普通字母键未采集，额外序列来源和因果作用仍待追查，不直接改快捷键。B 的两次 clipboard updated 日志晚于捕获窗口，不与成功提交强行关联。详细时间、实际进程/GUI 生命周期与恢复验证见上述窗口文档及 `2026-10-19-original-input-ab/real-capture/`。没有安装新包，FarPane 已恢复 root1604687/Host1604822，原版 inactive。

后续只读 Mac 源码与用户开关对照（OCS seq35–38）：仓库的兼容模式在非 ASCII `sendText` 成功后补发 Ctrl+Shift+V，偏好按设备 UUID 保存。用户确认恢复后的 FarPane 开关可用、未勾选，原版 B 时状态不确定；仅勾选后，用户确认 Chrome 与 Warp 中文均正常。此时同一 FarPane 核心和服务未换，证明当前兼容路径可用，不能继续把两边客户端发包相同当成前提。原版实际开关、普通 V 和 Mac 二进制未验证，不能断言 B 成功完全由兼容补发造成，也不能宣称默认模式已修复。未做连续提交、重复或重连持久化专门验收。本轮只保存结果并交接，不修改 Mac/Linux 产品、不重开服务或输入采集窗口，暂停的 `0044` 不恢复。
