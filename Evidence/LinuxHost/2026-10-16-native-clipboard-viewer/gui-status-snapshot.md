# FarPane Linux GPU 媒体重构（linux-host）：原生 GUI 开发状态

2026-10-16，分支 `codex/linux-host-gpu-media`，开发基线 `b01c40bd7da588f0ec2add2947a9368289006792`。

最新检查点：Viewer 富剪贴板已接通并通过私有 Xvfb 双向测试，见文末及[证据](../../Evidence/LinuxHost/2026-10-16-native-clipboard-viewer/README.md)。Host 分类持久策略、有界后台 owner、完整生命周期/兼容/内存验收与安装包仍在开发，`runtime_ready=false`。

用户授权的完整交付目标：Linux 原生 GUI 对标 Mac 的首页和会话功能，完成真实后端对接，打包成可供用户测试的完整应用。此目标仍在进行。不得把以下原型、编译结果或协议单测当作完整 GUI 交付。

第一阶段原始测试见 [U0 依赖与界面证据](../../Evidence/LinuxHost/2026-10-16-native-u0/README.md)。Host/GUI 接通阶段见 [Host 控制与生命周期证据](../../Evidence/LinuxHost/2026-10-16-native-host-control/README.md)。配置事务与 Viewer 基础层见 [基础层证据](../../Evidence/LinuxHost/2026-10-16-native-config-viewer-foundation/README.md)。独立 Viewer、软件解码与实际连接见 [连接阶段证据](../../Evidence/LinuxHost/2026-10-16-native-viewer-session/README.md)。

## 方案已收敛

Claude 对 v2 的最终只读核对结论为可实施、没有新的阻断点。[v2.1 方案](gui-rewrite-plan.md)记录新增接口约束；[评审归档](../../Evidence/LinuxHost/2026-10-16-gui-review/README.md)保存原文与采纳决定。Linux owner 独立实现，Claude 没有开发、构建或操作服务。

## 当前实际进度

| 要求 | 当前状态与证据 |
| --- | --- |
| headless 依赖拆分 | `0015-native-headless-boundary.patch` 新增 `farpane-native`/`legacy-ui` 边界。native Cargo 依赖树没有 GTK3/GDK3、Sciter、tao/tray-icon、winit/softbuffer；native check/Release 编译通过，旧 Flutter/GPU feature 组合 check 仍通过 |
| 独立核心入口 | `--server` 已在隔离容器实际启动：先取得配置 owner、确认同 release 的不可变可执行文件、等待内置 CM listener 就绪，再启动控制接口和旧 Host 网络核心；没有独立 CM/托盘/Flutter 进程。`--service` 已接入但未运行验收。`--config-command`/`--config-cli` 支持受限配置。`--viewer <session>` 已有独立入口、认证和媒体线程；完整产品仍为 `runtime_ready=false` |
| 轻量协议 crate | `Linux/native/protocol/` 只依赖 serde/serde_json/libc。具备角色命令范围、密码 Debug 隐藏、64 KiB 控制消息、消息总超时、私有 socket 目录、SO_PEERCRED + SO_PEERPIDFD 稳定身份检查、不可由普通用户修改的 executable 路径检查 |
| GPU 帧合同 | 多 object/layer/plane、FD 数量、代、索引、pitch/offset/size 越界验证与 SDR 默认颜色规则已实现。新增有界 Unix seqpacket + SCM_RIGHTS 通道，异常报文自动关闭收到的 FD。VAAPI/DRM_PRIME 与 GtkGLArea EGL 分平面导入、颜色 shader、GLsync 已接通。独立 256×128 H.264/HEVC 探针以及私有 headless Wayland 的两次实际 GTK 连接通过；不支持时明确回退软件。真实用户桌面/原生 Xorg、长稳与资源目标仍未验收 |
| 监管策略 | `0016-native-host-runtime.patch` 接入 root supervisor 与实际活动计数。精确 exe/UID/argv/start-time + pidfd 选择/停止；连接、待审批、CM 文件任务、视频服务及尚未清理的 GPU owner 阻止空闲维护。未知状态保留进程，独立健康失败持续 60 秒后才走明确故障恢复。虚拟时钟与进程身份测试通过；真实 root 监管、用户切换及显示变化仍未验收 |
| GTK4 首页对接 | 首页状态来自真实 native agent 或离线配置 helper，包含 ID、认证模式、固定密码状态、可用临时密码、GPU 开关/后端。服务器设置、认证、密码、GPU、入站审批/撤权/断开有真实命令路径；允许/拒绝/超时、断开和撤权已有实际连接证据，其他并发与重启矩阵仍待验收。独立工作线程、有界命令队列、状态合并，不在 GTK 主线程等待 IPC；分区切换释放旧 widget。连接按钮已接独立 Viewer、密码/二次验证/不安全连接确认、显示器选择、音频开关和 HUD；真实循环连接已测软件画面。设备管理已有真实持久化与 GTK 验收；音频与受限文件共享已接通，富剪贴板策略仍未完成 |
| 配置与迁移边界 | 首次 Config 访问前持生命周期 flock；运行中 CLI 转发给 agent，离线 helper 不启动 Host；revision 冲突拒绝保存。握手检查版本/release、SO_PEERPIDFD 与 root-owned GUI/core。旧 Flutter FarPane 未使用新锁，因此还检查本产品旧 IPC，避免在线迁移同时写配置。新增 fsync + 两文件恢复记录事务，候选配置在落盘成功后才替换内存；首次安装有单独恢复标记。写失败、三处中断恢复、加密记录、损坏记录拒绝已做隔离测试。准备完成后的落盘故障要求进程恢复，不能继续由旧内存回写 |
| Viewer 只读边界 | `0018-native-viewer-boundary.patch` 在第一次配置加载前选定只读模式；只注入 GUI 提供的公开网络快照，PeerConfig 只在内存保存且不保存密码。旧配置/设备文件读取和写入被隔离，旧 Host/CM/服务 IPC 的连接与监听入口拒绝 Viewer。已接实际 `--viewer`。`0019` 绕开旧视频队列与隐式剪贴板初始化，并拒绝终端 IPC、隐式远程文件动作及语音呼叫 |
| 会话状态模型 | 旧会话/旧代/重复事件不覆盖新状态；只有本地呈现确认可以进入 Streaming。已接 worker 事件与 GTK frame clock 的 after-paint 确认；真实软件画面已验证 |
| 环境与 canonical | 新依赖只装入扩展的隔离 builder；FFmpeg 未重建、宿主包未更改。`prepare-native.py` 在写入前验证整个 staging 操作，保留未知生成目录修改。源码、补丁和两个新 Cargo.lock 均在 Linux 下 |
| 桌面通知与激活 | Host 内纯 D-Bus SNI/DBusMenu/通知已接通；GUI 可经标准 D-Bus 激活并复用窗口，审批仍走已鉴权控制通道。服务重启/消失、GUI 退出、真实批准与无人处理超时已完成私有总线验证；真实 GNOME/KDE、后台注册和睡眠恢复仍待验收 |
| GUI/Host 组合 smoke | 容器内 root-owned 测试 release、普通用户 Host/GUI、私有 Xvfb/D-Bus、无网络/GPU/宿主 socket。真实配置转发、重复 agent 拒绝、不受信任 executable 拒绝、GUI 两次关闭/打开保留同一 Host 均通过；三个分区显示合成配置。maps 无旧 GUI 库，未发现 GTK CRITICAL。该轮未含媒体连接；最新 Viewer 检查已在两个私有 Xvfb 间跑实际 TCP 登录与视频，原始结果另行归档 |

