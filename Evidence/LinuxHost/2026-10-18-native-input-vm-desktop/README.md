# FarPane Linux GPU 媒体重构（linux-host）：真实 GNOME 私有输入回归

2026-10-18 UTC，分支 `codex/linux-host-gpu-media`，HEAD `0b7381291f84637cb5eea557a498aced16ed5dd4` 加保留的未提交改动。用户要求离开期间无人值守推进。本轮不改产品、不编译或打包应用、不安装候选、不操作宿主桌面或 RustDesk。

## 最终结果

同一原始 `.3` 候选 `farpane-native-dev-d393fd0cff634416807feae5`，真实 GTK GUI→认证 TCP→Host→特权 IPC→root uinput→GNOME Wayland 应用的三项检查通过：

| 目标 | 原始记录 | 实际内容 | 内核事件 |
| --- | --- | --- | --- |
| VTE 独立 PTY | `runs/desktop-terminal-4/` | 中文测试 | 72 条，无 SYN_DROPPED |
| Chrome 155.0.8059.84 输入框 | `runs/desktop-browser/` | 中文测试 | 72 条，无 SYN_DROPPED |
| GTK4 Entry | `runs/desktop-entry-final/` | 中文测试 | 72 条，无 SYN_DROPPED |

每项包含四次完整 Shift-down/Insert-down/Insert-up/Shift-up，其他事件为焦点 Alt+Tab、输入法前缀修饰键及 SYN。逐字提交后目标内容与预期完全一致，延后再读无重复。VTE 读的是 PTY 输入字节，不是终端截图；Chrome 读合成页面的 input.value。三项都使用产品网络发送远端焦点键和中文，没有直接写目标文本或剪贴板。`summary.json` 为汇总，原始结果和完整串口日志在对应目录。

Guest 运行真实 systemd 259.5、PAM、logind、GNOME/Mutter 50.1。真实 loginctl 返回 UID 1000、seat0、Active=yes、Type=wayland、Class=user；GNOME 确实持有产品 evdev FD。产品的原有 DRM CPU 捕获及 VP9 软件媒体完成实际画面呈现。本轮未测试宿主 GPU。

独立内核 boot ID 已与宿主区分。QEMU 只暴露 `/dev/kvm`，无网卡、宿主 GPU/input/显示/总线/服务 socket；4 vCPU、6 GiB guest RAM、10 GiB 容器上限、180 秒期限。VKMS 模块是锁定的公开程序文件，仅复制并加载到 guest。Chrome 仅复制锁定的 255 项程序文件/链接，使用空 profile、无外网、无 GPU 的私有页面，沿用 `--no-sandbox` 测试参数；不把该结果称为浏览器安全验收。清空 capabilities 和 NoNewPrivileges 仅用于 guest 用户会话。

## 保留的失败与修正

- `desktop-run-2`：Linux 7 VKMS 改为 faux bus，旧 module symlink 断言错误；改为核对实际设备/驱动路径。
- `desktop-run-3`：GNOME 默认 udev 规则主动忽略 VKMS，未启动桌面。
- `desktop-run-4`：后置 TAG-= 未解决忽略问题；快速关机截断串口 JSON，runner 解析失败。改为 guest 内只删除两条确切 VKMS ignore 规则并等待串口发送；后续再改为 systemd 正常关机，避免写盘中直接 poweroff。
- `desktop-run-5`：真实 GNOME/logind 与产品键盘设备消费通过，只测启动，未发送文本。
- `desktop-run-6`：GUI 实际已呈现 208 帧，但事件驱动 progress 文件仍是首帧前状态，测试等待条件误判。改用只有绘制后才写出的 input-targets 标记；未修改产品。
- `desktop-run-7`：首个完整网络/内核/GTK4 单字“中”通过；它不是最后的四字矩阵。
- `desktop-terminal`、`desktop-terminal-2`：VTE 图标加载器退出，诊断得到 bwrap “Unexpected capabilities but not setuid”。限定 guest 用户会话 capabilities 为空、NoNewPrivileges=yes 后，bwrap 返回 0 且 VTE 正常。未禁用宿主策略。
- `desktop-terminal-3`：PTY 已有“中文测试”，但观察器未及时读取产生 SYN_DROPPED，未判通过。改为每个客户端键事件后排空，并显式拒绝丢事件，最终三个目标均完整读回。
- `desktop-network-guards.log`：首次 unittest 模块路径调用不正确而 ImportError；使用脚本入口后通过。最终 `desktop-guards-complete.log` 六项保护通过，普通宿主执行在挂载、设备打开、启动 GUI/服务或关机前拒绝。

`sources/` 是最终 canonical 测试源码快照；早期失败版本由各 `disk.json` 的测试哈希绑定，原始生成磁盘在 Build 保留。所有 raw 结果保持原样，不能把早期失败的测试哈希当成最终源码哈希。

## 未验收与实机边界

Linux GTK 逐字 Seq 不等于 Mac `input_string` 的多字单次 Seq，也没有替代真实 Mac 输入法。残留修饰键在完整网络/内核路径中的修正前后对照、Warp、Mac mini→linux-host 用户验收、首页内存及完整 GUI 发布矩阵仍未关闭。本轮私有回归不证明当前安装版已修复。

只读检查确认 `/opt/farpane/current` 仍是 `.1` 的 `bfc1befc…`，root PID 64215、Host PID 70886；一条已认证入站，待审批 0。观察接口 file_jobs=1 为 CM owner 计数，media_owners=2；busy_count=4 不能解释为四条连接或四个文件传输。FarPane active/disabled，RustDesk inactive/disabled。详情见 `installed-read-only.json`、`installed-activity-desktop.json`。未提交、推送、stage/activate 或重建 FFmpeg。

复现命令与范围见 [Linux 文档](../../../Linux/docs/native-input-vm.md)。新增测试尚未进入此前冻结的 `.3` 源码归档；应用源码与该归档保持一致。
