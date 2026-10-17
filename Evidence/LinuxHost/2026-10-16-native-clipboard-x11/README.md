# FarPane Linux GPU 媒体重构（hermes）：X11 有界剪贴板读写

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本检查点完成 X11 原生输出、事件驱动调度、GUI 原字节分块输出及最大字节 PNG 的实际双向连接验证。完整 GUI/安装包目标继续进行，`runtime_ready=false`。没有安装、提交、推送、修改现有服务或重建 FFmpeg。

Host 已替换 arboard 输出：在既有剪贴板线程提供 TARGETS/TIMESTAMP/MULTIPLE/INCR，PNG/SVG/文本保留原 Bytes，RGBA 按行有界编码。最多四路 INCR，单段 64 KiB，3 秒不活动/30 秒总期限；当前及在途旧 selection 正文共用 256 MiB 保留上限。取消的替换保留原内容；失去所有权后已开始的传输继续完成，新的本地内容释放当前引用。eventfd 与 X11 FD 驱动工作线程，无周期 payload 扫描。

GUI 原字节 ContentProvider 每次异步写最多 64 KiB，共用四个输出额度；每步 3 秒、总计 30 秒。超时后尚未返回的 GIO callback 保留额度和一段副本，不保留整个 memfd。不同 provider 正文保留最多 256 MiB；GDK 自身 stream 缓冲、RGBA 纹理和网络 buffer 另计，不是总进程内存上限。

| 验证 | 结果与范围 |
|---|---|
| 实际连接 | `runs/20261016T214813Z`，两轮各 22 项检查；GTK GUI → 独立 Viewer → 私有 TCP Host → 私有 Xvfb |
| 最大字节 PNG | 发送 134217728 字节、接收 134217727 字节，分别逐字节核对并记录 SHA-256；两种内容不同，未复用相同内容捷径 |
| 本机最终读取 | 修正夹具后，最终近 128 MiB GUI 输出分别约 117/111 ms；这只是本机粘贴读取时间，不是端到端延迟 |
| 权限与生命周期 | 文本/富文本/PNG/SVG、单向/分类撤权、失焦/恢复、卡住来源、16 次交替复制、真实 Host 撤权按钮、配置保持、控制通道无正文均回归 |
| 空闲调度 | 两轮全关后均为一个 Host 剪贴板线程，0.5 秒 CPU tick 增量为 0，新 selection 的内容请求为 0；不是整机/完整空闲性能验收 |
| Host provider | `provider/20261016T215028Z`：最大 INCR/哈希、RGBA 透明像素、原字节共享、四路限制、旧内容保留、死读者、保留额度、超时/恢复、TARGETS/TIMESTAMP/MULTIPLE 和失去所有权后完成；另附最大 reader 读取时间 |
| GUI provider | `logs/clipboard-writer-gui-provider-2.log`：实际 GIO 输出、四个无人读取的管道、第五个拒绝、超时取消和恢复；既有 RGBA→PNG 像素/格式测试仍通过 |
| 核心和协议 | `clipboard-writer-final-tests.log`：3 项 Host 策略/任务/全局网络额度、1 项 RGBA 编码取消、38 项协议、6 项 GUI 普通测试通过；显示单测另行显式执行，不把 ignored 计为通过 |
| 输入回归 | `runs/20261016T214923Z`，两轮真实键鼠/中文输入、预编辑本地保留、失焦/断开松键和工具栏隔离通过 |
| 构建与源验证 | core/GUI Release 通过；62 文件 staging、pin/patch/overlay/lock 核对、diff 空白检查通过。构建复用原 FFmpeg 静态库 |

两轮均有画面、保持 Streaming、正常回收 Viewer 并保留 Host；身份/认证/服务器和其他共享设置保持。全部使用无宿主桌面/服务/音频/密钥挂载的独立容器和私有 Xvfb；本轮没有使用 GPU。

保留的失败与修复：

- `provider/20261016T213058Z` 和首次大图连接：Host reader 的每分块固定 5 ms 休眠使三秒期限耗尽。改为 X11 可读立即唤醒，未延长期限；下一轮独立 reader 为 575 ms。
- `runs/20261016T213850Z`、`20261016T214045Z`：新内容已到 GUI，但夹具在 SelectionClear 后退出，截断已经开始的旧内容 INCR。夹具改为完成已接收请求，原始 request/读取长度/返回码日志保留。不能据这些失败断言原 GDK provider 无法传大图。
- `runs/20261016T214547Z`：GUI 分块输出初版显式 flush 触发 GIO CRITICAL/超时。改为每段 write，按 GDK 正常 provider 完成/close 约定结束；最终运行检查无 CRITICAL。新分块 provider 另有并发、取消及保留额度约束。

最大 PNG 使用合法两像素图和 ancillary 填充，测试的是字节上限，不是最大像素图片。GUI 的 RGBA provider 仍由 GDK 纹理序列化；最大像素 RGBA 跨网络及跨平台解码未验收。

整条大图链路的内存尚未达标：两轮 GUI/Viewer/Host 独立 PSS 峰值约 **265–267 / 377–379 / 642–676 MiB**。同期采样的三个进程 PSS 合计峰值约 **1074/1097 MiB**；样本间隔目标 100 ms，实际间隔与原始值见 `large-clipboard-samples.json`。这不是三个独立峰值相加，也不包含 Xvfb/测试夹具或专用 GPU 内存。单 provider 保留 128 MiB 的局部成本不能代替这些完整链路数字；网络序列化/加密副本、候选和分配器保留仍须分析，未放宽首页或整体预算。

未验收项：Host Wayland、最大像素/RGBA 跨网络、Mac/旧版互操作、实际慢网络/多连接/动态媒体并发、完整故障与后台恢复、1440p GPU/长期内存/同条件 A/B、发行版 ABI、原生安装包及回退。现有安装和服务保持原状，开发产物留在 Build/Linux。

最终二进制 SHA-256：

- GUI：`bca3ec7370662bc413190b41965bf5d77f12c5ffc764abeb3d2b5620304592ff`
- core：`4413bec00be474d497bd891b4b7da7ac5ac37afa5a40a8531fdb24e802e24302`

复现入口：`Scripts/linux/test-native-viewer.sh clipboard-large`、`Scripts/linux/test-native-viewer.sh input`；provider 夹具通过 `Scripts/linux/native-container.sh -c 'python3 -B /workspace/Linux/tests/native_clipboard_writer_smoke.py'` 和对应的 `native_clipboard_provider_smoke.py` 执行。canonical 代码、测试与合同均在 Linux/；大 PNG 等生成物留在 Build/，其长度/SHA-256 与未复制原因保存在 `excluded-generated-files.json`，无需在 Git 中保存数份 128 MiB 图像。

`source-state.json` 固定本检查点源码与产物哈希，`contract-snapshot.md` 保存合同快照，`evidence-sha256.json` 固定归档文件。此前证据目录未改写。
