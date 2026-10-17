# FarPane Linux GPU 媒体重构（hermes）：原生后台服务

`farpane-core --service` 是 root 监管与采集角色，`--server` 是桌面用户的 Host agent。GUI、Viewer、文件 worker 不由 Host 的定时维护逻辑选择或停止。本实现仍处于开发验收阶段；现有宿主 FarPane/RustDesk 没有切换至此版本。

## 启动、接管与结束

原生分支由 root 直接启动同一不可变 release 的 `farpane-core --server`，不依赖 sudo 包装进程。启动前核对 UID、passwd 用户名及该用户私有的 `/run/user/UID`；HOME 与工作目录来自 passwd，清空继承环境，仅传入已发现的显示、Xauthority、Wayland、用户总线、自定义 XDG 配置/数据/缓存/状态目录及必要基础变量。X11 未提供总线地址时，仅使用该 UID 拥有的运行目录 bus socket。

子进程设置 NSS 返回的实际附加组、全部真实/有效/保存 GID 与 UID，开启 `NO_NEW_PRIVS`，不保留 root 能力。附加组按 `getgrouplist` 的返回数量截断，不能将预分配空间里的零值加入 root 组。设置父进程死亡信号之前重置继承的 SIGTERM handler；父进程消失时结束其直接启动的 agent。

root 建立桌面上下文时，可接管同 UID、同核心文件、精确 `--server` 角色、同登录会话且晚于会话 leader 启动的现存 agent；先清理不匹配的同版本 Host。已有 agent 的父进程仍是原启动者；不能把接管当成重新设置了它的父死亡信号。更换用户、同 UID 的新登录、无桌面或正常退出时，先确认旧 Host 已结束，再允许新授权上下文。停止失败保留原所有权状态，不启动第二个用户的 Host。

进程选择和发信号均核对 executable、UID、完整角色参数及 start ticks，使用 pidfd，忽略仅在检查期间消失的进程。显式故障恢复和桌面上下文结束允许在 SIGTERM 的两秒期限之后使用 SIGKILL，并再次等待；这是 runtime 的恢复策略。原生安装器另有停止合同，不通过 SIGKILL 强制结束普通用户进程，详见 [安装与回退](native-install.md)。

## 桌面发现与授权有效期

native root 循环直接解析 `loginctl show-seat seat0` 与 `show-session` 属性，不调用旧的 shell/桌面环境猜测链。每个查询上限 600 ms、32 KiB；非零退出、超时、重复/缺少属性和观察期间变化均视为未知。只有明确空 ActiveSession 或确认不是本地用户图形会话时，才作为无可用桌面处理。会话身份包括 UID、session ID、leader PID/start ticks 和显示协议；不只比较 UID。

环境发现仅扫描同 UID 的进程，检查起始时间和读取前后的身份；优先使用该登录会话的环境，每个候选完整采用，禁止从多个进程拼凑。DISPLAY 必须是本机显示，Wayland socket 必须位于该用户运行目录且由该 UID 拥有。现代 GNOME/KDE 的部分用户服务不携带 session ID：仅在有界枚举确认该 UID 唯一图形登录、候选桌面组件均晚于 leader 启动且显示目标一致时允许使用；歧义直接报告不可用。自定义 XDG 路径必须是绝对路径。

查询失败保留 Host/network 进程，同时清除 root 的有效会话快照；快照即使没有被清除也在两秒后过期。root 的原同核心 IPC 校验增加当前 UID、精确 Host 角色和登录来源检查，未确定会话时不准入新的特权请求。uinput 连接绑定建立时的会话身份，每 100 ms 检查有效性，未知或登录变化时关闭，避免空闲旧连接继续保留输入权限。客户端发送失败后有界重连，最多每 500 ms 尝试一次；失败的按键/鼠标动作不会自动重放，恢复后只接收后续动作。这里的重连不是已按下按键状态的恢复承诺，物理输入仍需真实桌面验收。

当前支持 seat0。多个图形登录下没有明确来源的环境、早于当前登录的残留用户服务、同登录中仅环境改变但 logind Display 未变的合成器重启，不作为已支持场景。查询和输入协议测试也不等于锁屏/greeter、实际 DRM/uinput 或真实 logind 生命周期验收。

## 活动快照与健康探针

活动快照包含已认证入站连接、待审批、文件任务、视频和清理中的媒体 owner，以及进程 start ticks、generation、单调时钟。过期或未知状态不能作为空闲。活动会话阻止每小时维护；已知空闲才允许维护重启。独立健康请求持续超时至少 60 秒且达到次数门槛时进入明确故障恢复，并记录可能中断连接。

root 发起请求前使用内核提供的对端 UID/PID/pidfd 验证目标为同一不可变核心文件的精确 `--server` 进程，并核对预期 PID/start ticks。接收侧的普通用户无法读取 `/proc/<root>/exe`，因此不能对 root 套用同 UID 的 executable 校验。

用户端为内核确认的 UID 0 对端提供一个窄的观测分支：只接受单次 `NativeActivity(None)` 或 `NativeHealth(None)`，读取和回传都有 800 ms 上限，回传前检查持有的对端 pidfd 仍存活；其他报文直接关闭连接。这个分支不声称识别 root 客户端的 executable，也不调用普通 IPC 命令分发器。普通用户程序仍须通过原来的同核心、UID、角色身份校验。root DRM、输入和服务配置接口的接受范围没有扩大，GUI 仍不能通过本接口管理 root。

明确 EOF/reset、格式错误或身份拒绝归为 `Rejected`，不会累积为持续超时。真实读写超时才进入 `TimedOut`；agent 明确报告 CM 尚未就绪也作为不健康状态。这样既能恢复卡住的 Host，也避免鉴权失败导致正常 Host 每分钟被重启。

## 验证入口与边界

`Scripts/linux/test-native-service.sh [ARTIFACT]` 只在独立容器中运行：私有 PID namespace、`/opt`、`/run`、用户总线和 Xvfb，无网络、GPU、宿主服务或桌面挂载。真实 core/GUI 和两个测试 UID 用于生命周期检查；loginctl 输出由受控夹具提供，不能代表真实 logind 验收。测试文件不会安装到宿主。

测试包含 root 接管、其他用户退出、丢失 agent 后直接启动、实际 UID/组/能力与环境、GUI 打开关闭、Host 开关、用户总线重建、父进程死亡、正向状态查询及非观测命令/普通程序拒绝、健康运行超过 60 秒、实际持续故障恢复、用户切换、无会话及 root 正常退出。移除测试服务的 CAP_KILL 可产生真实 EPERM，以验证停止失败不会开始新用户上下文。

会话发现失败/格式错误/阻塞、无标签用户服务的歧义、同 UID 登录更换和自定义 XDG 目录已加入受控集成测试。尚未验收的门槛包括：真实 systemd/cgroup/logind、greeter/锁屏、实际一小时活动连接、GNOME/KDE 和 Wayland 生命周期、睡眠与网络恢复，以及主机安装后的真实连接。受控会话测试通过不能据此标记 `runtime_ready=true`。
