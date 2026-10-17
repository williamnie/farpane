# FarPane Linux GPU 媒体重构（linux-host）：HUD 与会话诊断

2026-10-16，`codex/linux-host-gpu-media`，HEAD `b01c40b`。本检查点未安装、提交、推送或部署。现有 RustDesk/FarPane 的服务、配置、身份及宿主桌面均未改变；没有重建 FFmpeg，没有操作 Mac/xuanwu，没有唤醒旧线程或派发实现代理。

## 本轮实现

- GUI 与 Viewer 分别按需采样自身 CPU、PSS/USS/RSS/SwapPSS、FD 和线程，HUD 隐藏时停止读取与后台订阅。原来的空指标已替换为实际解码、有效新画面 after-paint、编码包率/字节、队列/租约、本地未呈现候选以及媒体后端信息。
- 静止画面速率归零，未知/过期值显示不可用；区分远端 RTT、解码调用平均时间和本地呈现等待，不声称测得端到端延迟。
- 两侧事件队列共用指标合并/优先丢弃规则，不让指标挤掉认证、权限、回复和生命周期事件。wire sequence 先验证后合并；全关键事件溢出仍按原边界结束。
- 诊断只记录白名单状态/计数，不复制身份、凭据、任意后端原文、输入/剪贴板/文件内容。内存最多 2,000 条/1 MiB，磁盘最多两份各 512 KiB，异步写入队列最多 64 条，私有权限和非阻塞文件锁。
- GTK 保存对话框导出脱敏 JSON；取消不写，日志/导出失败不影响连接。HUD 关闭后保留最后样本并附年龄。未知已有日志、符号链接等拒绝覆写。

详见 [统计定义与诊断合同](../../../Linux/docs/viewer-diagnostics.md)。此脱敏承诺仅覆盖新增诊断功能，不涵盖未经重审的旧核心 stderr/旧服务日志。

## 验证

26 项协议、6 项 GUI、5 项 staging 测试通过。协议测试含实际自身资源读取、停采与重启基线，及指标洪峰/关键事件保序/真实溢出。GUI 测试覆盖敏感字段隐藏、记录容量、磁盘轮转上限、文件锁、未知备份与符号链接保留。native core Release、GUI Release 和旧 Flutter/GPU 组合 check 通过；源码 pin/patch/overlay/lock 及 57 个 canonical staging 文件检查通过。

最终二进制的 HUD 两轮测试使用私有容器、普通用户、Xvfb、实际 Host/Viewer/GTK 和 loopback。正常日志与日志不可写各通过 12 项检查，真实 `/proc` 读数与对应 executable/PID 交叉核对，实际点击 HUD、打开诊断、取消/保存文件对话框，确认关闭 HUD 后停止采样、静止 FPS 为 0、最后快照有年龄、导出失败后仍为 Streaming。Host 身份/配置保持，结束后 worker 回收。

实际输入两轮验证键鼠、中文单次提交、IME 预编辑留在本地、窗口失焦与断开时释放远端按键、HUD 点击不传到远端。测试从实际 GTK 控件分配取得 HUD 位置，再转换为 X11 坐标，并核对 HUD 已开启。

GPU 回归分别使用私有 headless Weston Wayland 与其 Xwayland，各两次连接；只有 renderD128、256×128 静态桌面、虚拟输出上限 12 FPS。每次仅输出一张静态新帧；实际 VAAPI worker、GTK DMA-BUF 绘制、该帧租约完成/回收和重新连接均通过，没有悄悄改用软件帧。保护脚本开始、结束以及运行中查询现有 FarPane 视频连接数，全程为 0；有新连接即只停止该次合成探针。这是显示路径回归，不是 GPU HUD 性能预算或真实宿主桌面验收。

## 保留的中间结果

- `191850Z`：首次 HUD 两轮通过，尚未增加停采后快照年龄和最终队列修正。
- `193005Z`：快照年龄与满队列规则修正后的 HUD 两轮通过；随后只调整输入测试定位方式。
- `193102Z`：输入测试失败，原硬编码的 HUD 坐标点中了新增“诊断”按钮，后续输入进入辅助窗口。改为真实控件分配/坐标转换；没有为通过测试改变产品输入或窗口规则。

旧中间日志中的测试用 GtkFileChooserDialog 弃用提示来自私有无门户后备窗口的自动操作；产品始终使用 GtkFileDialog。后续只对该测试模块显式允许此弃用 API。核心既有 warnings 保留，不通过放宽编译器规则隐藏失败。

## 资源与剩余范围

`memory-summary.json` 来自 HUD 两轮实际软件解码/Xvfb/Cairo 样本，开启 HUD 并请求合成刷新。GUI 与 Viewer 采样时点不同，不能直接相加为预算；它们未包括 Host、root supervisor、文件 worker、合成器和专用 GPU 内存。该结果只验证观测链路，没有证明低内存/低 CPU 目标达成；首页 60 MiB 目标仍未通过。

真实桌面文件门户、最小化/遮挡、高 DPI/多显示器统计、1440p 动态 GPU、完整进程与 DRM client 内存账本、同条件旧新版 A/B、长稳仍待验证。后台注册、睡眠/网络恢复、富剪贴板、实际 root/greeter/用户切换、发行版 ABI、完整原生安装包/升级/回退也仍在整体交付范围。`runtime_ready=false`，完整 GUI 开发目标保持进行中。

```sh
Scripts/linux/test-native-viewer.sh hud
Scripts/linux/test-native-viewer.sh input
python3 -B Scripts/linux/run-native-gpu-test.py --viewer
python3 -B Scripts/linux/run-native-gpu-test.py --viewer --x11
python3 -B Scripts/linux/prepare-native.py --check
```

冻结目录包含原始运行文件、构建/检查日志、最终源码和二进制 SHA-256；不复制临时 symlink 目标，排除项单列。旧冻结证据不修改。

最终二进制运行：

- `hud`：`20261016T193531Z`。
- `input`：`20261016T193247Z`。
- `gpu-wayland`：`20261016T193337Z`。
- `gpu-x11`：`20261016T193430Z`。
