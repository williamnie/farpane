# FarPane Linux GPU 媒体重构（linux-host）：中文输入修复候选 `.8`

2026-10-19 UTC，由 `claude-08da8438` 接手实现。分支 `codex/linux-host-gpu-media`，HEAD `0b7381291f84637cb5eea557a498aced16ed5dd4` 加保留的未提交工作。没有安装或切换服务，也没有提交或推送；Mac 和暂停中的 `0044` 均未改动。

## 实机日志提供的新线索

交接采集期间，当前安装 `.1`（Host 进程）的产品日志里，`ClipboardContext` 只初始化过一次（arboard 的 “wayland data control … failed, falling back to X11” 警告），时间是 17:15:29 -07:00。这次初始化发生在用户先输入 `abc` 之后、提交中文的时间段内，此前和此后都没有再出现。剪贴板写入路径和“从 Mac 收到剪贴板”路径共用这个上下文，所以它只能**支持“中文 Seq 进入了剪贴板路径且写入未报错”**，不能单独证明，也看不到当时的修饰键状态。`.1` 没有 0043，也没有本轮新增的阶段日志。只读查看了日志模板和源码位置，没有输出正文、ID 或地址。

## 产品改动：`Linux/patches/0045-native-committed-text-state.patch`

对“字面文字”的盘点，也就是哪些消息是已经提交的文字：
- Legacy Seq：Mac 的 `input_string`，原生 Wayland/uinput 路径，包括纯 ASCII 分支和剪贴板分支。本补丁覆盖这两个分支。
- Legacy Unicode 的非 ASCII 分支、Translate Seq 的非热键分支：仍由 0043 在剪贴板函数中清理，行为不变。
- Legacy Chr 的热键分支、Translate Seq 的热键分支：保持原有的快捷键语义，不做中立处理。

具体改动：
1. `process_seq` 在 Wayland uinput 分支入口调用 `native_literal_text::prepare`：先查询 Ctrl、Alt、Meta 三项，全部查完后再统一释放（左右键成对释放；对未按下的键发 up，会被内核输入核心丢弃）。纯 ASCII 提交也会先释放，修复了“Control 残留时 `abc` 变成 Ctrl+A/B/C”的问题。
2. 状态查询改用新增的 `UInputKeyboard::try_key_state`，IPC 失败时返回错误，不再当作“未按下”。只要有一项查询失败，本次提交就整体丢弃：不改任何按键、不写剪贴板、不发快捷键，并记录 warn；不重放。root 端 EVIOCGKEY 失败时仍会回答 false，这是剩余的已知限制。
3. 无正文的阶段日志：`Native committed text #N: chars= ascii= released_modifiers=0bMAC`（bit0 Ctrl、bit1 Alt、bit2 Meta）和 `Native paste clipboard written in N ms`，与 0043 已有的 `clipboard ready` / `paste key sequence queued` 一起使用。这些日志分不同调用点限流，所以一次释放不会被并入普通提交的计数。“已入队”和“剪贴板已写入”都不等于目标应用已经消费。

不按应用名特判，不改动粘贴快捷键（仍为 Shift+Insert），也不加入 Mac 侧的补发粘贴。补丁的各个 hunk 与 0044 不重叠，因此在 `.3` 基线和含 0044 的活动树上都能 apply。

## 构建与打包（从冻结来源派生）

- `Scripts/linux/build-native-core-update.py`：复制生成的 checkout，在副本中反向撤掉父包之后的补丁（0045、0044），恢复父包的 overlay（53 项哈希全部一致），只应用所选的 0045。离线、locked，target 使用独立缓存 `Build/Linux/core-update-target`；活动 checkout 和 `Build/Linux/target` 都不写入。最终运行 `core-updates/run-0q_7wu96`：
  - 单测 3（新增）+ 1（input_retry）+ 7（input_service，另有 1 项需私有桌面而 ignored），全部通过；
  - release 只重编了 3 个 crate，未重建 FFmpeg 和 GUI。
- `Scripts/linux/repackage-native-core.py`：以 `.7` 为父包（`58e533b081afae50b9c8e8a5`，GUI 与 `.7` 逐字节相同），只替换 `libexec/farpane-core`、lock 中的补丁列表和新增补丁文件，ELF NEEDED 不变。bundle 为 `farpane-native-dev-79e6fd6f2505d006beeb4e71`，core SHA-256 `c403acbf2caa5d49d531f1f8cff30ebc248605a0e852c8367d4b14f9eeb4ee01`。Cargo lock 未变，依赖许可材料原样沿用，**notice 源码映射没有重新绑定**（`build.json` 的 `core_update` 中记为未关闭项）。
- Deb：`Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.8_amd64.deb`，SHA-256 `ea15afb1ee5c621337a7db3bdcc880da1d71d8c97f88dc718dcdf9954f03bd0f`。Ubuntu 24.04 上 `.7 → .8` 的 dpkg 安装、升级、两次真实软件视频连接和 purge 全部通过（`deb-smoke-ubuntu2404.log`）。
- 第一轮候选 `cebb934373f856dc71fa5e51` 已经废弃：它的限流把“释放”日志并进了下一条记录。该轮回归通过的结果保留在 `runs/round1-candidate-browser`，对应的 Deb 已移到 `Build/Linux/retired/input-fix-20261019/`。

## 隔离回归（真实认证 TCP → Host → root uinput → GNOME，私有 KVM）

`Linux/tests/native_input_vm_wire.py` 新增第 4 个用例 `ascii-held-control`：在内核确认 Control 处于按下状态后，发送 Mac 式整段 Seq `abc`。要求先出现 Control-up，不出现粘贴组合键，目标文字准确且不重复。

| 运行 | 目标 | 结果 |
| --- | --- | --- |
| `runs/baseline-7-browser` | `.7`（= `.3` 核心）Chrome | 前三例通过，**`ascii-held-control` 超时：文字没有到达** |
| `runs/candidate-browser` | `.8` Chrome 155 | 四例全部通过 |
| `runs/candidate-entry` | `.8` GTK4 Entry | 四例全部通过 |
| `runs/candidate-terminal` | `.8` VTE PTY | 四例全部通过 |

四例都通过时，最终文字为 `中文测试控制提交混合A1，🙂éabc`。日志显示 `#2 … released_modifiers=0b001` 与 `#4 … ascii=true released_modifiers=0b001`。entry 运行的串口日志里没有出现 `#4` 这一行，但该用例的内核事件与文字核对都已通过，这里不把这一点当作日志证据。Python 侧协议与入口保护共 11 项通过。

## 仍未验收

这是协议等价的测试端，不是真实 Mac 应用。仍需维护窗口和真实 Mac→linux-host 实测，才能确认用户实机的根因与修复效果。安装 `.8` 后，新日志可以直接区分以下情况：中文 Seq 没有到达（没有 `#N` 行）、到达时修饰键残留（`0b001` 等）、剪贴板写入完成但应用没有显示。Warp 不接受 Shift+Insert 的问题不在本补丁范围内，仍待讨论；`.8` 不会让 Warp 中文变为可用。
