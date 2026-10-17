# FarPane Linux GPU 媒体重构（linux-host）：双屏连接与枚举生命周期

2026-10-17，`codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。Linux owner 独立完成，未启动新代理或唤醒 Claude；此前 OCS seq 2 已由 v2.1 采纳，本轮读取既有记录，没有新一轮委派。

## 改动与证据

- `Linux/patches/0041-x11-monitor-reply-lifetime.patch`：X11 枚举持有 RandR reply 至迭代结束或 Drop，处理空响应，修复迭代器指向已释放内存。仅增加固定补丁；媒体版本和已有补丁未变。
- `Linux/tests/native_multidisplay_smoke.py` 与 `Scripts/linux/test-native-multidisplay.sh`：原始 GUI、私有双屏 XRandR、实际 TCP 视频、外部 XTest 与远端 XQueryPointer。通用 Viewer 夹具增加独立测试模式。
- 普通 `.7` 双屏测试原先可通过；释放内存填充诊断下旧 Host 认证后意外退出（第二次记录退出码 0，GUI 存活），新核心在相同条件下九项通过。它不是 SIGSEGV、物理桌面或 GPU 崩溃证据。
- 夹具前序错误完整保留：Python 表达式语法；Xvfb 无连接自动 reset。后者通过私有 `-noreset` 修正，不修改宿主显示。

九项覆盖：两屏目录、0→1→0→1 下拉切换、两种实际远端颜色、不同屏幕比例、非零原点鼠标映射、黑边输入拒绝、切屏保持同一 worker、断开回收 worker、关闭 GUI 保留 Host。远端点击分别精确为 `(160,360)` 和 `(720,380)`。

## 候选与范围

最终正常分配器的 bundle 九项双屏检查通过；Ubuntu 26.04（`20261017T080056Z`）和 24.04（`20261017T080130Z`）各六组 dpkg 检查通过，升级后的程序各完成两次实际软件连接。Debian `.8` 为 17,244,844 字节，SHA-256 `cec3cce8b30a9def2d756b90fb7e7bc7fe6cf3ccb62ec6bcce52dcd087d35f0b`，release 为 `farpane-native-dev-3f68a4bc59ff54565b6a31db`。

最新交付文件和哈希写入 `deliverables.json`；二进制与 canonical 来源由 `native-build.json`/`final-check.json` 绑定。逐项运行原始资料位于 `runtime/`，失败与构建日志位于 `logs/`，改动快照位于 `canonical/`。`SHA256SUMS` 覆盖本目录留证文件。

只增量构建核心；GUI 保持 `9e57d7b3…`，FFmpeg 缓存未重建。无 GPU 与原 Flutter/GPU feature 编译检查通过。依赖清单仍为 712 包、2598 材料、45 个待核对条目，清单仅因新二进制、构建记录与固定补丁表重新绑定；不是新增完整许可审计。

全部运行使用隔离容器，最大 4 CPU/12 GiB、断网、普通用户、私有配置与显示，未挂载主机 GPU、桌面、物理输入、服务或密钥。`host-state.json` 对照现有两个服务 PID、安装 current、四个 FFmpeg 静态库。未安装、commit、push、发布或改动 Mac/xuanwu。原生维护切换仍等待用户先前待答复的窗口确认。

真实多屏/热插拔/混合缩放、GNOME/KDE/Wayland、GPU/1440p、Mac 互操作、systemd/logind、硬件音视频、长稳、配对内存 A/B 与 60 MiB 首页目标、完整许可审计及公开 CI 仍未验收。小尺寸静态软件双屏通过不关闭这些检查；完整 GUI 目标保持进行中。
