# FarPane Linux GPU 媒体重构（linux-host）：中文输入交给 Claude 修复

2026-10-19，北京时间。用户在真实测试后明确要求：“你收集完成日志，直接给claude，让他去修吧”。接收者为新线程 `claude-08da8438`（ocs 名称 farpane，session farpane-96），不是旧 `claude-288b5f14`。本 Codex 线程已停止采集与产品开发；由该 Claude 线程继续修复，避免两个 owner 同时写产品。

## 本次真实反馈与证据

- 用户报告 Mac mini FarPane“关于”为 **v2.0.8**；尚未读取实际 Mac 二进制，勿擅自改写为 v0.2.8。
- 操作：连接 ID 1000000000，在 Ubuntu Chrome 输入框先输入 `abc`，再经 Mac 输入法选字提交 `中文测试`，不复制粘贴、不按回车。
- 用户反馈原文：**“英文正常，中文没有”**。Warp 和 Chrome 先前都失败；当前灰色兼容菜单也未解决。
- 当前安装仍为 `.20261018.1`，release `farpane-native-dev-bfc1befc221061266d5f50da`。本次核对 root PID 64215、Host PID 1362864，同一核心 SHA-256 `bd6d8c376299fe8c5313daa06d79a1820ebfe2f9f9ef32d06b758bccfae259e3`。
- 采集于北京时间 08:12:51 左右开始，观察约五分钟后按用户交接要求结束，采集进程退出 0。它不是服务进程；FarPane 会话和服务没有停止。
- 150.635 秒处入站从 0 变为 1；154.149、167.197、170.208 秒出现共 **4 次 `UInputKeyboard::key_sequence` 调用日志**。规则覆盖的剪贴板写入失败、输入传输丢弃和状态查询失败没有匹配记录。
- 对既有日志做一次仅长度的补充核对：四次 UTF-8 字节数依次为 1、1、3、1。没有保存正文或正文哈希。**不能据长度认定其中哪次是英文或中文，更不能说已观测到 CJK Seq。**
- `NativeActivity` 的 `file_jobs=1` 是 CM owner、`media_owners=2` 是所有者计数；不表示用户传了文件或有四条连接。

完整白名单分类日志、测试来源和终态见 `Evidence/LinuxHost/2026-10-19-native-input-handoff/`，原采集在 `Build/Linux/native-input-observer/capture-4m7rfq1h/`。采集器 canonical 是 `Scripts/linux/observe-native-input.py`，8 项测试通过；没有开启 TRACE、抓普通按键、读剪贴板或操作应用窗口。原始产品日志没有整份复制到证据。

## 证据限制与实现状态

本轮只读采集，**没有编写/构建/安装完整诊断核心，没有修复产品**。`.1` 不记录完整的非 ASCII Seq 收取、剪贴板成功和内核注入，不能从无错误推断文字已经抵达 Linux 或应用。下一步由 Claude 决定补齐这些阶段观测或使用有依据的候选作受控验证；不要再把 VM、IPC 入队或剪贴板成功叫作真实中文验收。

关键候选区别：

| 候选 | 状态与区别 |
| --- | --- |
| `.1` / `bfc1befc…` | 实机运行；包含 DISPLAY 地址修正，不含 0043 修饰键修正 |
| `.2` / `67f5d1594e8961809614f4e1` | 已构建、之前 stage/plan，未激活；GUI 与 `.1` 相同；源码差异仅依赖 pin、输入测试、0042、0043；core SHA `26147ece6e48ce42ae550f0452809227bf7c54ce8a659218a97d80456c424661` |
| `.3` / `d393fd0cff634416807feae5` | 保留 0043，另修 Viewer 屏幕选择提示；实际网络→root uinput→GNOME 的旧/新对照已通过；core SHA `c57fc5dd5755c2caf6e7780d5bf2cc33459b1629949079d2d9eedb17fcf62f6b` |
| `.7` / `58e533b081afae50b9c8e8a5` | 最新 GUI 候选，复用 `.3` 核心，未安装；不含 0044 |

`0043` 已包含两条无正文 DEBUG 标记：`Native committed text: clipboard ready; preparing paste` 与 `Native committed text: paste key sequence queued`。本轮没有把这两条接入采集器，因为当前 `.1` 没有它们。后者仅表示入队，不是内核或应用确认。没有进行新的 stage、plan 或 activate。

## 已与你讨论的设计约束

先读 `Linux/docs/chinese-input.md` 顶部两轮 OCS 评审及 `Evidence/LinuxHost/2026-10-19-native-input-review/`。既有 DM 的 seq 8/10 是你的评审与修正，seq 9 是本线程提出的四项边界。

- 字面文字提交与物理按键/热键分开；不要按应用名猜粘贴快捷键。
- DISPLAY 修正及 0043 的通用语义有证据，不能一概撤销。ASCII Seq 的修饰键覆盖仍需研究，不可破坏 Translate 热键。
- `0044-native-warp-paste-shortcut.patch`、`paste_target.rs` 及其接入仍是用户暂停的草稿。**活动 dependencies.lock.json / native/mod.rs / 生成 checkout 已混有它；不要直接从活动树构建或删除他人改动。** 从冻结来源派生，canonical 补丁/pin 留在 Linux/，产物在 Build/。
- IBus 只是未验证研究候选；不能承诺跨应用、跨桌面可用或暗中切用户输入源。
- SelectionRequest/Wayland send 不是应用消费确认，禁止据此自动补发；读取缺失也不能单独证明未消费。
- 状态查询失败不能当作 false 后盲目释放八个键；区分查询错误与确实未按下，只处理自身输入设备，保持失败动作不重放。
- Mac 兼容开关额外发 Ctrl+Shift+V，可能与 Host 粘贴叠加；不要求用户改 Warp 键位或反复找灰色菜单。

## 继续工作的边界

工作区 `/home/user/farpane`，分支必须为 `codex/linux-host-gpu-media`，当前 HEAD `0b7381291f84637cb5eea557a498aced16ed5dd4`。全部未提交工作保留。此次用户已授权 Claude 接手实现、测试和准备候选，不再局限于只读评审；未授权新一次服务替换/桌面操作、Mac 文件写入、commit/push/deploy。需要服务切换时先把候选准备具体再确认维护窗口。

不操作 RustDesk 服务/进程/配置/ID/密钥，不改显示模式、不切桌面、不安装宿主 FFmpeg/写 `/usr`，不改 Mac 或 xuanwu，不唤醒旧线程、不增代理/定时任务。FFmpeg 9.0.2 已构建，不无故重建；约 4 核/12 GiB，复用隔离镜像和缓存。GPU 仅限定 render 节点、单路低负载，当前有真实用户连接。用户接受目前内存，停止内存优化。

本轮尚未确认故障根因，不能向用户声称已修好。后续请直接由 Claude 向用户报告修复进度，本 Codex 不并行修改产品。
