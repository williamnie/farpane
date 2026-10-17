# FarPane Linux GPU 媒体重构（linux-host）：原生会话发现与授权

2026-10-17 UTC，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本轮补齐 native root 服务的有界桌面发现、同 UID 登录更换、输入授权有效期与有界重连，并以最终开发包完成隔离验证。完整 GUI 交付目标仍在进行；没有安装、提交、推送或替换宿主服务，`runtime_ready=false`。

## 实际结果

| 检查 | 结果与原始记录 |
| --- | --- |
| 有界查询、属性解析、输入授权有效期 | 3 项单测通过，`logs/native-session-unit-final.log` |
| 输入断线后重连且不重放失败动作 | 1 项真实私有 Unix socket 单测通过，同一日志 |
| core/GUI Release 与 canonical 重建核对 | `logs/native-session-build-final.log` 通过；62 个 GUI/protocol staging 文件及 pin/patch/overlay/lock 一致 |
| 原生无 GPU 与旧版默认特性加 Flutter/GPU | 两个 cargo check 通过，`logs/native-session-feature-checks.log` |
| 最终包的真实 root/user 服务 | `service-runs/20261017T005511Z/result.json`，17 项通过；健康 70 秒不重启，SIGSTOP 后约 64.182 秒恢复 |
| Ubuntu 26.04 | `package-runs/20261017T005812Z`，8 类包/库检查，以及两次实际软件视频/GTK 呈现连接通过 |
| Ubuntu 24.04 纯运行镜像 | `package-runs/20261017T005845Z`，同样的包检查与两次实际软件视频连接通过 |

服务测试使用真实 core、GUI、两个 UID、进程权限/信号/pidfd、私有 Xvfb 和用户总线。新增检查覆盖无 session 标签的桌面服务、多个图形登录时拒绝猜测、错误/格式错误/阻塞查询时保留 Host、同 UID 新登录更换 Host 并保留身份、自定义 XDG 配置目录；保留前轮的接管/降权启动、实际 EPERM、GUI 退出、Host 开关、用户总线恢复、父死亡、健康与故障恢复、用户切换、无会话和正常退出检查。

**loginctl 是受控提供者，root 由测试程序启动；不是真实 systemd/logind 验收。** 两个发行版容器使用同一宿主内核。没有 GPU、宿主显示/用户总线/服务 socket 或外网。输入测试验证协议与 Unix transport，不打开 `/dev/uinput`，不证明实际按键状态恢复。此处的 CPU 软件视频连接也不是 Host GPU 性能验收。

## 实现与回归范围

`Linux/native/discovery.rs` 直接查询 logind 属性，每次 600 ms/32 KiB 上限，不将查询失败当作无桌面。会话 key 包含 UID、SID、leader PID/start ticks 和显示协议。环境取自同 UID 且身份稳定的完整候选，支持绝对 XDG 配置/数据/缓存/状态目录；不从多个进程拼凑。

GNOME/KDE 用户服务常不携带 session ID。仅在有界枚举确认唯一图形登录、候选组件晚于 leader、显示目标一致时允许使用这些环境；多个候选登录或显示目标冲突时报告不可用。Wayland socket 检查用户运行目录、所有者和类型。root 发布的快照两秒过期，查询未知立即撤回。特权 IPC 增加当前 Host 登录来源检查，uinput 连接每 100 ms 复核身份，失效即关闭。

`input_retry.rs` 对失效传输使用 100 ms 连接/发送期限和至少 500 ms 重试间隔，绝不自动重放失败动作。`supervisor.rs` 在会话未知时保留 Host/network，明确登录更换时先结束旧授权上下文；循环错误日志限频。`session.rs` 将完整白名单环境传入既有直接降权启动。

本轮共享源码修改严格限制于以下原生路径，canonical 补丁为 `0036`、`0037`、`0038`：

- `src/platform/linux.rs`：root 服务转入 native 监管循环，native root 的当前用户查询读取有期限的快照。旧循环及非 native 行为保留。
- `src/ipc/auth.rs`：root 侧原有同核心 executable 校验前增加当前 Host/UID/登录来源检查，并为输入连接取得会话 key；不放宽旧身份要求。
- `src/server/uinput.rs`：native handler 使用会话有效期，native 客户端持有必要的重试时点、调用有界重连并限频报告错误；关闭 native 特性时保留原发送/接收路径。

