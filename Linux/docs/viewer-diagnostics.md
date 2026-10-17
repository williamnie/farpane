# FarPane Linux GPU 媒体重构（hermes）：Viewer HUD 与诊断

原生 GUI 开发接口，2026-10-16。此功能未安装到正在服务的 Flutter FarPane；`runtime_ready=false`。源码在 `Linux/native/protocol/src/telemetry.rs`、`Linux/native/viewer*.rs`、`Linux/gui/src/viewer_hud.rs` 和 `diagnostics.rs`。

## HUD 口径

工具条的 HUD 按钮同时订阅 Viewer 指标并启用 GUI 自身资源采样。隐藏时取消订阅、停止读取 `/proc`，不为了指标创建常驻进程。两个进程各自最多一个按需创建的资源线程；停采后在线程条件变量上等待，再次开启重置 CPU 差分基线。每秒采样自身进程，不枚举其他应用或读取配置。

| 显示/导出字段 | 定义与边界 |
|---|---|
| 接收包/s、KiB/s | 最近约一秒进入媒体队列的有效编码视频 packet 数量与 payload 字节。一个 VideoFrame 协议消息可含多个 packet；不等于画面 FPS，也不含音频、文件、协议头或加密开销 |
| 解码 FPS | 解码器实际输出新帧的差分；静止没有输出时为 0 |
| 呈现 FPS | GUI 在有效 generation、窗口 mapped 且 GTK `after-paint` 后确认的新远程画面数。光标、HUD 或窗口重绘不计；不是显示器扫描完成/光子测量 |
| 解码调用 ms/帧 | 解码线程 `send`/`receive` 调用耗时之和除以该区间输出帧数，包含驱动调用内的等待；不含队列等待、呈现 ACK 等待或 GUI 渲染。没有输出时显示不可用，不冒充 GPU 硬件执行时间 |
| 网络 RTT | Host 通过 TestDelay/QualityStatus 报告的往返估计；原始值超过 15 秒未更新则不可用。不是端到端延迟 |
| 本地等待 | 帧进入 GUI bridge 到对应 `after-paint` 的平均时间，包含本地排队/渲染。不能与 RTT 相加宣称端到端延迟 |
| 候选未呈现 | 本地被替换、旧 generation 或未映射时跳过的画面候选累计数。不是网络丢包，也不证明远端漏帧 |
| GPU 租约 | GUI 当前 pending/inflight 的 GPU 帧借用数量；核心另外导出 `leases`。两端不是同步快照，不能求差当泄漏 |
| 压缩待处理项/字节 | VideoFrame 分组及有效 payload 的预留量，包含当前正在解码的分组；导出名 `queued_groups` |
| `skipped_display_groups` | 非当前显示器的 VideoFrame 分组累计数 |
| `channel_rejected_groups` | 尝试送入有界媒体 channel 时失败的分组数；不涵盖所有网络/解码错误，不是丢帧总数 |
| CPU | `/proc/self/stat` 的 utime+stime 按 `_SC_CLK_TCK` 和单调时间差计算。一个逻辑核满载为 100%，可能大于 100%；首次/重新启用后的首次采样没有差分基线，显示不可用 |
| PSS / USS / RSS / SwapPSS | `/proc/self/smaps_rollup`；USS 为 Private_Clean+Private_Dirty。Private_Hugetlb 单独导出，不混入 USS。缺失/无权限显示不可用，不填 0 |
| FD / 线程 | 自身 fd 目录计数减去枚举所用 FD，自身 stat 的线程数；均为近似快照 |
| 编码/媒体后端/链路 | 实际 decoder 和连接事件；导出只允许已知的 codec/backend 枚举，不复制任意后台字符串 |

GUI 与 Viewer 的 CPU/PSS 是分别采样的，包含各自的采样线程成本。它们不包含 Host、root supervisor、文件 worker、桌面合成器或 GPU 专用内存，不能代替整套产品的资源预算。共享内存分摊会随其他进程存在而变化，资源样本的年龄随导出一并保留。超过约 3 秒的资源/后台样本在 HUD 中显示不可用；诊断关闭 HUD 后仍保留最后一份快照并附 `performance_age_ms`。

后台和 GUI 的指标都是每秒合并的可替换事件。队列满时先移除指标，为认证、权限、回复和生命周期事件留位置；全是关键事件时仍保留原有的溢出终止边界。GUI 在校验 wire sequence 后才合并，不把本地合并误报为缺失 wire 事件。此改动不改变帧租约、同步 fence 或 ACK 时序。

## 会话诊断与导出

工具条“诊断”打开辅助窗口，最多保留 2,000 条且最多 1 MiB 的事件记录。只生成已定义的状态、权限、计数与后端摘要；不复制协议原始 payload、设备/服务器身份、密码、显示器名称、路径、输入、剪贴板或文件内容。自由格式错误/日志被替换为固定摘要。该约束针对此新诊断功能，不表示既有核心的全部 stderr 或旧服务日志都已重新审计。

GUI 进程内使用一个 128 KiB 栈的后台写入线程、64 条有界 channel，失败或拥塞不会等待媒体线程。日志位于 `$XDG_STATE_HOME/farpane/native/`（未设置时 `$HOME/.local/state/farpane/native/`）；应用子目录新建为 0700，日志 0600。`viewer.log` 和 `viewer.log.1` 各不超过 512 KiB，`viewer.lock` 防止多个 GUI 写入者冲突。非自有、非私有、符号链接、多硬链接或未知内容文件拒绝覆写；日志不可用时界面说明，内存中的事件仍能导出。正常运行不持续将每秒性能样本写入日志，以免增加 I/O 和日志量。

“导出脱敏诊断”使用 GTK FileDialog，由用户选择本机位置，异步写入 JSON。取消不写文件；写入失败保留会话和界面，显示重试提示。导出包含事件、丢弃计数、版本、资源范围和最后的性能快照及年龄，不读取/打包应用配置或完整进程信息。它没有改变应用现有的身份和认证策略。

## 复现与后续验证

```sh
python3 -B Scripts/linux/prepare-native.py
Scripts/linux/container.sh Scripts/linux/build-native-core.sh release
Scripts/linux/native-container.sh -c 'cd Build/Linux/gui && cargo test --offline --locked && cargo build --offline --locked --release'
Scripts/linux/test-native-viewer.sh hud
```

`hud` 在私有普通用户容器、Xvfb 与实际 loopback Host/Viewer/GTK 中运行正常及日志不可写两轮。测试用实际 HUD/诊断控件和 GTK 保存对话框，核对对应进程 executable/PID 与 `/proc`，验证开关采样、静止零帧率、取消/成功/失败导出、脱敏和 worker 回收。测试允许的私有 FileChooser 后备实现不代表已验收 GNOME/KDE 文件门户。

真实门户、最小化/遮挡/多显示器高 DPI 的指标语义、1440p 动态 GPU 场景、同条件 CPU/内存开销 A/B、完整进程/GPU 内存账本及长稳仍需后续验收。HUD 数值不是这些验收的替代品；不得把软件 Xvfb 的 PSS 当作真实 VAAPI 桌面预算。