新控制协议当前要求支持 `SO_PEERPIDFD` 的 Linux 6.5+；Ubuntu 24.04 默认内核和 Debian 13 候选满足版本范围，但发行版实测仍未完成。不能静默降级为存在 PID 复用竞态的 `/proc/<pid>/exe` 单次检查。此要求仅针对新的普通用户控制接口，不改变既有 root DRM IPC 权限。

## 设备管理与内存的后续检查点

[设备管理检查点](../../Evidence/LinuxHost/2026-10-16-native-devices/README.md)已完成最近设备、中文别名、收藏、搜索、仅收藏筛选、忘记确认与快捷连接；真实 GTK 操作和后台落盘已验证。记录只在首次实际呈现成功后写入，经同一个配置 owner/revision/原子事务，按 ID 服务器及公钥隔离，最多 128 项/24 KiB。损坏数据不覆盖、收藏不自动淘汰。该设备检查点当时尚未实现 Secret Service/保存密码与远端主机名称；新增实现见后面的密码库检查点。

[内存与纹理共享检查点](../../Evidence/LinuxHost/2026-10-16-native-gpu-memory/README.md)补上全新 OUT_DIR 的 GResource 生成检查，验证默认 GSK GL、同 display 的 GL API 和共享能力；私有 Wayland/Xwayland 的 GLES sharing=true。首页空闲两秒后在短线程一次性回收分配器保留页，实际首页 PSS 为 97.8–101.9 MiB，Viewer 截图前 118.2–119.3 MiB。此前截图后约 196 MiB 的样本不代表优化后的值；60 MiB 首页目标仍未达到，没有放宽预算。真实桌面、20 轮资源与延迟仍待验收。

[同窗口重连检查点](../../Evidence/LinuxHost/2026-10-16-native-reconnect/README.md)已增加结束/失败后的重试和替换连接确认，旧 worker 回收并释放旧 view 后才建立新 session。隔离软件会话的实际 worker 崩溃、同 GUI 重试、重新认证和再次呈现通过；输入/IME/松键与私有 Wayland GPU 回归通过。真实断网/睡眠恢复、D-Bus 第二次连接与 GPU 故障矩阵仍待验收。

[光标检查点](../../Evidence/LinuxHost/2026-10-16-native-cursor/README.md)已接入仅作用于远程画布的 GDK 原生光标，32 项缓存、96×96 单形状上限。实际 Xvfb→网络→GTK→XFixes 检查确认了颜色、热点、缓存重选、本地工具栏边界与半透明像素。曾发现 X11 的预乘 Alpha 被重复相乘，修正为显式格式后通过。Mac 非预乘路径有源码依据，尚未做跨机实测；其他后端/尺寸、远端位置覆盖层和长稳仍待补齐。之后的私有 Wayland GPU 回归通过。

