# FarPane Linux GPU 媒体重构（linux-host）：Host 分类剪贴板

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本检查点接通 Host 分类设置、GTK 控件、连接撤权、有界 X11 读取与后台调度。完整 GUI/安装包目标继续进行，`runtime_ready=false`。开发 Release 留在 Build/Linux；未安装、提交、推送、切换或修改现有服务，未重建 FFmpeg。

本机共享页提供文本、富文本、图片 × 发送/接收六个实际控件。配置使用既有 durable 事务与 revision；独立 native key 不修改旧版开关、音频或文件设置。没有新 key 时只继承旧文本授权；损坏的显式策略关闭共享，不回退到旧权限。Host 连接不再使用上游通用剪贴板广播或每次更新创建线程。

一个 Host 工作线程处理最新输入；授权先于解压和桌面内容读取，写入前复查策略和连接 epoch。X11 先检查 TARGETS，跳过文件 URI 和自身来源，仅读取已授权表示；每次属性读取、INCR 累积大小和整个 selection 响应都有上限。连接失效使旧任务失效。所有 Host 连接共用一个网络发送额度，覆盖序列化与 TCP 发送；等待者只保留最新候选，完成后通知重试，serial 防止重复发送。已经写入本机剪贴板的内容保留，并计入 Host 内存。

| 检查 | 结果与边界 |
|---|---|
| 协议 | 38 项通过，见 `logs/host-clipboard-gui-build.log` |
| GUI | 6 项普通测试通过；显示相关的既有 ignored 单测本轮未重复计入 |
| Host 核心 | 3 项通过：迁移/损坏策略、真实 wire 最新输入与撤权、跨连接发送额度/通知/防重复，见 `host-clipboard-unit-verified.log` |
| 配置进程 | 32 项通过，包含新进程回读、未知字段和旧 revision 拒绝、损坏策略关闭、旧版及其他设置保持，见 `host-clipboard-config.log` |
| 实际 GTK 控件 | `runs/20261016T210417Z/host-clipboard-ui`：六控件逐项关/开，12 次后台事务确认，原值恢复 |
| 实际剪贴板 | `20261016T210417Z`，两次 GTK → Viewer → 私有 loopback Host → 私有 Xvfb 连接，每轮 20 项通过 |
| 输入回归 | `20261016T210509Z`，两轮实际键鼠、中文单次提交、失焦/断开释放和工具条隔离通过 |
| 文件回归 | `20261016T210641Z`，文件专用认证、分页、审批、空文件双向 SHA-256、worker 回收、Host 保留通过 |
| 构建 | core/GUI Release、旧 Flutter/GPU 组合 check 通过；61 个 staging 文件、3 项准备/5 项 staging 检查及完整 pin/patch/overlay/lock 核对通过 |
| 界面渲染 | `gui-render`：三个私有 Xvfb 页面截图成功，无旧 GUI 库映射/GTK CRITICAL。此处离线开发路径不能通过安装目录鉴权，后台不可用提示属于该静态测试，不是用户安装验收 |

两轮每轮 20 项见 `viewer-*/clipboard-result.json`：文本双向；Viewer 64 KiB 边界/超限；富文本默认关闭；Host 64 KiB/超限；卡住的 Host selection owner 之后在总期限内恢复新内容、控制接口仍可应答；HTML/RTF/文本 bundle 双向 INCR；富文本不授权独立文本；PNG 双向；SVG 原字节双向；16 次连续交替复制；Host 未授权类型不请求正文（同时确认实际读取过 TARGETS）；拒绝未授权入站富文本；Host 独立收发撤权；Viewer 单向撤权；失焦/恢复；Viewer 全关；视频会话保持 Streaming；控制事件无正文；实际 Host 撤权按钮关闭双向复制；Host 全关持久化。这里的媒体检查是既有画面和 Streaming 状态保持，不是动态高负载媒体并发或吞吐验收。

每轮 5 次 Host 策略修改记录了前后 revision，连同开场设置和成功连接历史写入逐项核对，其他身份/认证/网络/媒体/共享设置保持预期。显式连接撤权不可由该连接的旧选项重新授予；全关后再开启策略只适用于新连接。所有测试均使用容器自建 Xvfb/会话总线/配置和 loopback；没有宿主 GPU、桌面、剪贴板、音频或服务挂载。

保留首次失败 `logs/host-clipboard-check.log`：arboard provider 要求 `'static` 数据，借用 Bytes 不能编译。已改为显式有界拥有副本后完成构建和上述真实连接测试；这些副本属于后续内存优化范围。没有隐藏或覆盖该失败日志。

操作前采样 PSS（MiB，GUI/Viewer/Host）：第一轮约 **135.7/13.9/110.5**，第二轮约 **132.9/13.6/113.2**。均为软件媒体/Xvfb，无 root 服务或 GPU；不是剪贴板峰值、首页 60 MiB、整体预算或同条件旧新版 A/B 验收。静态 GUI 截图测试的首页样本也超过 60 MiB。

最终开发二进制 SHA-256，与三个实际运行的 `test-binaries.json` 相同：

- GUI：`9373e61dbac1c3e1414fe72d8e7a4cd33b4dd8ad7e926e32f74e067f65430b99`
- core：`20b478e6ae3ecdb2e5826bf32aa394467164c6e594325bc8987a799e5ef90b19`

未验收/下一步：Host Wayland 后台仍明确不可用；X11 写入仍借用 arboard provider，超大 selection 的 INCR 输出、转换副本及峰值必须单独实现/验证，不能从本轮中等 PNG 推断 128 MiB 全范围可用。3 秒是其他 selection owner 的内容响应期限，本地 X server 同步请求/回复的整体冻结恢复仍待处理。最大图片、RGBA 跨网络、Mac/旧版互操作、实际慢网络多连接额度、动态媒体并发和通道故障矩阵未验收。后台注册/恢复、完整内存与 GPU 矩阵、跨发行版 ABI、安装/回退/发布仍在整体目标内。

实现合同见 [快照](contract-snapshot.md)和 [canonical 文档](../../../Linux/docs/clipboard-contract.md)。`source-state.json` 记录本检查点 canonical 文件与二进制哈希；`evidence-sha256.json` 固定这份证据，既有检查点未改写。
