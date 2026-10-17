# FarPane Linux GPU 媒体重构（hermes）：独立 Viewer 与真实软件画面

2026-10-16，`codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。改动尚未提交；没有安装新 GUI、替换服务、操作宿主桌面、访问 GPU 节点或修改原 RustDesk。FFmpeg 9.0.2 静态库和现有隔离缓存继续复用。

这是完整 GUI 开发中的检查点，**不是完整交付或 GPU Viewer 验收**。独立 Viewer 已能通过实际协议认证、解码并在 GTK 显示远端画面；当前 GUI 明确协商软件兼容模式。

## 已接通

- `--viewer <session>`：私有控制 socket 与帧 socket，核对版本/release/session/稳定进程身份；只注入公开网络快照。网络、媒体线程与 GUI 分离，不进入 Host/CM/托盘入口。
- `0019-native-viewer-worker.patch`：实际会话接新媒体队列，协商已实现的 decoder；绕开旧剪贴板监听与视频队列，拒绝隐式文件动作、语音呼叫和终端 IPC。
- GUI 首页连接、独立会话页、密码重试、二次验证/不安全连接提示、显示器选择、刷新、音频开关、HUD、断开返回。二次验证/显示切换/音频只有代码路径，尚未实际验收。
- 只有本地 frame clock 的 after-paint 确认才能进入“画面正常”。最多保留一个未处理帧；旧代事件不覆盖新状态。退出由后台线程等待/回收自己的子进程，不按进程名终止，也不在 GTK 线程等待。
- 软件 H.264/HEVC 使用现有 FFmpeg，VP8/VP9 使用现有 libvpx，libyuv 转换为 BGRA。sealed memfd 永久禁止写入、缩小和扩大，GDK 持有不可变像素。单帧最多 2560×1600 像素，最多 3 个未归还帧；VP8 关键帧尺寸先检查，VP9 外部帧分配累计最多 96 MiB。
- 压缩队列最多 4 项、累计最多 16 MiB，不丢任意参考包后继续解码。解码与归还具有期限，停止/断开不能被视为 GPU 读取完成。真实 GPU 驱动阻塞与 EGL fence 尚未验收。

## 实际验证

| 检查 | 结果 | 记录 |
| --- | --- | --- |
| core 单测与 Release | 7 通过，含一个子进程测试入口；Release 3m21s | `native-viewer-validation.log` |
| VP8/VP9 真实编码包→新 decoder | 明/暗像素、尺寸、PTS、opaque alpha 与 sealed 内存通过 | 同上 |
| 超大 VP8 关键帧 | 解码分配前拒绝，失败 decoder 不可继续使用 | 同上 |
| 轻量协议 / GUI 状态 | 18 / 2 通过 | `gui-viewer-build.log` |
| 最新 GUI 测试与 Release | 2 通过；Release 9.29s | `gui-viewer-final-build.log` |
| 实际 Viewer 连接 | 8 项通过，连续两次独立 GUI 进程会话 | `native-viewer-smoke-final.log`、`runtime/` |
| 原 Host/首页回归 | 9 项通过；关闭 GUI 保留同一 Host，离线 helper 正常 | `native-viewer-host-regression.log` |
| 旧 Flutter/GPU feature check | 通过 | `native-viewer-legacy-check.log` |
| canonical pin/patch/overlay 重建 | 66 个文件与锁文件匹配 | `native-viewer-source-verification.json` |
| staging 保留未知修改 | 4 通过 | `native-viewer-staging-tests.log` |

真实连接测试在 `--network none` 的容器中运行，只有容器 loopback 可用。Host 和 GUI 分别使用私有 Xvfb `:91` / `:92`，Host 输出合成测试图；root 仅在容器 `/opt` 组装不可变 release，应用降为普通用户运行。GUI 用错误密码触发拒绝，再用合成固定密码登录；实际 VPx 帧经过 worker、SCM_RIGHTS、sealed memfd、GDK texture 和 frame clock。两次都显示画面、回收 Viewer，Host PID/ID/revision/认证状态不变。不是模拟回复或预制图直接送入 GUI。

此直连测试的连接状态没有宣称端到端加密；尚未覆盖 ID 服务器发现和加密握手。最初合成图中的“encrypted”措辞已改为“TCP”，最终截图为真实测试内容。

[`runtime/viewer-0/viewer-window.png`](runtime/viewer-0/viewer-window.png) 为完整会话窗口；`remote-frame.png` 为实际解码像素；`viewer.json` 为受限协议事件及呈现/回收结果。第一轮暴露的 frame clock 已清理 handler 再次 disconnect 问题已修复，最终没有 GLib CRITICAL。双 Xvfb 首次并发创建 socket 目录的测试夹具竞态也已修复；原始失败日志保留于 `initial-failures/`。

## 内存样本的适用范围

以下为 640×480 静态合成桌面、软件 Host 编码与软件 Viewer 解码、Xvfb/Cairo 下相邻时刻的 PSS，单位 MiB。原始值和 `/proc` maps 在每次 `process-sample.json` 与配套文件中。

| 进程 | 第一次 | 第二次 |
| --- | ---: | ---: |
| GUI | 118.1 | 109.2 |
| Viewer worker | 14.2 | 13.1 |
| 本机测试 Host | 123.3 | 123.0 |
| GUI + Viewer | 132.2 | 122.3 |
| 三进程之和 | 255.5 | 245.4 |

这些样本是在测试截图导出后取得，包含其分配影响；同一主机同时充当编码端和解码端，没有 root 服务、真实 GPU 或 1440p 负载。不是平均/峰值、泄漏测试或最终内存预算验收，不能作为低 CPU 或 GPU 成功证据。首页 60 MiB 目标仍未验收通过。

## 必须继续完成

EGL 分平面 DMA-BUF 导入、颜色 shader、GPU 完成 fence、真正的硬解与显存/CPU 验收；键鼠/IME、剪贴板、文件传输、音频实测、重连和完整 HUD/诊断；设备管理/共享策略/SNI/通知/后台与睡眠恢复；root 监管和入站权限/文件验收；最低发行版 ABI、原生打包、升级回退和用户安装包。`runtime_ready=false` 仍有效，没有把软件 Viewer 代替完整目标。

复现：`Scripts/linux/test-native-viewer.sh`；构建用现有 `container.sh` / `native-container.sh` 离线入口。`source-state.json` 记录本轮源码与二进制 hash，`SHA256SUMS` 校验归档。此前阶段证据保持原样。