## 内存调查：尚未验收

Release 原型在容器 Xvfb/Cairo 下首页 PSS 为 122,094 KiB（119.2 MiB），高于 60 MiB 目标。其中 LLVM 映射约 36 MiB、Gallium 约 9.9 MiB，堆约 21 MiB。仅作诊断的 `GDK_DISABLE=gl,vulkan` 对照为 56,121 KiB（54.8 MiB），表明图形初始化成本显著。

禁用图形的对照不能运行最终 GLArea Viewer，因此不作为正式优化或达标证据。宿主硬件驱动和共享页归属尚未测量，也没有改变验收目标。后续分区样本可能包含前一张测试截图导出后的分配器保留；不能把它们当成 20 轮泄漏实验。完整 Host/GUI/Viewer PSS、GPU 分配和组合预算都未验收。

本阶段接通 Host 后的最新隔离样本：首页 114.5 / 107.0 MiB PSS；关闭两个 GUI 循环后的 Host 为 57.1 MiB。它们不是同时采样的组合预算，也没有 root 服务或媒体连接，首页 60 MiB 目标仍未通过。离线配置 helper 路径亦已实际运行验证。

## Viewer 当前实际能力与限制

最新 [GPU Viewer 检查点](../../Evidence/LinuxHost/2026-10-16-native-gpu-viewer/README.md)包含真实 VAAPI→DMA-BUF→shader→fence 探针，以及私有 Wayland 和 Xwayland 中各两次实际 GTK 连接。已经出现 GPU 画面，尚不是完整功能、真实桌面或性能预算验收。

最新[输入与文本剪贴板检查点](../../Evidence/LinuxHost/2026-10-16-native-input-text-clipboard/README.md)已接通真实 GTK 键鼠/IME、有界网络输入队列和双向 UTF-8 文本剪贴板。两个私有 Xvfb 间的真实连接验证了普通字符、中文单次提交、预编辑不外发、切换应用/断开时松键、工具栏点击不外发，以及双向文本、8 KiB 上限和关闭后停止发送。图片/HTML/RTF、实际桌面输入法和独占仍未验收；此前连接阶段的“输入/剪贴板未验证”描述仅指当时那一轮。

独立 worker 已接通实际 RustDesk 协议会话，GUI 只传公开 ID/服务器快照，不读取或保存 Host 密码。专用控制通道校验 release/身份/session/sequence/generation；命令和事件有界，压缩队列最多 4 项且累计不超过 16 MiB，不丢弃参考包后继续解码。媒体调用/归还有超时监管，GUI 线程不等待 worker；重试必须先确认旧子进程已回收。

GUI 在实际 EGL context 查询并验证导入能力后才协商 GPU；不支持时进入**软件兼容模式**：H.264/HEVC 使用已存在的静态 FFmpeg，VP8/VP9 使用同一依赖缓存中的 libvpx，libyuv 做 BGRA 转换。不可变 sealed memfd 跨进程传帧，单帧不超过 2560×1600 像素，最多 3 个未归还帧，未导入的旧候选可直接归还；GDK 持有不可变像素，不与 decoder 复用可写内存。VP8 在关键帧解码前检查尺寸；VP9 外部分配器另有 96 MiB 累计上限。这些开发约束不等于整个 Viewer 已达到 240 MiB 目标。

GPU 路径限制 H.264/HEVC、8-bit NV12、SDR；固定 23 个 surface（16 参考 + 4 工作 + 3 出借），对齐后像素上限 2560×1600。保留原始 AVFrame 和 DRM_PRIME 映射。GLArea 对 R8/GR88 分平面导入，在 shader 中转换到持久的自有 RGBA 纹理，再呈现到 GTK framebuffer；后续重绘只读这张自有纹理。非阻塞 GLsync 查询必须在同一个有效 EGL context 中执行，确认完成后才 ACK；超时或上下文丢失停止整个 Viewer 代，HUP/Drop 不作为完成证明。

780M/Mesa 26.0.8 返回格式可用但 modifier 数量为零，GBM/VAAPI 导出的布局为 INVALID。现在通过同 render 节点的 16×16 自有 GBM 缓冲实测 EGLImage→2D texture 导入，并完整保留 modifier 原值，绝不把 INVALID 当作 linear。限定 renderD128 的真实探针完成 H.264/HEVC 各 4 帧的解码、导入、shader、fence 和归还，色块 RGB 最大误差 0；私有 Wayland 实际连接两次，每次 GPU 帧、after-paint 和完成归还均确认，退出后同一 Host 保留。它们仅使用 256×128 合成静态内容，既有服务连接数持续为零；没有宿主桌面、KMS 或服务切换。

实际 GTK 样本 GUI PSS 约 196 MiB、Viewer 约 31 MiB（截图后），仍需内存调查。真实用户桌面/分辨率、原生 Xorg、持续视频、故障与长期资源目标未验收，不能称为完整 GUI 或性能交付。

