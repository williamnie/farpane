# Host Mode H1c 进展报告 — Framing 与刷新恢复

- 日期：2026-08-07
- 对应设计：`docs/host-mode-design.md` §6.4、§11.6、§20.3、§26.4
- 状态：H1c Golden Connection 完成；H.264 真机回归保留为后续双 codec 兼容验证

## 0. 验收范围与 codec 策略

当前产品目标为 FarPane 控制端 → Hermes → FarPane Host，不再要求官方 RustDesk 控制端补验收。Host 将同时提供 H.264 与 HEVC 硬件编码能力，由 Rust 会话能力协商选择唯一 codec；同一会话不能同时运行两个编码器。现有旧版 FarPane Viewer 只消费 HEVC，因此首个真实连接先验证 HEVC，H.264 保留为新版控制端可协商的兼容能力。

独立 `HostHEVCEncoder` 已接入 `HostMediaPipeline` 的显式 codec 配置。App 现在分别探测并广告真实 H.264/HEVC 硬件能力，只接受带 codec 的 `reconfigure`，再将 Rust 选出的 codec 与 codec epoch 原样绑定到所选 pipeline、压缩包提交和 encoder-state 上报；缺失 codec 会 fail closed。真实 ScreenCaptureKit 测试分别选择 H.264 与 HEVC，并证明每个 pipeline 只创建所选编码器；HEVC 路径确认硬件编码、VPS/SPS/PPS 与启动 IDR。尚未取得真实 FarPane subscriber/writer/远端画面证据，不能据此宣称 HEVC 端到端已完成。

## 1. H1c.1 framing vectors

新增 `H264FramingAccessUnit`，严格解析 4-byte AVCC 和 Annex-B，能在压缩字节层相互规范化，并检查 SPS、PPS 与 IDR。解析器拒绝截断 length、零长 NAL、空 Annex-B NAL 和无 start code 输入。转换只复制有界压缩包，不接触 raw frame。

`Tests/VideoPipelineTests/Fixtures/h264-framing-vectors.json` 同时保存等价的 AVCC4/Annex-B/SPS/PPS/IDR 向量。它在文件内明确标记为 synthetic/provisional，不冒充官方 RustDesk wire 样本。真实 VideoToolbox 测试产生的两个 AVCC IDR 均再次由该 parser 验证为参数集完整。

生产路径当前仍将 H.264 VT AVCC 标记为 `.avcc` 后交给 Host Media ABI，Rust writer 保持带 framing metadata 的压缩 bytes。Rust 定向测试已证明 writer wrapper 不改写 access unit 字节及其 PTS/keyframe/display metadata；它不冒充远端 decoder 互操作证明。FarPane Viewer 真实连接确认 decoder 接受的 framing 前，不提前选择 AVCC/HVCC→Annex-B 转换位置。

## 2. H1c.2 RefreshVideo→IDR

- Rust `video_service::run_native` 发现当前 service 的 `OPTION_REFRESH` 时，不重启采集/编码器，而是向当前 route 的 connection/codec/display epoch 发 `requestIdr`。
- 新 subscriber 也触发 route-scoped IDR 请求；codec、display geometry 改变才走 service switch/reconfigure。
- Swift 事件解析对 schema、epoch 和 reconfigure 必填项 fail closed；App 仅在 `matchesRoute` 成功时把请求交给当前 pipeline，旧 route 的迟到 stop/IDR 被忽略。
- `HostH264Encoder.requestKeyframe()` 的内部 pending flag 已覆盖 pipeline 使用的带归一化 PTS encode 入口。硬件实测连续证明 startup IDR 与后续 requested IDR 都是 keyframe 且带 SPS/PPS。
- Rust 在远端 Refresh 后只对当前 route 的首个已派发 IDR 发一次 `refreshKeyframeDispatched` 脱敏事件；App 校验 route、keyframe 与 SPS/PPS 后显示“刷新关键帧已发送”。该状态证明 writer 边界，不替代远端可见画面验收。

## 3. 仍需真实连接的门禁

以下项目不能由 fixture 或本机无 subscriber 测试替代：

- Host 将 H.264 与 HEVC 真实能力交给 Rust 协商，并只启动协商选中的编码器；
- 另一台机器的现有 FarPane Viewer 建立 HEVC 会话并实际显示画面；
- 新版 FarPane Viewer 建立 H.264 会话并实际显示画面；
- 确认 access unit 经过 `GenericService::send_video_frame` 和现有 Direct/Relay writer；
- 从远端触发 RefreshVideo，确认同一 VT session 下一帧恢复画面；
- 捕获并固化 FarPane 控制端实际接受的 framing、参数集和 keyframe 黄金样本，再把 provisional fixture 升级为 golden。

2026-08-07 用户已在 MacBook Pro 上使用旧版 FarPane，连接安装新修复包的 Mac mini Host，并明确确认能够正常看到远端画面。这证明 FarPane → Hermes → FarPane Host 的认证、真实订阅、HEVC 兼容路径和远端渲染已经形成闭环，也确认 `--cm` 多开修复后的包可完成连接。旧 Viewer 虽无手动刷新按钮，但其解码恢复自动触发了远端 Refresh；Host 依次显示请求生成关键帧和刷新关键帧已发送，证明 Refresh→IDR→writer 路径成立。用户进一步确认同一会话无需重连、画面持续显示，断开后 Mac mini 回到“可被连接”。单行状态未观察到 ACK 文案，可能已被后续刷新状态覆盖；远端成功解码是更下游的交付证据。H1b/H1c 和 §21 H1 总退出条件满足，可以进入 H2。

FarPane 控制端的最小操作、状态判定和脱敏证据模板后续在 `docs/host-mode-h1-golden-connection.md` 与 `Evidence/HostMode/2026-08-07/h1-golden-connection-template.md` 中同步收敛。

## 4. 首次 FarPane 实链发现：原生 Host 不应启动外部 CM

2026-08-07 首次用旧版 FarPane Viewer 连接 Mac mini 上的新 Host 时，输入密码后每次尝试都会额外启动一个 FarPane GUI/Dock 图标，控制端也没有显示画面。代码追踪确认 RustDesk 入站连接会尝试连接 `_cm` IPC；连接失败时，上游通过当前 executable 启动 `--cm`。FarPane 没有独立 connection-manager 进程模式，Swift App 也不会把 `--cm` 分流，因此该命令错误地再次启动普通 GUI。

`rdn-native-host` 现在仅在原生 Host media binding 已激活时跳过外部 CM 启动与 CM IPC；普通 Viewer 路径以及没有 Host binding 的上游行为保持不变。定向 Rust 测试覆盖 Host bound/unbound 两种分支，完整 Core 已重建，并通过 Host lifecycle 与 Swift 全量回归。新包随后在 Mac mini 上通过旧版 FarPane Viewer 真机连接并正常显示画面，确认原阻塞已解除；该实链尚未替代 Refresh/ACK/teardown 三项剩余验收。
