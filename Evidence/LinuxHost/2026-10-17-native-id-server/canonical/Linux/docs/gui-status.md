# FarPane Linux GPU 媒体重构（hermes）：原生 GUI 开发状态

2026-10-17，分支 `codex/linux-host-gpu-media`，开发基线 `b01c40bd7da588f0ec2add2947a9368289006792`。

当前供维护窗口测试的具体版本、文件、支持范围及操作顺序集中在[原生 GUI 测试候选](native-test-candidate.md)。最新 `.6` 修复了格式错误验证码使输入框消失的问题：视频和文件连接的真实 TOTP、错误重试、取消、密码库边界及文件传输已通过，双 Ubuntu 包运行和 `.5 → .6` 升级检查通过；仅重编 GUI，核心和 FFmpeg 未重编。详见[二次验证检查](two-factor-authentication.md)。尚未安装，真实桌面和内存目标仍待验收。

后续[实际 ID 与中继检查](id-server-connections.md)已通过：同一 `.6` 原始 GUI/core 对接私有 hbbs/hbbr，数字 ID 直连与强制中继均实际出图，错误服务器公钥在密码提交前被拒绝，退出后 worker/中继连接回收且 Host 保留。中继通过配对日志和两端 socket 交叉确认；私有 hbbr 使用单 Tokio worker 避开同机配对竞态。测试隔离于宿主网络和现有服务，没有应用修改、重编或新包；公网、并发服务器与真实桌面验收不在本轮范围。

前一候选记录：Debian `.5` 包与 `5ad72a01…` bundle 来自完整独立源码构建，交付源码快照为 `514e82df…`，编译输入为 `6464d1ae…`。已从断网、无 Git/旧产品缓存的解压目录实际生成 GUI bundle 和 Debian 包，并通过双发行版软件连接和限定 GPU 回归。应用源码保留 `.4` 的 RGBA 修复；专项大图片测试范围仍按旧版本记录。尚未安装到 hermes，维护切换等待用户确认。下面的旧阶段记录保留原有测试范围，不能将其中的旧版本哈希用于当前候选。

最新[独立打包交付](native-source-package.md)补齐源码包的根 notices、独立构建 receipt 和无 Git 的来源识别；实际编译来源与打包来源分别绑定，旧产品缓存不覆盖。完整源码构建与可移植打包这两个检查已完成；公开 Linux CI、完整发布许可审计、真实桌面和性能门槛仍未关闭。

新增[公开工具链入口](native-build-tools.md)：固定 Rust 1.89.0 SDK、vcpkg/CMake 均实际从公开 URL 下载并验证，新 SDK 在隔离容器安装、换路径挂载和离线复用通过；用它和空缓存完成 38 项协议测试及完整 GUI Release 编译。应用构建可以显式选择 SDK，不再必须使用 hermes 旧工具目录。未替换 `.5` GUI/core 或重编 FFmpeg；旧冻结源码归档不重写。

后续[独立 Linux CI](native-ci.md)已实现完整入口，并通过本地显式复用源码构建的串联验证：20 项打包/工具测试、38 项协议测试、包运行与 dpkg 事务，以及 bundle/升级包各两次真实软件连接通过。独立 workflow 固定 Actions 提交，只生成候选附件；没有推送、云端执行或公开发布。新工具和 CI 入口随新源码快照交付，不替换 `.5` 测试候选。

最新[首页资源测量](home-memory.md)区分了镜像文件页与宿主桌面共享页：六份系统文件内容相同而 inode 不同；只读使用同一文件页后，同一 `.5` 首页约 78–79 MiB，30 秒空闲样本 PSS 78.42 MiB、GUI CPU 单核 0.074%、12 FD/无 Viewer 子进程。固定分配阈值诊断只再减少约 3 MiB，未采用为产品默认。60 MiB 门槛保持不变，真实桌面仍待验收；上述差额是测量归因，不是产品版本优化。