已在隔离容器的两个私有 Xvfb 上完成真实 TCP 连接、错误密码重试、VPx 解码、GTK 呈现、Viewer 退出回收和第二次连接，Host 的 ID、revision 和认证状态不变。此测试是容器内直连，未验证 ID 服务发现、端到端加密、实际桌面/驱动、输入、音频、文件、剪贴板或网络故障恢复。显示器选择和音频开关已有命令路径，但只有一个显示器且未传音频，不能记为功能验收。

## 继续实现的顺序

1. 配置事务故障/恢复已完成隔离验证；入站允许/拒绝/超时、断开、音频/文件撤权和键鼠撤权状态已完成实际 GUI/通信验证。继续按键按下期间撤权的释放、其他权限与并发/重启矩阵，以及 root 监管、显示代重建和登录会话边界验收。当前 native 实例只在隔离容器运行。
2. 首页设备列表/收藏/别名/搜索已接通；继续密码库的跨桌面/2FA 验证、共享类型和方向、接收根目录/逐次确认、音频设备变化与迁移剩余矩阵、真实桌面的通知/SNI 与激活、后台注册和睡眠/网络恢复；继续完善已有 worker 的权限、输入和传输边界。
3. 独立 Viewer、认证、软件画面、输入/IME、文本剪贴板和 EGL GPU 呈现已接通；继续实际桌面/输入法矩阵、故障/资源/色彩边界、网络与睡眠恢复、富剪贴板、音频剩余矩阵、文件传输及完整 HUD/诊断。
4. 完整生命周期、异常与资源测试；跨发行版 ABI/桌面验证；原生 manifest、安装器、图标/desktop/AppStream、Linux 独立 CI、完整安装包与可回退升级。用户测试前提供清楚的支持范围与未验收项。

## 密码库与远端名称检查点

新增 [密码库检查点](../../Evidence/LinuxHost/2026-10-16-native-secrets/README.md)和[接口合同](credentials.md)：视频/文件认证共用系统密码库控件，默认不保存；显式读取，认证成功后才保存，错误密码和一次性验证码不保存。按服务器、公钥和设备隔离；设备页可只忘记密码，或同时删除记录和密码。读取期间改用手动认证会使旧读取结果失效，待取消的读取结束后仍可保存新认证成功的密码。GTK 主线程不等待密码库调用。

已通过五轮私有视频连接、独立 GUI 的密码读取、延迟服务取消、读取期间手动连接、确认删除、设备页取消/删除与隔离记录检查。没有 libsecret、密码库锁定时均完成两轮手动认证并呈现画面；锁定的读取/保存/删除被明确拒绝，记录与服务保持存在。文件窗口认证后保存及上传/下载 SHA-256 回归通过。22 项协议、3 项 GUI、27 项配置、5 项 staging 测试，native core/GUI Release、旧 Flutter/GPU 组合 check、pin/patch/overlay/lock 核对通过。最终测试二进制哈希与归档一致。

隔离测试曾发现 GNOME Keyring 50 在连续取消自动解锁时触发自身断言。最终版不主动请求 `Unlock`，锁定时提示先在系统密码管理器中解锁；没有默认 collection 时不替用户创建。此前失败的原始日志保留。该修改没有访问或改变宿主密码库。

远端名称取自认证后的 PeerInfo，在会话标题和最近设备中显示，首次实际呈现后由配置 owner 持久化；用户别名优先，名称可搜索，旧记录可读取。真实 loopback 会话已核对容器主机名、持久化与实际 GTK 搜索。

资源样本同时记录 GUI、Viewer、Host 和私有密码库；这一轮是 640×480 软件媒体与 Xvfb/Cairo，不是 1440p GPU 预算验收。密码库额外进程不能从组合成本中漏算；首页 60 MiB 目标仍未通过。其他密码库提供者、真实桌面的手动解锁/默认库初始化、2FA、完整交互与长期资源矩阵仍待验收。未安装这个原型，`runtime_ready=false`；完整 GUI、跨发行版 ABI 和用户测试包继续开发。

[原生音频与撤权检查点](../../Evidence/LinuxHost/2026-10-16-native-audio/README.md)已完成非阻塞 Host 采集、Viewer 有界 Opus 播放、真实共享页/麦克风确认、音源和开关持久化。私有 PulseAudio/null sink 的两次真实网络连接测得约 440 Hz 的输出，关闭与真实 GUI 撤权后测得静音，重开恢复；终止测试音频服务后视频仍可刷新。修正了 `prebuf=0` 欠载静音和旧 CM prelogin 等待导致入站列表为空的问题。配置 21 项、协议 21 项、GUI 3 项及最新私有 Wayland GPU 回归通过。该检查点当时仍待旧 `audio-input` 音源迁移；后续进展见下文。实际桌面/硬件音频、设备拔插、服务恢复重试、音画同步/抖动和长稳仍待验收，未安装此原型。

