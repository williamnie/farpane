# FarPane Linux GPU 媒体重构（linux-host）：Mac 式中文消息对照

2026-10-18 UTC，分支 `codex/linux-host-gpu-media`，HEAD `0b7381291f84637cb5eea557a498aced16ed5dd4` 加保留的未提交改动。本轮新增测试和文档，未改产品、编译、打包、安装或操作用户桌面。

## 结果

同一测试脚本、systemd/logind/GNOME、内核、VKMS 和用户会话设置，分别运行原始 `.1` 与 `.3` bundle。准备阶段逐项校验 bundle；三组旧/新对照的 guest 脚本、systemd 单元、镜像和协议参考哈希均相同。实际经过密码认证 TCP→Host→特权 IPC→root uinput→GNOME Wayland 目标，无输入后端替身。

| 目标 | `.1` 普通整段中文 | `.1` Control 残留 | `.3` 三种提交 |
| --- | --- | --- | --- |
| GTK4 Entry | 正确 | 有焦点、剪贴板更新，文字未增加，Control 仍按下 | 全部正确，Control 先释放 |
| VTE PTY | 正确 | 文字仍能粘贴，但 Control 未释放，状态检查失败 | 全部正确，Control 先释放 |
| Chrome 155 | 正确 | 有焦点，文字未增加，Control 仍按下 | 全部正确，Control 先释放 |

三种提交依次是“中文测试”、“控制提交”、以及“混合A1，🙂é”。第二次先通过真实协议按下 Control，再以 EVIOCGKEY 确认 guest 内核按下状态；候选必须先产生 Control-up，再产生唯一一组 Shift-down/Insert-down/Insert-up/Shift-up。每次核对精确内容、焦点、无重复；补发迟到的物理 Control-up 后也不重复。最终三目标均得到 `中文测试控制提交混合A1，🙂é`。

VTE 的旧版并非“没有中文”，本记录不把它改写为与 GTK/Chrome 相同的失败。三项 baseline runner 都保留 exit 1：GTK/Chrome 因文字未到超时，VTE 因 `Literal Seq left Control pressed` 断言失败。测试没有为旧版改成相反的通过条件。

## 消息和隔离范围

协议测试端模仿仓库中的 Mac `rdn_client_send_text → session.input_string`：只设置 `KeyEvent.seq`，down=false、press=false、Legacy、modifiers 为空，不另发剪贴板同步。中文整段的消息字节是 `7a0e320ce4b8ade69687e6b58be8af95`。固定源码参考见 `wire-reference-sources.json` 与 canonical `native-input-vm.lock.json`；准备 wire guest 时核对哈希。

测试端声明 Mac OS / 1.5.0，按上游无公钥 IP 直连流程连接 guest loopback。先验证错误密码被拒，再以合成固定密码成功认证，收到实际软件视频后才发送输入。它不是 Mac 二进制、输入法、ID/中继或加密握手测试。目标文本由应用本身报告，VTE 读独立 PTY，Chrome 使用空 profile 和 guest 合成页面；没有直接写入文字或剪贴板。

QEMU 只暴露 `/dev/kvm`，没有网卡、宿主输入/GPU/桌面/总线/服务 socket。VKMS、root 服务和键盘都在独立 guest 内核。4 vCPU、6 GiB guest RAM、10 GiB 容器上限、180 秒期限；测试与磁盘准备顺序执行。Chrome 程序清单与上轮相同，仍是无外网/无 GPU、`--no-sandbox` 的测试配置，不是浏览器沙箱验收。

## 原始记录

- `runs/wire-entry/`：初次协议连接已认证并收到视频，但 GNOME 概览焦点未准备成功，未发送中文。增加与 GUI profile 相同的远端点击后继续。
- `runs/wire-entry-2/`：首次候选 Entry 三种消息成功。其失败日志保存方式随后补充，最终对照使用下列同版脚本。
- `runs/wire-baseline-entry/`、`wire-baseline-terminal/`、`wire-baseline-browser/`：原始 `.1` 三个对照，均按上述原因失败。
- `runs/wire-entry-final/`、`wire-terminal/`、`wire-browser/`：原始 `.3` 三目标全部通过。
- `summary.json`：逐目标差异、脚本一致性、两个原始 core 的 SHA-256 及未改动 Deb 哈希。
- `wire-guards-final.log`：8 项入口防误执行通过，包括网络连接和 evdev 打开前拒绝普通宿主环境。
- `wire-unit-final.log`：3 项协议测试通过，覆盖 Seq 默认字段/字节、帧长度边界、截断与溢出拒绝。

每轮包含完整串口日志、runner 结果、QEMU 参数、磁盘准备元数据及独立提取的 network-input/entry JSON。失败时外层 `native_desktop.input_text_sent=false` 仍是启动阶段的初值；实际已提交的文本和事件以 network-input 的 cases、目标状态及内核记录为准，不据该初值声称未执行输入。`sources/` 保存最终 canonical 测试快照，旧诊断轮的源码哈希保留在各自 disk.json 中。

## 仍未验收

这证实 `0043` 的修饰键修正适用于生产网络/内核路径，但未观察用户实际失败瞬间的按键状态，不能宣称唯一根因。真实 Mac 输入法、Warp、Mac 灰色兼容菜单和维护窗口验收仍待完成；当前安装 `.1` 不因此变为已修好。

只读检查见 `installed-read-only.json` 和 `installed-activity-wire.json`：当前 release 仍是 `bfc1befc…`，root PID 64215、Host PID 70886，一条已认证入站、零待审批。file_jobs=1 是 CM owner，media_owners=2，busy_count=4 不是四条连接。FarPane active/disabled，RustDesk inactive/disabled。未 stage/activate、提交或推送。

`.3` Deb SHA-256 仍为 `476f189cac60495be8b54fad2e0c8070bf904cdfa3420af7af1baa72f68bea64`，无需为新增测试重编应用或 FFmpeg。新增测试不在此前冻结源码归档内；应用源码保持一致。复现入口见 [Linux 文档](../../../Linux/docs/native-input-vm.md#mac-式-seq-与旧版对照)。
