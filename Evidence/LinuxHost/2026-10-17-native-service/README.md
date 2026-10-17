# FarPane Linux GPU 媒体重构（hermes）：原生服务生命周期

2026-10-17 UTC，分支 `codex/linux-host-gpu-media`，HEAD `b01c40b`。本轮完成原生 root 服务直接启动/接管桌面 Host、真实进程回收与健康探针的隔离验证，并生成新版开发包。现有宿主 FarPane/RustDesk 没有切换；完整 GUI 目标仍在进行，`runtime_ready=false`。

## 最终结果

- `runs/20261017T000817Z`：修复后的实际构建产物通过 14 项服务检查，持续故障恢复用时 65.314 秒。
- `runs/20261017T001249Z`：最终打包产物再通过同样 14 项检查，恢复用时 65.307 秒。两轮均先让健康 Host 连续运行 70 秒，确认 PID 保持，再注入 SIGSTOP；故障恢复使用实际墙钟，没有缩短生产期限。
- `package-runs/20261017T001214Z`、`20261017T001232Z`：最终包分别在 Ubuntu 26.04 builder 和 Ubuntu 24.04 纯运行镜像中通过八类库/包检查、各两次实际软件解码和 GTK 呈现连接，覆盖错误密码后重试、第二次连接、worker 回收、Host 与配置保留。
- 原生 core/GUI Release、完整 pin/patch/overlay/lock 重建核对和 62 个原生 staging 文件检查通过。原生不带 GPU 的构建检查、现有默认特性加 Flutter/hwcodec/drm/farpane-linux/linux-gpu-media 的构建检查通过；相关进程身份与 NSS 组列表测试在前序本轮日志中通过。

服务测试使用真实 root core、用户 core、GTK GUI、两个 UID、pidfd、信号、用户 D-Bus 和 Xvfb。覆盖接管同用户 agent、清理其他用户 agent、丢失后直接降权启动、环境/UID/组/能力、正向健康/活动回包、非观测命令和普通程序拒绝、GUI 关闭、Host 开关、总线重建、父进程死亡、健康保留、故障恢复、用户切换、无会话及 root 正常退出。移除测试服务的 CAP_KILL 产生真实 EPERM，验证旧 Host 未停止时不启动新用户上下文。

**会话发现由受控 loginctl 夹具提供，root 服务由测试程序启动，不是真实 systemd/logind。** 两个容器发行版共用宿主内核，也不构成其默认内核、GNOME/KDE 或物理桌面验收。没有 GPU、宿主桌面/用户总线/配置/服务 socket 或外部网络挂载。

## 修复与回归范围

`Linux/native/session.rs` 直接从同一不可变 release 启动用户 agent，替代原生路径的 sudo 包装。启动前核对 passwd UID/用户名和私有 runtime 目录，清空 root 环境，仅传入受控桌面变量；正确截断 NSS 附加组，设置全部 UID/GID、NO_NEW_PRIVS 和父死亡信号。设置父死亡信号前重置继承的 SIGTERM handler，防止 fork/exec 间丢失退出信号。

`process.rs` 和 `supervisor.rs` 使用同核心、UID、精确角色参数、start ticks 和 pidfd；检查实际停止结果，失败时保留所有权且拒绝新上下文。初次接管不能被当成显示环境变化。未知活动状态不能当作空闲，真实独立健康失败持续 60 秒后才明确恢复。

补测发现普通用户不能读取 root 的 `/proc/PID/exe`，原有反向鉴权因此拒绝正常探针，而 EOF 又被误归为超时。现在 root 严格认证 Host 身份；用户端仅向内核 UID 0/pidfd 确认的对端提供两种单次、有期限的只读观测，不进入一般 IPC handler。此方向不声称识别 root executable。EOF/reset、格式与身份拒绝不会累积为超时。root DRM/输入/服务配置接口接受范围没有扩大。

现有共享文件的必要修改仅为原生特性内的薄接点：

- `src/platform/linux.rs`：调用原生降权启动，原生启动时允许接管，按停止结果协调用户切换/无会话/退出，取消新启动前无条件强停。
- `src/ipc.rs`：原生用户主 IPC 的 root 请求转入两种只读观测分支。
- `src/ipc/auth.rs`：为该分支取得内核确认的 UID 0 与存活 pidfd。

对应 canonical patch 为 `0034`、`0035`，具体实现位于 `Linux/native/`，哈希在 `Linux/dependencies.lock.json`。关闭原生特性时保留旧 Flutter 路径，未改 Mac/xuanwu、上游 pin 或 GUI 实现；GUI 构建二进制与前一检查点相同，没有新增依赖。详细权限和生命周期合同见 `service-contract.md`。

## 失败记录与证据边界

早期会话夹具仅修改 PATH，未截获上游优先使用的 loginctl；随后只在私有容器挂载受控提供者。最初真实服务无法在不含 sudo 的运行环境拉起 agent，原始日志保留。新启动测试还暴露配置 helper 与新 agent 争抢首次 owner 锁的测试竞态；夹具现在等待实际 listener 接受连接后才查询，不只检查 socket 文件存在。

早期 `20261016T234732Z`、`235224Z` 的 10/12 项通过**不能证明健康监管正确**：缺少健康超过 60 秒的正向条件。新增检查在 `235640Z` 复现了健康 Host 被重启，日志明确记录了错误的 60 秒恢复。探针修复后的 `20261017T000326Z` 又暴露首次发现显示环境造成的 `RestartIdle`，已修正后才得到最终两轮通过。没有删除失败或靠放宽期限使其通过。

归档保留相关文本/JSON 日志；重复的 GUI 截图仍在 `Build/Linux/native-service-smoke/` 原运行目录中，没有删除。早期宽泛日志收集带入的非 FarPane cargo 夹具日志不纳入本归档。`source-state.json` 记录最终 canonical 源码哈希，不能把它当作每个历史失败版本的源码状态；对应构建日志和检查点区分各阶段。

## 产物与尚未验收项

开发包：`Build/Linux/artifacts/farpane-native-dev-65fc50f640bf0f13ac1ff6bb`，271 个条目。tar.gz SHA-256：`bb90658c6249b811c88184d0ce55e898ced3cad8c06772a8e0fabb09dcd731a9`。最终打包 core SHA-256：`9104ec0a8148fd7d37282ce3258457d072c5abf714b0994bff2434b5d23296c6`；构建原文件的哈希另见 receipt，打包只对副本移除构建 RPATH。

四个 FFmpeg 9.0.2 静态库的大小、mtime 和 SHA-256 均保持不变。开始与结束的只读系统状态相同：FarPane current 仍指向 P1，MainPID 3212867、active/disabled；RustDesk MainPID 1880443、active/enabled。没有安装、commit、push、部署或调用其他代理实现。测试结束后只剩四个原有容器。

真实 systemd/cgroups/logind、会话发现失败/阻塞的区分与期限、同 UID 登录切换、锁屏/greeter、一小时活动连接、Wayland/GNOME/KDE 生命周期、睡眠与网络恢复、自定义 XDG 桌面环境仍未验收。完整媒体互操作、性能/低内存、原生 deb/RPM/AppStream、CI、完整许可证/对应源码发布包仍属后续工作。首页 60 MiB 目标没有通过；本轮没有 GPU 或实际用户连接性能测试。原生版本未安装，当前包是可审阅的开发产物。
