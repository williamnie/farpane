# Host Mode H1b 进展报告 — 原生媒体链路

- 日期：2026-08-07
- 基线机：Mac mini（Mac16,11，M4 Pro，arm64）
- 上游：RustDesk 1.4.9 @ `6c578292e8ebbbec708b76986ba8c4bc7c509747`（pinned）
- 对应设计：`docs/host-mode-design.md` §6.4、§11.1、§11.2、§11.4、§11.6、§26.3

## 1. 当前结论

H1b.1、H1b.2、H1b.3 已完成。已授权的本机测试进程真实跑通 ScreenCaptureKit→VideoToolbox H.264/HEVC 硬编；随后旧版 FarPane 在另一台 MacBook Pro 上连接 Mac mini Host 并正常显示远端画面，Host 的 route-matched Refresh keyframe writer 里程碑成立，断开后采集/编码停止并回到 ready。Host Media ABI、Rust bounded queue、`GenericService::send_video_frame` 与现有 transport 的真实订阅闭环已经证明。

## 2. H1b.1 Host Media ABI 与 Rust producer

- Host Media ABI v1 与 Host Control ABI 分开版本化；只接收编码后的 access unit，不跨 ABI 传原始帧。
- access unit 包含 `hostInstanceId`、connection/codec epoch、display ID/revision、codec、framing、PTS、keyframe/parameter-set flags 和有上限的 bytes。
- Rust 在 ABI 返回前深拷贝压缩包；队列容量为 3。错 instance/epoch/codec、过大包、非单调 PTS、首个 IDR 缺参数集和背压均返回稳定错误码。
- `rdn-native-host` feature 向 `scrap` 注入原生 H.264/H.265 能力；未启用 feature 时保持上游行为。
- feature-gated `video_service::run_native` 将 access unit 包装为现有 `EncodedVideoFrame`/`VideoFrame`，仍调用 `GenericService::send_video_frame`，并保留 subscriber snapshot、`VideoFrameController` ACK、QoS、display/codec switch 和 Refresh→IDR 控制。
- feature-gated Rust 单元测试直接验证 writer wrapper 原样保留压缩 bytes、keyframe、PTS、display index，并在进入 `GenericService::send_video_frame` 前拒绝与协商 codec 不一致的包。
- writer 首帧派发和 RustDesk frame-fetched ACK 只产生一次 route-scoped 脱敏里程碑事件；不包含 peer/connection ID、压缩 bytes、屏幕内容、密码或服务器材料。App 仅接受当前 route 的事件并展示媒体状态。
- RustDesk QoS 的 kbps 在 mediaControl 边界饱和换算为 VideoToolbox 使用的 bps，避免非零历史 QoS 值导致 1000 倍码率偏差。
- Swift `HostControlClient` 在 Host 指针存活锁内完成所有 FFI 调用，stop/destroy 无法与 command/snapshot/media submit 竞态。

## 3. H1b.2 ScreenCaptureKit adapter

- 仅使用 macOS 13 可用 API；单显示器 `SCStream`，`queueDepth=3`，按目标 FPS 设置最小帧间隔。
- 首选 `420f`，同时逐帧识别实际 `420f`/`420v`/BGRA：bi-planar 直达 VT 的逻辑 raw-frame copy count 为 0，BGRA 由系统 pixel transfer 的逻辑值为 1；未知格式拒绝。
- 使用 frame status 与 dirty rect metadata；不做 CPU 全屏 hash、diff 或颜色转换。
- 本机已有 Screen Recording 授权，集成测试实际启动 SCK 并取得桌面帧，未请求或更改新的系统权限。

## 4. H1b.3 VideoToolbox H.264

- 编码 session 设置 RealTime、禁止 frame reorder、H.264 Main AutoLevel、目标 FPS/bitrate/data-rate limit/keyframe interval，并显式要求硬件编码。
- 首个成功 callback 后才读取 `UsingHardwareAcceleratedVideoEncoder` 和 `EncoderID`；本机实测 `hardware=true`、`softwareFallback=false`、encoder ID 非空。
- 输出统一为 4-byte length-prefixed AVCC；关键帧前置 SPS/PPS，首帧和 Rust `requestIdr` 都强制下一帧关键帧。
- App 只在 Rust 建立 subscriber route 并发出 `reconfigure` 后启动 SCK；idle Host 不启动采集。旧 route 的 stop/IDR 由 connection/codec/display epoch 拒绝，不影响新 route。

## 5. 验证与边界

已通过：

- Rust Core release 构建和 Host Media 符号门禁；artifact SHA-256 见 H1b evidence；
- Rust 媒体定向测试 3/3 通过，覆盖 protobuf 字段映射、codec mismatch 和脱敏里程碑 payload；
- 上游 patch `git apply --check --reverse`，证明 patch 与 Vendor 工作树一致且可审查；
- 真实 SCK→VT 集成测试、独立 VT IDR/参数集测试、像素路径合同测试；
- Host media event schema/epoch 合同、Host ABI 生命周期及 Hermes 双注册回归；
- Swift release build 与全量测试。

真机补验结果：

- MacBook Pro 旧版 FarPane 建立真实 active subscriber，远端持续显示 Mac mini 桌面；
- Viewer 自动恢复触发 Refresh，Host 生成带参数集的 route-matched HEVC IDR 并通过现有 Rust writer 发送；
- 同一会话无需重连继续显示，断开后 Host 回到 ready；
- 单行状态中的 ACK 文案未被用户观察到，可能被后续刷新状态覆盖，但远端成功解码提供了更下游的传输证据。

## 6. 下一步

H1b 真实订阅闭环完成，与 H1c Golden Connection 一并收口。下一步进入 H2 性能媒体面。