新增[同一窗口反复连接检查](viewer-lifecycle.md)：`.5` 原始程序经外部 XTest 完成两轮预热加二十轮真实软件连接，22 个 Viewer 全部回收，软件帧映射归零，GUI/Host FD 固定 12/40，最大合计空闲 PSS 增量 2.37 MiB。末段 GUI 仍增长 598 KiB，不能宣称排除持续增长。另二十轮弱引用对象观察未发现类型净累积；该观察不覆盖全部堆分配，额外 preload 内存不作为产品预算。产品未修改，GPU/真实桌面/长稳与首页绝对目标仍未验收。

后续同轮分配器诊断进一步区分了驻留与分配：二十轮中 GUI PSS 最大增加 1.61 MiB，而 glibc 内存区总空间只增加 4 KiB，报告的非空闲空间净增加约 44 KiB，mmap 与对象类型未累积。原始逐区 XML 已保存，未将包含缓存/开销的非空闲字节冒充精确活分配，完整内存验收仍为 false；没有改变产品 allocator 默认值或重建候选。详见[分配器诊断](viewer-lifecycle.md#分配器明细与驻留增量)。

新增[独立原生依赖构建](native-bootstrap.md)：公开 Ubuntu 24.04 基础镜像、固定 vcpkg/CMake 工具、断网和空安装前缀下，13 个配方及 8 个静态库从源码构建成功，CPU 编解码/像素/生命周期探针通过。源码、工具、ABI、产物及两次前序失败均留证。没有使用旧媒体二进制缓存，也未重建现有 FFmpeg、替换候选或触碰服务。完整空环境媒体/core 构建和公开 CI 仍未完成；这一独立检查不修改 `.4` 的构建记录或冻结源码归档。

后续[完整源码构建](native-source-build.md)已通过：同一固定源码快照和新依赖前缀，在断网、空 Cargo/target 缓存的公开 Ubuntu 24.04 builder 中完成新 FFmpeg、libdrmtap、核心和 GTK4 GUI。新程序分别在 Ubuntu 24.04/26.04 完成两次真实软件视频连接，每个环境九类检查通过。修正汇总器的目录误计后仅重新验证，未重复编译。这关闭了该快照的完整应用源码构建检查；不声明工具链源码重建、按位复现、GPU/真实桌面或公共 CI 通过。`.4` 候选及现有产品 FFmpeg 前缀未替换，构建和运行证据另行绑定新哈希。

最新[大图片传输内存改进](clipboard-memory.md)：native Host/Viewer 共享接收正文，并释放已发送完的大型 TCP 写缓冲。相同 128 MiB PNG 双向夹具中，三进程同时 PSS 峰值由 1,070/1,090 MiB 降为 807/829 MiB，约减少 24%；两轮各 22 项剪贴板检查和字节/SHA 一致性通过。两项针对性测试、原生无 GPU/旧 Flutter GPU 检查通过。首页实际 GL 身份确认为 Radeon 780M/radeonsi/ACO，首页约 99–106 MiB，60 MiB 目标仍未达到。新核心的打包与后续验收以该检查点记录为准；下述源码包绑定此前核心版本。

新增[离线源码包检查点](native-source-bundle.md)：固定源码/补丁、1,082 个 vendor 目录、实际原生 port 配方与源归档已打包，最新修正版的 88,601 个条目逐项核对。断网、空 Cargo/编译缓存、未挂载原工作区的容器中，core/GUI 依赖图、38 项协议测试和完整 GUI Release 编译通过。已补入 Cargo include 规则遗漏的 libwebm 许可文本及其他定位材料，完整文本位置补充了 4 项，原始待核对记录仍保留。没有替换产品二进制或重建 FFmpeg；全新原生依赖/core 构建、完整许可审计及公共 CI 尚未完成。

最新打包检查点：[Debian 测试候选包](native-deb.md)已在 Ubuntu 26.04/24.04 各通过 6 组实际 dpkg/GUI 检查，包含安装、升级失败后的配置恢复、移除和包内两次真实视频连接。完整 GUI/core/图标与独立安装工具随包提供；包管理器只暂存候选，服务与桌面切换沿用显式维护事务。相同输入重打包哈希一致。没有重建媒体/GUI、安装到宿主或触碰现有服务。正式发布的完整依赖源码/许可证、CI 和真实桌面/性能验收继续进行，`runtime_ready=false`。见[Debian 包证据](../../Evidence/LinuxHost/2026-10-17-native-deb/README.md)。

Viewer 检查点：已提供本次会话显式授权的自动重连，最多四次，仅在已呈现过画面、核心允许重试且旧 worker 已回收后启动。每次使用当前设备/服务器范围内的系统密码库记录；取消、密码缺失/错误、确认要求、主动断开或身份范围变化均停止自动恢复。实际 GUI、私有密码库/网络提供者、TCP 代理与 Xvfb 的七轮会话、八项检查通过，包括断网暂停后重新出图和四次实际替换连接后停止。9 项 GUI、38 项协议单测通过，1 项既有图形测试按环境要求跳过；实际空文件上传/下载、认证、批准、取消和 worker 回收回归通过。见[自动重连合同](viewer-recovery.md)与[本轮证据](../../Evidence/LinuxHost/2026-10-17-native-viewer-recovery/README.md)。这些受控测试不替代真实网络切换、系统休眠、跨平台或 GPU 故障验收。

此前 Host 恢复检查点：已接入 logind/NetworkManager 只读事件监听、三次有界注册恢复和首页状态。12 项隔离端到端检查通过：实际 UDP 注册、恢复时保留现有 Host/授权连接并继续呈现新帧、无响应/拒绝耗尽、关闭被控取消恢复、提供者替换与旧信号拒绝。服务器拒绝回包不会仅因记录了延迟就误报恢复在线；第一次实际失败和修正后结果均保留。3 项恢复单测、38 项协议测试和 6 项 GUI 测试通过，1 项既有图形测试按要求跳过。见[恢复合同](system-recovery.md)与[Host 恢复证据](../../Evidence/LinuxHost/2026-10-17-native-recovery/README.md)。

Host 恢复阶段的开发 bundle 已通过 Ubuntu 26.04/24.04 各 8 组包/私有库检查及两次实际软件视频连接；原生无 GPU 与原有 Flutter/GPU feature 检查通过。该阶段产物 `farpane-native-dev-9499d664fb2ccb3e841cb98f` 未安装、未发布，仍为 `runtime_ready=false`。Viewer 自动重连阶段的实际产物与检查结果以本轮证据为准。安装版本、两个服务 PID、FFmpeg 静态库哈希/大小/mtime 在 Host 恢复阶段均未变化。

此前会话检查点：原生服务的有界桌面发现、同 UID 新登录切换、输入授权有效期和失败后重连已实现。实际开发包通过 17 项隔离服务检查，健康 Host 连续 70 秒不重启，持续卡住约 64.2 秒后恢复；4 项针对性单测和原生无 GPU/旧 Flutter GPU 构建检查通过。见 [会话发现与授权证据](../../Evidence/LinuxHost/2026-10-17-native-session/README.md)和[服务合同](native-service.md)。测试使用受控 loginctl，不等同于真实 systemd/logind、锁屏或物理输入验收。完整功能、跨桌面与内存目标仍在进行，开发包未安装，`runtime_ready=false`。

此前原生 GUI/core 已形成开发 bundle，补齐同 release 私有库加载、构建记录/清单校验和 Ubuntu 24.04 的 libva 兼容；同一包在 Ubuntu 24.04 纯运行镜像与 Ubuntu 26.04 中均完成两次实际软件视频连接。见 [打包与 ABI 证据](../../Evidence/LinuxHost/2026-10-16-native-package-abi/README.md)和[开发包说明](native-package.md)。[Wayland 剪贴板检查点](../../Evidence/LinuxHost/2026-10-16-native-clipboard-wayland/README.md)已完成后台协议与 X11 回归。

新增安装事务检查点：已实现 root 私有暂存、只读计划、维护切换、P1 回退和中断恢复，以及普通用户菜单/图标/D-Bus/autostart 的独立事务。真实进程/文件事务、未知角色与修改保留、用户入口恢复，以及真实包的私有安装/加载/GIO 读取，在 Ubuntu 26.04 和 Ubuntu 24.04 测试环境通过；服务管理器仍为替身，真实 systemd/logind 与用户桌面切换未验收；随后真实 core 在受控会话提供者下的 root/user 监管已通过独立检查。见 [安装合同](native-install.md)及[本轮证据](../../Evidence/LinuxHost/2026-10-16-native-installation/README.md)。没有更换 GUI/core/FFmpeg 二进制，也未操作宿主服务。

用户授权的完整交付目标：Linux 原生 GUI 对标 Mac 的首页和会话功能，完成真实后端对接，打包成可供用户测试的完整应用。此目标仍在进行。不得把以下原型、编译结果或协议单测当作完整 GUI 交付。

发布材料核对已开始：[依赖源码与许可清单](native-source-materials.md)离线归集 712 个选中 Cargo 包、2,598 份材料和 13 个缓存原生 port 信息，全部文件哈希已核对。45 个声明/独立文件定位记录仍待逐项检查；它们不是“无许可”的结论。对应开发源码快照及 GUI 离线构建已有上述证据；完整对应源码义务、嵌套第三方文本及发布审计尚未关闭，没有因此发布候选包。

第一阶段原始测试见 [U0 依赖与界面证据](../../Evidence/LinuxHost/2026-10-16-native-u0/README.md)。Host/GUI 接通阶段见 [Host 控制与生命周期证据](../../Evidence/LinuxHost/2026-10-16-native-host-control/README.md)。配置事务与 Viewer 基础层见 [基础层证据](../../Evidence/LinuxHost/2026-10-16-native-config-viewer-foundation/README.md)。独立 Viewer、软件解码与实际连接见 [连接阶段证据](../../Evidence/LinuxHost/2026-10-16-native-viewer-session/README.md)。

## 方案已收敛

Claude 对 v2 的最终只读核对结论为可实施、没有新的阻断点。[v2.1 方案](gui-rewrite-plan.md)记录新增接口约束；[评审归档](../../Evidence/LinuxHost/2026-10-16-gui-review/README.md)保存原文与采纳决定。Linux owner 独立实现，Claude 没有开发、构建或操作服务。

## 当前实际进度

| 要求 | 当前状态与证据 |
| --- | --- |
| headless 依赖拆分 | `0015-native-headless-boundary.patch` 新增 `farpane-native`/`legacy-ui` 边界。native Cargo 依赖树没有 GTK3/GDK3、Sciter、tao/tray-icon、winit/softbuffer；native check/Release 编译通过，旧 Flutter/GPU feature 组合 check 仍通过 |
| 独立核心入口 | `--server` 已在隔离容器实际启动：先取得配置 owner、确认同 release 的不可变可执行文件、等待内置 CM listener 就绪，再启动控制接口和旧 Host 网络核心；没有独立 CM/托盘/Flutter 进程。`--service` 已完成受控会话提供者下的真实 root/user 生命周期检查；真实 systemd/logind 尚未验收。`--config-command`/`--config-cli` 支持受限配置。`--viewer <session>` 已有独立入口、认证和媒体线程；完整产品仍为 `runtime_ready=false` |
| 轻量协议 crate | `Linux/native/protocol/` 只依赖 serde/serde_json/libc。具备角色命令范围、密码 Debug 隐藏、64 KiB 控制消息、消息总超时、私有 socket 目录、SO_PEERCRED + SO_PEERPIDFD 稳定身份检查、不可由普通用户修改的 executable 路径检查 |
| GPU 帧合同 | 多 object/layer/plane、FD 数量、代、索引、pitch/offset/size 越界验证与 SDR 默认颜色规则已实现。新增有界 Unix seqpacket + SCM_RIGHTS 通道，异常报文自动关闭收到的 FD。VAAPI/DRM_PRIME 与 GtkGLArea EGL 分平面导入、颜色 shader、GLsync 已接通。独立 256×128 H.264/HEVC 探针以及私有 headless Wayland 的两次实际 GTK 连接通过；不支持时明确回退软件。真实用户桌面/原生 Xorg、长稳与资源目标仍未验收 |
| 监管策略 | `0016-native-host-runtime.patch` 接入 root supervisor 与实际活动计数。精确 exe/UID/argv/start-time + pidfd 选择/停止；连接、待审批、CM 文件任务、视频服务及尚未清理的 GPU owner 阻止空闲维护。未知状态保留进程，独立健康失败持续 60 秒后才走明确故障恢复。虚拟时钟、进程身份与受控会话下的真实 root 监管/UID 切换检查通过；新代码已加入有界 logind 查询、同 UID 登录来源和输入有效期检查；真实 logind、物理输入及显示变化仍未验收 |
| GTK4 首页对接 | 首页状态来自真实 native agent 或离线配置 helper，包含 ID、认证模式、固定密码状态、可用临时密码、GPU 开关/后端。服务器设置、认证、密码、GPU、入站审批/撤权/断开有真实命令路径；允许/拒绝/超时、断开和撤权已有实际连接证据，其他并发与重启矩阵仍待验收。独立工作线程、有界命令队列、状态合并，不在 GTK 主线程等待 IPC；分区切换释放旧 widget。连接按钮已接独立 Viewer、密码/二次验证/不安全连接确认、显示器选择、音频开关和 HUD；真实循环连接已测软件画面。设备管理已有真实持久化与 GTK 验收；音频与受限文件共享已接通，分类富剪贴板、X11 分块 provider 和 Wayland data-control 已接通，跨平台与完整内存验收见后续检查点 |
| 配置与迁移边界 | 首次 Config 访问前持生命周期 flock；运行中 CLI 转发给 agent，离线 helper 不启动 Host；revision 冲突拒绝保存。握手检查版本/release、SO_PEERPIDFD 与 root-owned GUI/core。旧 Flutter FarPane 未使用新锁，因此还检查本产品旧 IPC，避免在线迁移同时写配置。新增 fsync + 两文件恢复记录事务，候选配置在落盘成功后才替换内存；首次安装有单独恢复标记。写失败、三处中断恢复、加密记录、损坏记录拒绝已做隔离测试。准备完成后的落盘故障要求进程恢复，不能继续由旧内存回写 |
| Viewer 只读边界 | `0018-native-viewer-boundary.patch` 在第一次配置加载前选定只读模式；只注入 GUI 提供的公开网络快照，PeerConfig 只在内存保存且不保存密码。旧配置/设备文件读取和写入被隔离，旧 Host/CM/服务 IPC 的连接与监听入口拒绝 Viewer。已接实际 `--viewer`。`0019` 绕开旧视频队列与隐式剪贴板初始化，并拒绝终端 IPC、隐式远程文件动作及语音呼叫 |
| 会话状态模型 | 旧会话/旧代/重复事件不覆盖新状态；只有本地呈现确认可以进入 Streaming。已接 worker 事件与 GTK frame clock 的 after-paint 确认；真实软件画面已验证 |
| 环境与 canonical | 新依赖只装入扩展的隔离 builder；FFmpeg 未重建、宿主包未更改。`prepare-native.py` 在写入前验证整个 staging 操作，保留未知生成目录修改。源码、补丁和两个新 Cargo.lock 均在 Linux 下 |
| 桌面通知与激活 | Host 内纯 D-Bus SNI/DBusMenu/通知已接通；GUI 可经标准 D-Bus 激活并复用窗口，审批仍走已鉴权控制通道。服务重启/消失、GUI 退出、真实批准与无人处理超时已完成私有总线验证；真实 GNOME/KDE、后台注册和睡眠恢复仍待验收 |
| GUI/Host 组合 smoke | 容器内 root-owned 测试 release、普通用户 Host/GUI、私有 Xvfb/D-Bus、无网络/GPU/宿主 socket。真实配置转发、重复 agent 拒绝、不受信任 executable 拒绝、GUI 两次关闭/打开保留同一 Host 均通过；三个分区显示合成配置。maps 无旧 GUI 库，未发现 GTK CRITICAL。该轮未含媒体连接；最新 Viewer 检查已在两个私有 Xvfb 间跑实际 TCP 登录与视频，原始结果另行归档 |

新控制协议当前要求支持 `SO_PEERPIDFD` 的 Linux 6.5+；Ubuntu 24.04 默认内核和 Debian 13 候选满足版本范围，但发行版实测仍未完成。不能静默降级为存在 PID 复用竞态的 `/proc/<pid>/exe` 单次检查。新原生控制接口和 root 对桌面 Host 的会话来源校验使用这一机制；旧 Flutter 构建的权限路径保持原样。

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


## Host 分类剪贴板与 X11 后台检查点（历史：输出仍使用 arboard）

本机共享页已增加文本、富文本、图片各自的发送/接收控件。`SetHostClipboard` 使用既有鉴权、revision 和 durable 配置事务，保存独立 native 策略；旧版开关和音频/文件设置保持原值。无 native 策略时只继承旧文本授权；显式策略损坏时停止共享，并允许用户重新保存。六个实际 GTK 控件已通过 12 次修改、后台确认和原值恢复。

Native Host 连接改用一个剪贴板工作线程，保留最新输入与每连接最新输出；分类授权先于解压和桌面内容读取。X11 先检查有界 TARGETS，仅请求授权 MIME，限制普通属性/INCR 内容与整个来源响应时间，并在选择变化、策略变化或连接撤权后丢弃旧候选。显式撤销保持至连接结束，旧连接选项不能重新授予。Host 所有连接共享一份实际网络发送额度，慢连接保留最新值而不积压大图。没有获准发送的连接时关闭 reader；现有本机剪贴板内容不会因关闭共享而清空。

[Host 剪贴板证据](../../Evidence/LinuxHost/2026-10-16-native-clipboard-host/README.md)记录两次真实 GTK/Viewer/Host/私有 Xvfb 连接，每轮 20 项检查：保留前轮双向文本、HTML/RTF bundle、PNG/SVG、16 次连续复制、失焦/单向授权、控制事件无正文；新增 Host 64 KiB 边界与超限拒绝、卡住来源后的超时恢复、未授权格式不读取正文、入站富文本拒绝、Host 单向收发撤权、实际连接撤权按钮及全关持久化。两轮均保持视频、回收 Viewer 并保留 Host。测试使用独立容器，没有挂载或改变宿主桌面/剪贴板。

38 项协议、6 项普通 GUI、3 项 Host 策略/任务/全局额度测试通过，32 项实际配置进程检查通过，包括重启读取、损坏策略不回退、未知字段和旧 revision 拒绝、其他权限/身份保持。原生 core/GUI Release、旧 Flutter/GPU feature 组合检查、61 文件 staging、3 项准备/5 项 staging 检查及 pin/patch/overlay/lock 核对通过。两轮键鼠/中文输入、文件专用空文件双向与审批/回收回归通过。首次核心 check 发现 arboard provider 要求静态所有权，改为显式有界复制后通过；原始失败日志保留。

本轮样本仍在剪贴板操作前采集，GUI PSS 约 135.7/132.9 MiB、Viewer 13.9/13.6 MiB、Host 110.5/113.2 MiB，不能作为最大图片峰值、首页 60 MiB、GPU 或 A/B 验收。**Host Wayland 后台尚未接通**；X11 当前写入借用 arboard provider，其超大内容输出/转换副本和峰值仍需验证并改成有界 INCR。3 秒约束其他 selection owner 的响应，不保证本地 X server 整体冻结时的恢复。最大图片、Mac/旧版互操作、媒体并发、完整 GUI 其他阶段及原生安装包仍未完成；`runtime_ready=false`，当前开发产物未安装，现有服务保持原状。

## X11 最大字节图片与分块 provider 检查点

Host 已用 `clipboard_x11_writer.rs` 替换 arboard 输出，在既有工作线程内处理请求。PNG/SVG/文本保留原字节，RGBA 按行有界编码；支持 INCR、TARGETS、TIMESTAMP、MULTIPLE。最多四路 INCR，当前/旧 selection 正文共用 256 MiB 保留额度；卡住请求有不活动/总期限，失去所有权不截断已经开始的粘贴。工作线程改为等待 eventfd/X11 FD 和实际期限，没有内容时阻塞休眠。

GUI 增加自定义 ContentProvider，每次异步写最多 64 KiB，共用四个输出额度和正文保留上限，超时取消后残留 GIO callback 只持有单段副本及额度。GDK 缓冲和 RGBA 纹理序列化另计。原始内容、别名和 memfd 共享存储；上限不是整个进程的预算。

`20261016T214813Z` 两次实际 GTK/Viewer/Host/私有 Xvfb 连接各 22 项通过：前轮文本、富文本、PNG/SVG、权限/撤权/焦点/超时/连续复制均回归；新增 128 MiB 发往 Host、134217727 字节返回 GUI 的逐字节核对，以及全关后的单工作线程空闲检查。两轮空闲 0.5 秒 CPU tick 增量为 0，新本地 selection 没有被请求读取；视频保持 Streaming，Viewer 回收、Host 保留，身份和其他设置保持。

发现并保留三类失败：Host 读取每个 INCR 空事件轮固定休眠 5 ms，改为数据到达立即唤醒后最大内容约 575 ms 读取完成；测试来源在 SelectionClear 时过早退出，中断了已开始的粘贴，夹具已修正；GUI 分块输出的早期显式 flush 触发 GIO CRITICAL，现沿用 GDK 的普通 write/close 约定，最终连接无 CRITICAL。没有延长读取总期限、缩小测试内容或隐藏原始失败。

最大字节 PNG 是合法两像素图片加 ancillary 填充，**不是最大像素 RGBA 或跨平台解码验收**。单独 provider 测试验证透明像素、原字节哈希、旧内容传输、并发/保留额度、失效读者和超时恢复；GUI 的真实 GIO 管道验证四个卡住读者、第五个拒绝、取消及恢复。完整大图连接中 GUI/Viewer/Host 的独立 PSS 峰值仍达到约 265–267/377–379/642–676 MiB；详细同期样本见证据，不能相加独立峰值或宣称低内存已达标。网络序列化/加密、候选和分配器保留仍需分析。

Host Wayland、最大像素/RGBA 跨网络、Mac/旧版互操作、实际慢网络多连接、动态媒体并发、完整故障/生命周期/发行版/低内存与原生安装包仍待完成。产物仅在 Build/Linux；未安装、提交、推送或改变现有服务，未重建 FFmpeg。完整 GUI 目标继续进行，`runtime_ready=false`。


## Wayland 后台剪贴板检查点

Host 现通过独立平台层选用 ext-data-control 或 wlr-data-control，在既有线程中处理 CLIPBOARD，不创建窗口或使用 Xwayland 回退。具名 socket/初始化均有期限；仅支持单个明确 seat，继承 WAYLAND_SOCKET 明确拒绝且不消费 FD 或修改环境。读取只请求获准格式；输出复用原字节和有界 RGBA 编码，最多四路传输、256 MiB 独立 selection 保留，替换后旧传输可完成，卡住/关闭读者会释放。界面显示实际后台状态，保存的策略开关不代表合成器已授权。

[本轮证据](../../Evidence/LinuxHost/2026-10-16-native-clipboard-wayland/README.md)包含私有 Sway 两种协议各 24 项、Weston 缺失 data-control 的拒绝、沉默合成器约三秒初始化退出、继承 FD 保留、透明 RGBA 与最大字节 PNG。新 core Release、Host 三项测试和旧 Flutter/GPU check 通过；两轮实际 X11 连接仍通过各 22 项剪贴板检查及最大字节双向传输，两轮输入回归通过。GUI 二进制未变。全部在隔离容器完成，没有访问宿主桌面、GPU 或服务，没有重建 FFmpeg。

这尚不是完整 Wayland Host 媒体网络会话或 GNOME/KDE 验收；多 seat、合成器重启/撤销、最大像素 RGBA、跨平台与完整内存仍待检查。未新增远端专用动态能力字段。完整生命周期/发行版/打包和低内存目标继续推进，原型仍未安装。


## 原生开发包与 Ubuntu 24.04 ABI 检查点

已新增应用构建记录、native manifest 和开发 bundle 打包入口，包含独立 GUI/core、私有 libdrmtap、图标与桌面/服务模板。打包在副本中移除工具链 RPATH，校验源码/二进制对应关系；15 项完整性测试通过。native 库加载仅使用核心所属不可变 release，不借用 current 或系统安装的其他版本；root/普通用户的正常加载、缺库、越界链接和可写库拒绝均完成实际验证。

Ubuntu 24.04 纯运行镜像首次暴露 libva 2.20 缺少 vaMapBuffer2；native 链接新增一次性运行时查询，仅缺失新接口时采用 FFmpeg 已有的 vaMapBuffer 兼容操作。新旧真实符号集合和八线程测试通过，错误不重试旧路径。FFmpeg 静态库没有重建或更换，系统 libva/驱动没有更改。CPU-only native 与旧 Flutter/GPU check 均通过。

最终包在 Ubuntu 24.04 和 Ubuntu 26.04 各通过八类包/库检查及两次实际软件视频连接。随后在现有 FarPane 无连接时，以限定 renderD128、256×128/12 fps 静态内容完成两次私有 Wayland GPU 会话，VAAPI、DMA-BUF、after-paint 和正常回收均确认，测试期间 86 次空闲查询保持零连接，约 17.2 秒。它不是实际用户桌面、Ubuntu 24.04 GPU、1440p、延迟或内存验收。详见 [包与 ABI 证据](../../Evidence/LinuxHost/2026-10-16-native-package-abi/README.md)。

开发产物为 Build/Linux/artifacts/farpane-native-dev-98a34f241b2e1b20a2bcbaba（tar.gz SHA-256：9e31a4401c64db6561b50adc1b6c9740a87eefe577ec2050b5a779a7cd9fc19d）。它尚不是用户安装包：模板仍待绑定不可变 release，原生安装/升级/回退、桌面自启动迁移、完整许可证/源码与 CI、真实桌面/生命周期/功能和低内存门槛仍待完成。旧安装器不会接受此 native manifest；原型未安装、未修改现有服务或身份。


## 原生 root/user 服务生命周期检查点

原生核心现由 root 直接降权启动桌面 Host，不依赖 sudo 包装进程。核对 passwd 身份与私有 runtime 目录，清空 root 环境，设置实际附加组、完整 UID/GID、NO_NEW_PRIVS 和父死亡信号；同用户现存 agent 可接管，其他用户必须先退出。进程按同核心路径、UID、精确角色、start ticks 和 pidfd 识别；停止失败不会启动新的用户授权上下文。实现与权限合同见 [native-service.md](native-service.md)，构建/失败/成功证据见 [服务检查点](../../Evidence/LinuxHost/2026-10-17-native-service/README.md)。

补测发现旧探针要求普通用户读取 root executable，实际被内核拒绝，却被当成超时，导致健康 Host 每分钟误重启。现在 root 仍严格验证 Host 的同核心身份；用户端仅为内核确认的 root 对端开放两种单次、有期限的只读观测，不进入一般 IPC 命令分发。EOF/reset、格式与身份拒绝不再计为超时。随后修正了首次发现桌面被当作显示变化、意外重启已接管空闲 Host 的问题。两次失败均保留原始证据，没有靠延长恢复期限规避。

修复后，真实 core/GUI、私有 Xvfb/用户总线、两个 UID 和受控 loginctl 的 14 项检查通过：正向活动/健康回包、非观测命令与普通程序拒绝、服务接管/直接启动、真实权限/附加组、GUI 关闭、Host 开关、用户总线重建、父死亡、健康 70 秒不重启、实际卡住 65.3 秒后恢复、UID 切换、无会话、正常 root 退出；移除测试服务 CAP_KILL 产生的真实 EPERM 也确认不会开始第二个用户上下文。这里的 root 服务不是替身，但会话提供者是夹具；没有访问宿主桌面或服务。

原生安装事务已在上一轮完成隔离验证，见 [安装证据](../../Evidence/LinuxHost/2026-10-16-native-installation/README.md)。本轮仍不替代真实 systemd/logind、会话发现失败/阻塞、同 UID 登录更换、锁屏/greeter、一小时活动连接、Wayland 桌面、睡眠与网络恢复或完整媒体/内存验收。首页 60 MiB 目标仍未通过。原生版本未安装，`runtime_ready=false`；完整 GUI 目标继续进行。