未修改共享 trait/API 签名、Mac/xuanwu、GUI 实现或上游 pin；没有新依赖。新逻辑位于 Linux canonical 模块，checkout 是可由补丁/overlay 重建的生成目录。原生无 GPU 与精确旧 Flutter/GPU 特性组合已检查。完整权限和限制见 [服务合同](service-contract.md)。

## 失败与本机只读观察

早期仅接受带会话标签的环境，`service-runs/20261017T004427Z` 复现了 agent 消失后无法重新启动：root 明确报告 `Desktop environment is not ready for this login session`。原始超时及内部日志保留，没有靠延长等待时间解决。

只读观察本机 GNOME 后确认，一些带显示变量的 ibus/portal/日历组件位于用户服务中，不带 SID/scope；当前用户仅有一个图形会话，候选显示目标一致且有对应用户的 Wayland socket。三个 `native-session-*-shape.json` 只记录字段存在性/一致性，不保存身份和环境值；它们不是原生服务运行或真实桌面验收。随后增加上述有界回退，并以不带标签的私有桌面组件和多个候选登录验证修复。

截图保留在原 `Build/Linux/native-service-smoke` 和 `native-package-smoke` 运行目录；归档收录相关文本/JSON。`source-state.json` 是最终 canonical 快照，不代表早期失败版本。构建记录绑定代码、二进制与特性；最终包在测试前生成，其内文档不包含随后产生的验收结果，本归档补充这些结果。

## 产物与复现

开发包：`Build/Linux/artifacts/farpane-native-dev-8551f05a4f1b3f574d7db215.tar.gz`，23,660,799 字节、276 个清单条目。SHA-256：`50b6834e59939f9eeb69ab9dcb1a44e88b54886fc8c34f3dc19d1d760ac1620c`。

打包核心 SHA-256：`18624e0187e28495463b29560f18e2951be1e4736d80544d66b54b4a4e61f50f`；原始核心 `0dbea0a93f41a6b79f829c4a887671c4a3490744736ddcd18c917c74d5eb7ef4`。区别是打包副本移除了工具链 RPATH。GUI 二进制保持 `b3c509c8e3b3cd98d9dcd7a4f8e38e7748648fb5ff1a15c4876f642863020a80`。

```sh
Scripts/linux/build-native-app.sh /home/user/services/rustdesk-host-perf-20261015
python3 -B Scripts/linux/package-native.py
Scripts/linux/test-native-service.sh Build/Linux/artifacts/farpane-native-dev-8551f05a4f1b3f574d7db215
Scripts/linux/test-native-package.sh Build/Linux/artifacts/farpane-native-dev-8551f05a4f1b3f574d7db215
Scripts/linux/test-native-package.sh Build/Linux/artifacts/farpane-native-dev-8551f05a4f1b3f574d7db215 ubuntu-24.04
```

feature 检查在既有 core 容器内执行 `cargo check --offline --locked --no-default-features --features farpane-native --lib`，再执行 `cargo check --offline --locked --features flutter,hwcodec,drm,farpane-linux,linux-gpu-media --lib`。单测同样使用 core 容器，`--no-default-features --features farpane-native,linux-gpu-media --lib`，分别选择 `farpane_native::discovery::tests` 和 `farpane_native::input_retry::tests`，`--test-threads=1`。容器顺序运行，4 CPU/12 GiB；不执行 reference 中的服务切换脚本。

## 尚未验收

仍需真实 systemd/logind、GNOME/KDE/Wayland、锁屏/greeter、物理输入、睡眠/网络恢复、一小时活动连接和显示环境变化验证。当前仅支持 seat0；同登录中仅环境变化而 logind Display 不变的合成器重启、多个图形登录的无来源环境不在已支持范围。不能以本机环境形状观察代替上述测试。

完整媒体/剪贴板跨平台与并发、1440p GPU 性能/颜色/长稳、整体内存目标、deb/RPM/AppStream/CI、依赖许可证与完整对应源码发布包继续进行。首页 60 MiB 目标没有通过，本轮没有改善或重新测量内存。宿主维护窗口应在独立工作和可审阅产物准备完成后报告。

只读前后记录确认宿主 FarPane MainPID 3212867、active/disabled，RustDesk MainPID 1880443、active/enabled，FarPane current 仍为原 P1 release。四个 FFmpeg 静态库的长度、mtime、SHA-256 不变。没有启动新的代理、唤醒旧实现线程、安装、commit、push 或部署。