新增[音源迁移与文件基础层检查点](../../Evidence/LinuxHost/2026-10-16-native-audio-migration-files/README.md)：旧 `audio-input` 有描述、但尚无原生选择记录时，要求用户重新选择音源；采集入口在选择前拒绝启动，不把旧描述当成默认系统音源。实际离线配置 22 项检查和 GTK 未选择提示、麦克风确认取消/允许、切换音源、开关落盘通过，真实音频播放/撤权/故障视频回归也通过。GTK 使用明确的“请选择共享音源”项，避免空选择表现含糊。当前实测是在建立媒体连接前完成选择；**已有连接请求音频时的迁移阻断、旧配置回退、真实音频设备矩阵仍未验收**。

[原生文件连接检查点](../../Evidence/LinuxHost/2026-10-16-native-files/README.md)已将文件存储 owner 接入真实 RustDesk 文件连接、Host 配置和 GTK 辅助文件窗口。首页/会话中的文件入口、共享根目录、逐次确认、进度、取消、双端覆盖确认及入站撤权均有实际路径。文件 worker 独立于视频和音频；Host 最多四个文件 worker，每个八项任务，有界报文/队列、目录游标与超时。普通用户的显式私有根目录取代旧代码对 seat0 用户的文件访问假设；服务端不向远端暴露宿主绝对路径。

已通过普通和空文件的真实上传/下载、错误密码重试、1000 项目录的前两页（每页 128 项）、本机确认、确认前取消、拒绝覆盖保留原文件、勾选覆盖后替换、实际本地覆盖对话框、传输中撤权和进程回收。16 MiB 限速上传在 Host 收到 4.5 MiB 后通过真实撤权按钮停止，临时文件清除、目标未提交，界面显示已中断。上传、共享目录与下载的 SHA-256 一致；Host 配置/身份保留。最终协议 21 项、存储 18 项、GUI 3 项、配置 27 项、staging 5 项检查通过；音频/视频真实连接回归通过。此前“文件基础层尚未接网”的描述只适用于旧检查点。

文件窗口与首页同时打开的私有 Xvfb 样本（截图前）：GUI PSS 124.2 MiB、文件 worker 11.5 MiB、Host 46.2 MiB；不包含 root 服务、视频或 GPU，不代表首页 60 MiB 或组合预算已达标。新文件 worker 为按需额外进程，已在方案进程模型中显式计入。这一单文件检查点未包含目录/多文件传输，后续实现见下文。**Mac/旧 RustDesk 互操作、并发媒体/文件、畸形报文/限额/所有权限与故障矩阵、真实桌面与完整包仍未验收**。当前窗口不能当作完整文件功能交付。`prepare-native.py --check` 最终验证 45 个 canonical 源码文件；pin/patch/overlay/lock 重建核对通过。


新增[目录与多文件检查点](../../Evidence/LinuxHost/2026-10-16-native-folders/README.md)：已完成多选文件上传、分批目录上传和下载、空目录、单任务/单次批准、显式目录合并覆盖和跳过对象提示。每批最多 128 项/16 KiB，遍历保留有限游标；没有收集完整目录树。下载端保留 Host 原私有根权限，每批保存后才回复确认；上传/下载确认都绑定当前页码。GUI 提供发送文件夹与接收文件夹操作，普通单文件路径继续可用。

最新实际 GTK/loopback 测试将 301 个文件跨多批上传再下载，源端、Host、下载三方 SHA-256 一致；嵌套空目录、独立空目录、三文件选择、符号链接跳过及本地目录覆盖确认通过。32 MiB 目录下载在 Host 读出 3.125 MiB 后修改源文件，任务失败但文件连接保留；另一个目录下载在传输中取消，当前文件未提交、无 staging 残留。上传中修改源文件也只终止该任务，原文件 worker 随后成功完成新的下载。所有操作在私有容器中，无宿主桌面/GPU/音频/服务修改。它们不替代目录中途撤权、磁盘故障/跨批畸形报文、legacy/Mac 互操作和媒体并发的完整矩阵。

U0 未整体关闭：实际 root 监管、完整 CM 权限/文件处理、EGL/VAAPI 长稳与故障边界、真实驱动内存目标仍待验证。当前不会安装或启动这个不完整原型。原 RustDesk 与现有已工作的 FarPane 实例均保持原状。

## 复现入口

```sh
python3 -B Scripts/linux/prepare-native.py
python3 -B Scripts/linux/prepare-native.py --check
Scripts/linux/container.sh Scripts/linux/build-native-core.sh check
Scripts/linux/container.sh Scripts/linux/build-native-core.sh release
Scripts/linux/native-container.sh -c 'cd Build/Linux/native/protocol && cargo test --offline --locked'
Scripts/linux/native-container.sh -c 'cd Build/Linux/native/files && cargo test --offline --locked'
Scripts/linux/native-container.sh -c 'cd Build/Linux/gui && cargo test --offline --locked && cargo build --offline --locked --release'
Scripts/linux/native-container.sh Scripts/linux/test-native-gui.sh release
Scripts/linux/native-container.sh Scripts/linux/test-native-gui.sh release no-graphics
Scripts/linux/container.sh -c 'python3 Linux/tests/native_config_smoke.py'
Scripts/linux/test-native-host.sh
Scripts/linux/test-native-viewer.sh
Scripts/linux/test-native-viewer.sh audio
Scripts/linux/test-native-viewer.sh files
Scripts/linux/test-native-viewer.sh files-empty
Scripts/linux/test-native-viewer.sh files-matrix
Scripts/linux/test-native-viewer.sh files-tree
Scripts/linux/test-native-viewer.sh files-tree-fault
```

