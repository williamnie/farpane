# FarPane Linux GPU 媒体重构（linux-host）：系统事件与后台注册恢复

原生 Host agent 在自己的后台线程监听系统 D-Bus，接入 logind 睡眠通知和 NetworkManager 网络状态。它只请求重新注册，不重启 Host、Viewer、root 服务或媒体管线，不改变系统网络、休眠、显示、身份、密码与权限。GUI 首页显示后台报告的恢复状态。

## 系统事件与边界

- logind `PrepareForSleep(true)` 暂停本模块的快速恢复；随后 `false` 安排唤醒恢复。启动时读取 `PreparingForSleep`，不能把初次读到 false 当成一次唤醒。
- NetworkManager 的 `State` 与 `PrimaryConnection` 用于发现断网后恢复、主连接更换。50/60/70 都允许恢复，局域网远控不要求互联网连通。初次快照建立基线；重复状态不触发重新注册。
- 只接受当前服务 unique owner 的指定路径/接口信号。服务改名/退出会使旧 owner 失效；属性读取指向 unique name，不能自动激活服务或悄悄切换提供者。配置改变会取消旧恢复计划。
- 事件队列最多 32 项；状态通知合并，溢出时撤销待执行恢复并重新同步。每个属性/owner 调用 400 ms，工作线程每次最多处理 32 个事件。系统总线不可用时同一个线程五秒后重连，GUI 和媒体线程不等待它。连接总线本身使用 libdbus 的连接/认证约定，不声称这个过程受属性调用期限覆盖。

没有 NetworkManager 的系统保留核心原有的注册超时与 UDP 重绑定；不冒充已经收到网络变化通知。当前不额外监听同一 PrimaryConnection 内的 DHCP/DNS/地址变化。只有事件监听线程，不申请休眠 inhibitor，不调用 NetworkManager 的 Sleep/Enable/连接修改接口。

## 有限恢复与注册确认

触发后等待 500 ms 合并短时间事件；正在进行的恢复不会被重复事件重置预算。最多执行三次快速注册重启，尝试间隔为 3/6 秒，最后保留 10 秒确认窗口；相邻恢复动作至少两秒。网络明确不可用或系统准备休眠时不执行动作。快速恢复耗尽后显示等待服务器，保留核心已有重试。

注册请求与配置事务使用同一锁，复核 revision 及 Host 开关后才执行。关闭被控或修改设置后，旧恢复不能绕过新状态。此路径复用 `RendezvousMediator::restart()` 的注册循环，原有 Server 与已建立的连接仍由原生命周期拥有，不通过退出/重新拉起 Host 实现恢复。

原生 UDP/TCP 注册连接在建立前捕获请求代；只有该代的成功注册回执才能确认恢复。需要补交公钥的回复与注册拒绝不能当成成功，旧 socket 的迟到回复也不能确认新请求。线上延迟值和注册确认是不同的证据，快速恢复期间及重试耗尽后的界面不会仅凭收到回包宣称恢复完成。此确认约束针对本模块发起的恢复；初次注册和取消恢复后的普通核心状态仍沿用原注册语义，不声称重写了全部服务器部署/授权状态。

首页区分等待网络、准备休眠、正在恢复后台、后台在线和等待服务器。恢复状态是只读快照，包含实际监听能力、恢复代和尝试次数；没有新增提权或服务操作按钮。

## 验证范围

`Scripts/linux/test-native-viewer.sh recovery` 在既有隔离镜像中运行真实 Host、GUI、Viewer、两个私有 Xvfb、私有 D-Bus 的 logind/NetworkManager 提供者，以及只处理固定注册报文的 loopback UDP 服务器。只有合成配置和画面。它不触碰宿主系统总线、网络、服务、GPU 或睡眠状态。

验证必须同时看实际注册报文、后端快照、界面文字、已授权连接/进程保留、画面继续及退出回收。受控信号测试不能代替真正 suspend/resume、驱动/合成器重建、真实网络切换或跨桌面验收。Viewer 自动重新连接与密码库恢复是另外的逻辑，仍需完成；本模块不自动读密码库、不重放输入或恢复已失效的远端授权。

2026-10-17 隔离检查点：`20261017T013412Z` 的 12 项端到端检查通过，恢复后新帧及 Viewer 回收均有实际报告；拒绝注册的首页截图已核对。3 项恢复单测、38 项协议测试、6 项 GUI 测试通过，1 项原有图形测试按运行环境要求跳过。原始失败、修正和运行范围见[证据目录](../../Evidence/LinuxHost/2026-10-17-native-recovery/README.md)。TCP 回执钩子当前仅经编译/源码检查，未做本轮实际 TCP 注册测试。

## 接口依据

logind 信号及属性依据本机安装的 `org.freedesktop.login1(5)`。网络属性、主连接与状态枚举依据 NetworkManager 的 [D-Bus Manager 接口](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.html)和 [API 类型](https://networkmanager.dev/docs/api/latest/nm-dbus-types.html)。实现仅读取属性并订阅信号。
