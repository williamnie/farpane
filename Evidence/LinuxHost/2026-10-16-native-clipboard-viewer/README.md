# FarPane Linux GPU 媒体重构（hermes）：Viewer 富剪贴板

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本检查点接通原生 GTK Viewer 的文本、HTML/RTF、PNG/RGBA/SVG 数据路径，不代表完整 GUI/Host/安装包验收。`runtime_ready=false`，开发 Release 仅留在 Build/Linux；未安装、提交、推送、修改现有服务或重建 FFmpeg。

GUI 的文本、富文本、图片各有发送/接收开关。正文使用独立 seqpacket + 封印 memfd，控制和视频帧通道不携带正文。后台 owner 保留最新候选，复查策略 revision/epoch；发送前、耗时工作后和 GUI 应用前再次检查。独立网络额度不会挤占键鼠/认证的 1 MiB 额度，但原网络连接仍需传输大图片，不宣称消除带宽竞争。GUI 异步读取有大小和时间上限，保留原始 SVG 格式；当前 selection 的 GDK provider 内存仍须计入总预算。

测试期间修复两处运行问题：

- GDK 可把 SVG 推导成可转换的 PNG MIME，原读取顺序因此改变了表示。现在优先实际提供的 PNG/SVG，仅在原始图片 MIME 均不存在时尝试 Texture 的 PNG 序列化。
- 固定 `clipboard-master` 的 X11 监听在每轮回调后重建订阅并提高序号门槛，遗漏休眠间隔中的新变化。原失败日志中 Host 新 owner 已就绪却没有任何读取请求。`0027` 保持一次订阅及初始门槛；`0028` 将相同 commit 的隔离导出源码接入 Linux 构建。pin/patch/lock 为 canonical，原缓存只读。

核心适配器还处理上游同时给出 PNG/RGBA 的多表示：按授权选择单一类别，拒绝未知/Special，避免解码被禁用的表示；内部数据合同仍限制为单类别、至多三项。具体上限、生命周期与未完成项见 [接口快照](contract-snapshot.md)及 [canonical 合同](../../../Linux/docs/clipboard-contract.md)。

验证结果：

| 项目 | 结果与范围 |
|---|---|
| 协议 | 38 项通过，包括真实子进程 memfd、旧回执/重放、撤权、最新候选、prepare 期间取消、独立控制 socket、owner 退出；不把单元测试当实际桌面通道故障验收 |
| 原生核心 | 4 项格式/压缩/protobuf、2 项独立额度/撤权通过；其余 filtered 测试未计入 |
| GUI | 6 项常规回归通过；1 项需显示的测试在独立私有 Xvfb 显式运行通过，验证两个不透明 RGBA 色块的映射所有权、GDK PNG 序列化及 SVG 原字节选择 |
| 实际剪贴板 | `20261016T203650Z`，两次 GTK/Viewer/Host 真实 loopback 连接，每轮 13 项检查通过，见各 `clipboard-result.json` |
| 输入回归 | `20261016T203754Z`，两轮真实按键、中文单次提交、失焦/断开释放、工具条隔离通过 |
| 文件回归 | `20261016T203821Z`，文件专用认证、分页、审批、空文件双向 SHA-256、worker 退出、Host 保留通过；文件 worker 不启用剪贴板通道 |
| 构建与源码 | 原生 GUI/core Release、旧 Flutter/GPU feature 组合 check、60 个 staging 文件、3 项准备/5 项 staging 测试、完整 pin/patch/overlay/lock 核对通过 |

实际剪贴板每轮的 13 项：文本双向；64 KiB 边界及超限；富文本默认禁用；HTML/RTF/纯文本三格式双向及 X11 INCR；富文本授权不授权独立纯文本；超过控制消息上限的 PNG 双向及上游 PNG/RGBA 多表示；SVG 原字节双向；无额外 settle sleep 的 16 次交替复制；单向撤权；失焦暂停及恢复读取当前选择；全关停止发送；视频保持 Streaming；控制事件不含正文。每轮都确认首帧呈现、错误密码重试、Viewer 回收、Host 保留和身份/配置保持。RGBA 的检查为局部真实 GDK provider/PNG 序列化，未完成 RGBA 跨网络或 Mac 互操作。

保留的失败记录：

| 运行 | 结果 |
|---|---|
| `20261016T202359Z` | X11 测试夹具三处缩进触发 `-Werror`，已修正；未启动会话 |
| `20261016T202415Z` | 本机 SVG 被推导成 PNG，未按 SVG 到达；随后修正原始 MIME 优先级 |
| `20261016T202603Z`、`20261016T202827Z` | SVG 本机发送修复后，Host 新 owner 通知仍遗漏；后者有 MIME 请求与 owner 生命周期日志 |
| `20261016T203545Z` | X11 修复后 SVG/16 次交替复制通过；根窗口未让 GTK 失活，失焦夹具断言失败 |
| `20261016T203650Z` | 改用另一个真实窗口承接焦点后，两轮全部通过；未用延时规避监听丢事件 |

最后两轮剪贴板样本在内容测试前采集：GUI PSS 约 144.15/132.97 MiB，Viewer 14.85/13.49 MiB，Host 118.07/121.01 MiB，全部为 Xvfb 软件媒体。它们不是富剪贴板峰值、首页目标、GPU 或旧新版同条件 A/B 验收。

最终开发二进制 SHA-256：

- GUI：`eb78950afd2721c096d2e709e1da0e76dc221192196e90d1950c2d7eddcbe53c`
- core：`d2921888a8bd52673dfa805780b9d19c1448a7d5789d137a032c12ed917b39cb`

`source-state.json` 记录 canonical 文件和 Release 哈希；每个实际运行保留自己的 `test-binaries.json`，包括失败时的旧版本。`evidence-sha256.json` 校验本目录文件。测试只用隔离容器中的合成数据、私有 Xvfb、loopback、临时配置与凭据；没有宿主桌面/剪贴板、GPU 或现有服务操作。

未完成：Host 分类/方向持久策略、共享页与有界平台 owner、真实远端撤权清理；Wayland/Mac 互操作；大图峰值/慢 owner/媒体并发和通道故障的真实会话；完整 GUI 生命周期、跨发行版、内存目标及可回退安装包。下一阶段继续这些工作，不能把本证据作为完整安装包交付。

```sh
Scripts/linux/test-native-viewer.sh clipboard
Scripts/linux/native-container.sh -c 'python3 -B /workspace/Linux/tests/native_clipboard_provider_smoke.py'
Scripts/linux/test-native-viewer.sh input
Scripts/linux/test-native-viewer.sh files-empty
python3 -B Scripts/linux/verify-sources.py --reference /home/xiaobei/services/rustdesk-host-perf-20261015
```