第一轮 GUI crate 获取只使用 `native-container.sh --fetch` 的临时联网容器，其余构建离线。产物在 `Build/Linux/target/release/farpane-core` 和 `Build/Linux/native-target/release/farpane`；GUI 已接入部分 Host 控制，但两者都仍是开发产物，不是用户测试包。`test-native-host.sh` 仅在临时容器的 `/opt` 下组装测试 release；不向宿主 `/opt` 安装。

## 入站审批与出站并存检查点

[入站连接检查点](../../Evidence/LinuxHost/2026-10-16-native-inbound/README.md)补上 Viewer 顶部的“本机连接”入口：查看本机待批准/已授权连接，在临时对话框中允许、拒绝、撤权或断开，无须先退出远程画面。入口显示实际待批准数量；关闭对话框不会批准请求或停止 Host。对话框控件绑定采用弱 widget 生命周期，关闭后由后续刷新清除，不逐次累积失效回调。远端要求人工批准时，Viewer 显示“等待远端允许连接”。

实际私有 Xvfb/loopback 的三轮连接通过：允许前没有画面、允许后首帧呈现、键鼠撤权状态到达 Viewer、实际按钮断开；拒绝和未处理超时都没有收到画面，worker 回收，同一 Host 保留。超时轮总用时约 34 秒，包括 GUI 启动/连接，审批计时没有缩短。实际对话框截图已检查。该轮的关闭驱动仅发出 response 信号，不足以证明对话框实际关闭；下述桌面检查点已修正驱动并重新验证。GUI 完全退出后的系统通知与自动激活也见下述新证据。

修复 GUI 控制桥的重连竞态：操作携带发起时界面观察到的 Host generation；不能在连接重建后把旧审批换成新 generation 发送。过时代的审批在写入 socket 前拒绝，要求重新确认；错误时清除尚未交付的旧快照，避免离线标记被旧数据覆盖。新增单测确认旧/未知 generation 的审批没有发送字节。真实后台重启加旧请求重放的完整矩阵仍待补齐。

GUI 4 项测试和 native core/GUI Release 通过；键鼠/中文输入与失焦释放、五轮密码库、文件覆盖/撤权的实际回归通过。51 个 canonical staging 文件、pin/patch/overlay/lock 核对通过。新二进制直接引用的最高 glibc 均为 2.39，只是后续 Ubuntu 24.04 兼容性测试的依据；GTK/libadwaita/其他运行库和整个依赖闭包尚未在目标发行版验收，不能据此宣布支持。完整桌面集成、HUD/诊断、跨发行版与完整安装包继续开发。


## 桌面通知、托盘与窗口激活检查点

[桌面集成证据](../../Evidence/LinuxHost/2026-10-16-native-desktop/README.md)和[接口合同](desktop-integration.md)记录这一轮完整结果。Host 增加纯 D-Bus SNI、静态 DBusMenu 与入站通知，不加载 GTK，也不为托盘保留隐藏 GUI。三个 GUI action 只打开或聚焦主窗口/连接管理/托盘菜单；授权仍需实际 GUI 控件通过已有鉴权 socket 提交。授权页显示实际桌面服务可用性。

私有会话已通过 26 项端到端检查：服务稍后出现、KDE/freedesktop watcher、图标和菜单属性、D-Bus 自动启动、复用同一 GUI、关闭后进程退出而 Host 保留、GUI 关闭时收到请求、通知服务重启、过滤伪造来源/旧服务/旧 ID、点击通知不自动批准、实际允许后呈现、授权后关闭通知、服务消失后的无人处理超时。无操作按钮能力时只发通知，并拒绝其操作事件。超时轮没有帧、没有密码尝试，Viewer worker 回收；失败页面保留供重试，测试最后实际关闭窗口。X11 的 `_GTK_APPLICATION_ID` 为 `org.farpane.FarPane`，`WM_CLASS` 为 `farpane`；desktop 模板已按实测值修正。

入站允许/拒绝/超时回归再次通过。此前驱动调用 MessageDialog 的 `response` 只发信号，不能证明窗口关闭；现已改为实际 `close` 并验证窗口消失。另两次中间桌面运行分别发现测试自动提交密码、不应等待失败 GUI 自行退出的问题，均修正并保留原始失败日志。没有因测试便利而改变审批时限或失败页面行为。

截图检查发现人工审批完成后旧密码面板仍留在 Viewer；已在等待审批时使旧密码 challenge/读取失效，认证成功后清理输入和面板。测试新增等待审批与实际呈现时的 widget 可见性检查，最终截图确认无残留。已提交的密码保存候选仍只在认证成功后处理；五轮实际密码库连接、保存/读取/取消/手动认证与删除回归通过。真实 2FA 仍待验证。

22 项协议、4 项 GUI、5 项 staging 检查、native core/GUI Release、旧 Flutter/GPU 组合 check 和源 pin/patch/overlay/lock 核对通过。最新私有 Xvfb/Cairo 样本：主窗口含已打开管理对话框时 GUI PSS 约 111.3 MiB；另一轮与 Viewer 并存时管理 GUI 约 72.8 MiB；结束两次连接后的 Host 约 177.1 MiB，无 GTK/libadwaita 映射。它们采样时点不同，不能相加作为组合预算或当作托盘增量；首页 60 MiB 目标没有通过。没有新增后台 GUI 进程，不等于整个产品内存已达标。

服务/desktop 模板当前只在隔离测试中使用，未写入宿主桌面或安装此原型。真实 GNOME/KDE 托盘显示、Wayland 激活 token/焦点、用户总线整体重建、锁屏/greeter、root 监管、后台注册、睡眠网络恢复、富剪贴板、完整 HUD、发行版 ABI、原生安装包与回退仍在后续工作范围。`runtime_ready=false`，完整 GUI 交付目标保持进行中。

## HUD 与会话诊断检查点

统计定义见 [Viewer 诊断合同](viewer-diagnostics.md)，原始运行和源码/二进制哈希见 [HUD 检查点](../../Evidence/LinuxHost/2026-10-16-native-hud/README.md)。HUD 已连接真实后端，显示编码包率/带宽、解码与呈现 FPS、解码调用时间、远端 RTT、本地呈现等待、待处理队列、本地未呈现候选及媒体后端。资源来自 GUI 与 Viewer 分别读取自身 `/proc` 的 1 Hz 样本，包括 CPU/PSS/USS/RSS/SwapPSS、FD 和线程。关闭 HUD 后停止高成本采样和指标订阅，静止画面的速率归零；不把缺失数据填成 0，也不把本地等待当端到端延迟。

“诊断”窗口使用字段白名单、2,000 条/1 MiB 有界记录，后台以最多两份各 512 KiB 文件轮转。不会复制任意后端报错、密码、身份、路径、键鼠、剪贴板或文件内容。GTK FileDialog 异步导出当前脱敏事件和最后性能快照；关闭 HUD 后仍保留快照及其年龄。日志目录不可写、写入线程失败或导出失败均不阻塞媒体会话。

协议增加共用的指标队列规则：合并重复指标，满队列时移除指标，为关键事件留空间；全关键事件队列仍按原边界报告溢出。复核发现此前只合并新指标，关键事件抵达满队列时未先移除旧指标，现已修正。26 项协议测试包含指标洪峰/保序/真实溢出以及实际资源采样启停，6 项 GUI 测试包括脱敏、日志容量、轮转、锁与未知/符号链接文件保留。

两轮实际私有 Xvfb/loopback HUD 测试覆盖正常日志及日志不可写，每轮 12 项检查：真实控件启停、对应进程 `/proc` 交叉核对、静止零帧率、实际诊断窗口与取消/保存对话框、脱敏、停采后带年龄导出及导出失败仍保持 Streaming。输入回归起初因测试固定坐标点击到新增“诊断”按钮失败；现改为读取实际 HUD 控件分配并转换到 X11 坐标，再验证 HUD 确实开启。实际两轮键鼠、中文单次提交、失焦与断开释放、工具条不泄漏远端输入均通过，原失败记录保留。

新增呈现计数/候选跳过逻辑后的 GPU 显示回归通过：私有 Weston Wayland 与 Xwayland 各两次连接，renderD128、256×128、虚拟输出上限 12 FPS，每次输出一张静态新帧。实际 VAAPI/GTK DMA-BUF、该帧完成/回收、worker 退出与 Host 保留通过，没有软件帧回退。守护脚本运行中及前后确认已安装 FarPane 的视频连接数均为 0。此处只证明显示路径未被这次接入破坏，不是 GPU HUD 长稳/性能验收。

最终 HUD 软件解码/Xvfb 样本 GUI PSS 约 143.5/134.2 MiB，Viewer 约 15.9/15.2 MiB，只验证观测链路；资源年龄和采样时点分别记录。它们不包含 Host、文件 worker、root supervisor、合成器和专用 GPU 内存，不构成整体低内存验收。首页 60 MiB、同条件旧新版 A/B、真实门户与最小化/遮挡、1440p 动态 GPU 和长稳指标仍待验收。完整 GUI 目标继续进行，尚未交付安装包，`runtime_ready=false`。

## 富剪贴板数据层检查点（历史：当时尚未接入界面）

已新增 [类型、数据通道与接入合同](clipboard-contract.md)，证据见 [剪贴板数据层检查点](../../Evidence/LinuxHost/2026-10-16-native-clipboard-contract/README.md)。对齐 Mac 的 Text/HTML/RTF/PNG/RGBA/SVG，按三类、两个方向独立授权；metadata 与内容分开，最大 128 MiB 图片不会塞入现有 64 KiB 控制消息或视频帧队列。正文使用一份不可写、不可改变长度的 memfd，每个方向只有一份在途数据，校验策略 revision、serial、尺寸、偏移和描述符，旧回执不能释放新额度。共享映射可作为 GBytes/Bytes owner，避免适配层逐项复制整幅图。

后端适配器使用现有 RustDesk Clipboard/MultiClipboards，不访问桌面或配置。类型/方向授权先于解压；zstd 输出与 8 MiB decoder window 双重限额，PNG 拒绝第二层 zstd，任意 Special 名称/文件 URI 不准入。PNG 为结构/尺寸准入检查，未在这里进行 CRC/IDAT 的完整图片解码。

34 项协议测试、3 项原生核心剪贴板适配测试、6 项 GUI 回归测试通过。协议测试用真实子进程传递并验证 4 MiB RGBA memfd，覆盖大富文本 bundle、封印、过大/错误 FD 元数据、旧 revision、旧回执、重放和原帧通道；后端用真实 protobuf/zstd 验证中文/HTML/RTF 往返、映射所有权、压缩炸弹和大窗口拒绝。canonical staging 为 59 个文件，新增 overlay/pin/lock 核对通过。

当前运行路径仍是原有 8 KiB 文本共享，本检查点没有增加假开关或声称图片已可用。独立通道握手/超时、GUI MIME/ContentProvider、Viewer 独立网络额度、Host 持久策略与有界后台 owner、连接撤权时清理旧任务、实际 GTK/Host 双向粘贴及 Mac/Wayland 互操作仍须接通和验证；具体接入顺序已写入合同。未替换现有服务或开发 Release，完整 GUI/打包目标继续进行。


## Viewer 富剪贴板接通检查点

已将 GUI 与 Viewer 从控制 JSON 内的 8 KiB 文本路径改为独立剪贴板通道。GTK 控件提供文本、富文本、图片各自的发送/接收开关；默认关闭，按 MIME 和上限异步读取。HTML/RTF 可携带纯文本 fallback，PNG/SVG 使用原字节 ContentProvider，RGBA 使用映射支持的 MemoryTexture。保留原始 SVG MIME 的优先级，避免选择 GDK 推导出的 PNG 而意外栅格化。来源 provider 采用弱引用识别，避免回声和额外保留旧大图。

每端一个后台 owner、最新候选与一份在途额度，校验 policy/revision/epoch；策略、焦点和退出变化取消旧工作，耗时处理后以及网络出队/GUI 应用前复查。剪贴板另有单项网络额度，不扩大键鼠/认证的 1 MiB 队列；通道失败仅停用共享，旧 owner 释放前不允许累积重试。文件 worker 不创建此通道。当前 selection 由 GDK 持有时，其内容仍属于 GUI 内存成本；停止共享不会删除用户刚复制的本机内容。

实际测试暴露并修复固定上游 X11 监听的丢事件问题：原监听每轮重新订阅后抬高 sequence 门槛，丢弃休眠间隔排队的新 owner 事件。现在保持同一次订阅和初始门槛，只处理 CLIPBOARD XFixes 通知。commit 未升级；依赖源码导出、`0027`/`0028` 补丁、Cargo path override 与锁校验均纳入 Linux canonical 流程，不修改原缓存。网络适配也处理固定上游同时提供 PNG/RGBA 的情况，按授权选择一个类别，避免误拒绝合法图片或重复解码。

最终两轮真实 GTK → Viewer → 私有 loopback Host → 私有桌面连接，每轮 13 项检查通过：文本双向、64 KiB 边界/超限、默认关闭富文本、HTML/RTF/纯文本三格式双向 bundle、富文本权限不授权独立纯文本、超过 64 KiB 控制上限的 PNG 双向、SVG 原格式双向、连续 16 次交替复制、单向撤权、失焦暂停/恢复、全关停止发送、视频继续及控制事件无正文。两轮均确认 Viewer 回收、Host 保留、身份/配置不变。两个不透明色块的 RGBA → GDK provider → PNG 实际序列化在独立私有 Xvfb 单测验证，**不是 RGBA 跨网络或 Mac 验收**。

38 项协议测试、4 项核心格式适配、2 项网络额度/撤权、6 项普通 GUI 回归及 1 项显式运行的 GDK 测试通过；两轮实际键鼠/IME、文件专用会话空文件往返、旧 Flutter/GPU feature 组合 check、60 文件 staging、3 项准备/5 项 staging 测试及全部 pin/patch/overlay/lock 校验通过。此前夹具编译、SVG 优先级、X11 丢事件与根窗口失焦夹具的失败记录均保留。最后将失焦目标改成真实独立测试窗口，验证 GTK 实际失活；没有靠延迟绕过 X11 通知丢失。

证据见 [Viewer 剪贴板检查点](../../Evidence/LinuxHost/2026-10-16-native-clipboard-viewer/README.md)，接口见 [clipboard-contract.md](clipboard-contract.md)。这次样本在剪贴板操作前采集，不能作为大图峰值或低内存目标验收。Host 持久分类策略/有界平台 owner/真实连接撤权仍是下一步；Wayland/Mac 互操作、大图峰值、媒体并发和通道故障的实际会话验证待完成。开发 Release 留在 Build/Linux，尚未生成用户安装包；没有安装、提交、推送、替换现有服务或重建 FFmpeg。
