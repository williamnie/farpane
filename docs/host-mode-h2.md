# Host Mode H2 进展报告 — 性能媒体面

- 最后更新：2026-08-08
- 对应设计：`docs/host-mode-design.md` §15、§26.5
- 状态：H2.1.1–H2.1.8 Swift/系统/Rust queue、writer-loop 与 route-scoped RustDesk QoS RTT/network-delay telemetry 已接入；H2.1.9a–H2.1.9b 已建立 connection-ID 生命周期内的 direct/relay authority registry，并以独立 route-scoped transport event 导出 schema v7 脱敏 evidence；H2.1.10 已完成 encryption/send CPU、loss/reconnect 的生产权威审计；H2.1.11a 已把 native Host 防休眠收敛为仅远控屏幕会话持有的 user-idle assertion，并增加按 PID/类型采样与 active-route gate，H2.1.11b 已提供绑定 production route 的 ready→active→disconnected 生命周期 runner；H2.2.1–H2.2.6 adaptive cadence、telemetry、encode/send、thermal/power、production encoded-queue 与 current QoS network pressure 已接入，H2.3.1–H2.3.5 Rust encoded queue policy、backpressure recovery、encoder generation reset、六类 drop ledger 与 capacity-2 raw-frame handoff 已实现并验证；H2.3.6a 已增加调用正式 C ABI 的本地 Rust queue saturation harness，H2.3.6b 已证明 replacement HEVC IDR 可冷启动 production decoder 并恢复硬件解码；H2.4.1–H2.4.6 已完成 codec/尺寸/像素格式首帧硬编 probe、实际 display target 的保守 production advertisement、本机 4K30 双 codec 首帧证据、真实 active/static 会话 runner 与 30 分钟稳定性 fail-closed profile，H2.4.7a–H2.4.7b 已提供 app-local Host ready/route/pipeline 脱敏 JSONL 状态源及严格 600 秒 no-screen-route idle runner；sleep assertion 真机生命周期、全认证连接计数、上述三个网络/CPU 指标的权威实现、单次跨 Rust/Swift drop-ledger 集成及正式持续性能基线仍未完成

## H2.1.1 可关联的媒体阶段 signpost

新增 `HostMediaStageRecording` 合同与生产 `HostMediaSignpostRecorder`，使用 `io.farpane/HostMedia` 的 `os_signpost` event 记录：

- `capture`：ScreenCaptureKit 完整帧进入 pipeline；
- `encode-submit`：同一帧提交 VideoToolbox；
- `encode-rejected`：VideoToolbox 同步拒绝提交并撤销 in-flight；
- `packet-ready`：VideoToolbox 回调产生压缩 access unit；
- `send-submit`：压缩包提交 Host Media ABI；
- `send-accepted` / `send-dropped`：Rust 有界队列接受或明确拒绝。

所有阶段只公开归一化 PTS（微秒）和压缩字节数；不记录画面、压缩 payload、peer/connection ID、服务器配置或凭据。同一 access unit 的 capture、encode 和 packet 通过 PTS 关联，生产 App 的 send 阶段沿用同一 PTS。

## H2.1.2 线程安全 Host 核心媒体 snapshot

每个 `HostMediaPipeline` 现在拥有独立、线程安全且有界的 `HostMediaTelemetry`，覆盖：

- requested/capture dimensions、pixel format、requested/actual FPS；
- capture callbacks、完整有效帧数、dirty area ratio 最新值/平均值；缺 attachment 时保持 `nil`，不伪造 0；
- 主路径最大逻辑 raw-frame copy count；
- encode submissions/rejections、当前/最大 in-flight，以及有界 PTS latency 关联的 eviction 计数；
- 最近最多 2,048 个 encode latency 样本的 p50/p95/p99；
- encoded packets/bytes、会话平均 bitrate、keyframes；
- Host Media ABI send submissions/accepted/dropped；
- codec、VideoToolbox encoder ID、hardware acceleration 与 software fallback 实际读回；
- 单调时钟 runtime。

采集 callback 与有效帧分开计数；VideoToolbox 同步拒绝时立即撤销对应 PTS 的 in-flight。latency 样本最多保留 2,048 个，待回调 PTS 最多追踪 512 个并记录 eviction，不随长会话无限增长。dirty rect 只在 attachment 存在时按 content bounds 计算，并将重叠求和结果限制到 `[0, 1]`。

## H2.1.3 Host process sampler

每个 active Host route 以 1 秒周期采集当前 FarPane 进程和非敏感系统状态：

- `getrusage` user+system CPU delta / 单调 wall time，保留 latest/peak，允许多核时超过 100%；
- Mach `resident_size` latest/peak；
- `TASK_VM_INFO.phys_footprint` latest/peak，作为 private/physical footprint 门禁指标；
- `task_threads` 当前/峰值线程数，并及时 `vm_deallocate` 内核返回的 thread port 数组；
- `ProcessInfo.thermalState`、Low Power Mode；
- IOKit Power Sources 的 AC/battery/offline/unknown 枚举。

采样器不启动子进程、不读取用户文件、不记录 PID、进程参数或设备身份。首次周期采样延迟 1 秒，避免用极短时间窗产生虚高 CPU；timer 使用弱引用并在 telemetry 释放时取消。

## H2.1.4 system-side sampler

新增 `Scripts/sample-farpane-host-performance.sh`，由操作者传入当前 Host 的精确 PID，避免 Host 与 Viewer 并存时误采另一个 FarPane 进程。脚本每秒记录：

- 当前合并态 HostAgent/Native App 的 CPU、RSS、threads、相对 energy impact、总 sleep assertion 数量，以及按 PID/类型区分的 user-idle/display-sleep assertion 数量；
- WindowServer、videotoolboxd、VTEncoderXPCService 的聚合 CPU、RSS、threads 和相对 energy impact；
- 系统 user/sys/idle CPU、`memory_pressure` free percentage、thermal pressure 与 AC/battery 来源；
- 机器型号、架构、macOS、显示分辨率、采样模式、样本数和实际运行时间。

脚本拒绝覆盖既有证据；H2.1.11a 起 system evidence additive 升为 schema v2，`pmset` 每个周期只读取一次，再以精确 Host PID 区分 `PreventUserIdleSystemSleep` 与 `PreventUserIdleDisplaySleep`。默认 acceptance 模式要求普通场景至少 600 秒、`stability` 至少 1,800 秒。短时检查必须显式使用 `FARPANE_HOST_SAMPLE_MODE=smoke`，因此不能把预检输出误报为性能验收。正常运行示例：

```zsh
Scripts/sample-farpane-host-performance.sh static 600 Evidence/HostMode/2026-08-07/macmini-static <HOST_PID>
```

`top` 的 `POWER` 仅作为同机对比的相对 energy impact，不是焦耳，也不是整机物理功耗；电池场景的真实能耗仍需 Instruments Energy Log 或有权限的 `powermetrics` 证据。系统媒体进程按名称聚合，正式采样前应关闭无关编码任务，避免把其他 App 的 VTEncoderXPCService 计入 FarPane。

## H2.1.5 versioned sanitized evidence export

Host App 在 H2.1.5 首次支持显式设置 `FARPANE_HOST_TELEMETRY_OUTPUT`，在单条 Host media route 停止时写出当时的 schema version 1 JSON diagnostic snapshot。H2.3.4 以 additive version 2 增加脱敏 drop ledger，H2.3.5 以 version 3 增加 raw-frame queue current/maximum depth，H2.1.6b 以 version 4 增加 production Rust encoded queue，H2.1.7 以 version 5 增加 writer-loop wall aggregates，H2.1.8 以 version 6 增加 route-scoped RustDesk QoS network snapshot，H2.1.9b 再以 version 7 增加 route-scoped direct/relay/unknown transport snapshot；旧版本文件均保留为不可变历史证据。未设置时不创建目录或文件；配置值必须是绝对 `.json` 路径。导出使用固定字段 allowlist，不包含 display index、PID、peer/connection/Host instance ID、服务器、凭据、输出路径、画面、压缩 payload、dirty rect 坐标或错误文本。

写入先在目标目录完成唯一临时文件，再以原子 hard-link 发布最终文件；目标已存在或并发写入时拒绝替换，并清理自己的临时文件。每个显式文件只对应一条 route；要记录下一条 route，操作者必须换一个新文件名并重新启动 App。示例：

```zsh
FARPANE_HOST_TELEMETRY_OUTPUT="$PWD/Evidence/HostMode/2026-08-07/mini-route.json" \
  .build/arm64-apple-macosx/release/RustDeskNative
```

该 JSON 是 route-stop diagnostic snapshot，不记录场景标签、系统媒体进程或 Instruments 数据，也不因运行时间短而冒充 §15 的 10/30 分钟验收证据。正式场景仍需同时运行 system-side sampler，并由操作者记录设备、网络和场景上下文。

## H2.1.6a production Rust encoded queue depth primitive

Rust Host media route 现在为容量 3 的 production `sync_channel` 共享一个轻量、线程安全的 current/maximum depth tracker。enqueue counter 与非阻塞 `try_send` 在同一把小锁内提交，避免 consumer 先 dequeue 导致计数乱序；只有成功入队才增加 current/maximum，queue full 或 receiver disconnected 不改变计数。`video_service::run_native` 取得 packet 后立即记录 dequeue；最大深度保留到 route 结束。

定向测试覆盖容量从 0 增至 3、第四包 backpressure 后保持 3、消费后归零且 maximum 保持 3，以及正式 C ABI saturation/replacement-IDR 路径最终 drain。H2.1.6a 本身未修改 C ABI、wire、queue capacity、drop policy 或 Hermes；其导出由下面的 H2.1.6b 完成。详见 `Evidence/HostMode/2026-08-07/h2-rust-encoded-queue-depth.md`。

## H2.1.6b low-frequency Rust queue evidence export

production `video_service::run_native` 在既有一秒 writer/QoS 周期内最多发出一次 `mediaQueueDiagnostic/sample`，route guard 结束或 Host unbind 时先发 `routeStopped` 最终 sample，再发既有 `stopCapture`。事件复用 Host Control callback 的 schema v1 envelope，不增加 C symbol 或 ABI 字段；payload 只含 route epoch/display revision 和聚合的 current/maximum/capacity，Swift 只接受 `current ≤ maximum ≤ capacity` 的正整数容量及匹配当前 route 的事件。事件回调按同一串行队列保持最终 sample 先于 stop，因此 App 在异步 stop/writer 取 snapshot 前记录 finalized。

`HostMediaTelemetry` 对同一路由拒绝容量漂移，保留 sample count、latest current、最大 maximum、capacity 与 finalized；route-stop evidence 升为 additive schema v4。性能判定器现在要求至少一个周期 sample 加最终 sample、固定 production capacity 3、深度有界且 finalized=true；受控 schema v4 smoke 证明完整证据 pass，缺最终 sample 会产出并保留 `status=fail`。该指标不含 peer、服务器、密码、key、payload、画面、RTT、loss、transport type、encryption CPU 或远端 ACK。详见 `Evidence/HostMode/2026-08-07/h2-rust-encoded-queue-export.md`。

## H2.1.7 production Rust writer-loop wall timing

`video_service::run_native` 在真实 subscriber 路径累计两类 route-scoped wall time：`GenericService::send_video_frame` 同步把 message 分发到各连接 channel 的耗时，以及既有 `VideoFrameController` fetch/confirmation wait。它们与 queue depth 共用一秒 writer/QoS 采样边界，并在 route stop 发最终 cumulative sample；Host event callback、C ABI 和 wire 均未新增字段或 symbol。

CoreBridge 只接受 route 匹配、整数且内部一致的累计值；`completed + timedOut == cycles`、maximum 不得超过 total、subscriber dispatches 不得少于 cycles。`HostMediaTelemetry` 再拒绝累计回退和 finalized 后的迟到样本。route-stop evidence additive 升至 schema v5，validator 要求周期 sample + final sample、非零 subscriber cycles、计数/最大值一致及 finalized=true；完整 synthetic fixture pass，缺 writer final sample fail-preserve。

边界必须保持：dispatch wall 只覆盖同步 channel fanout，后续 protobuf、secretbox/DTLS 与 async socket send 在 connection task 中，当前 route token 不能可靠归因；frame-controller wait 也可能在 socket send 完成前被 notify，因此不是 RTT、远端 ACK、loss 或 encryption/send CPU。详见 `Evidence/HostMode/2026-08-07/h2-rust-writer-wall.md`。

## H2.1.8 route-scoped RustDesk QoS RTT/network delay

`video_service::run_native` 现在保留当前帧 `send_video_frame` 返回的精确 subscriber 集合，并在既有一秒 writer/QoS 边界向 `VideoQoS` 请求该集合的聚合快照。快照只导出 subscriber/QoS/已采 delay/已采 RTT/response-delayed 数量、最差有效 network delay 与最差 RTT；peer ID 只用于 Rust 内部关联，不进入 event 或 evidence。没有 `TestDelay` 历史的用户保持 `null`，不会继承控制器用于缺省决策的 150ms。

RTT 来自 pinned RustDesk `RttCalculator.get_rtt()`，达到其最小样本数后才可用；effective network delay 沿用 `UserDelay.avg_delay()` 已有语义。Rust producer、CoreBridge 与 Swift telemetry 三层均拒绝计数越界和 nullable/value 不一致；Swift 只接收匹配当前 route 的事件，保存 latest/route maximum，并拒绝 final 后的迟到 sample。route-stop evidence additive 升至 schema v6，validator 要求周期 sample、真实 delay/RTT availability 与 final sample；完整 synthetic fixture pass，缺 network final sample fail-preserve。

本步不新增 C ABI/wire/Hermes 字段，也不宣称 loss、relay/direct、reconnect、async encryption/send CPU、远端 decode/display ACK 或 input-to-photon latency。RTT/network delay 目前先进入真实性能证据，尚未接入 QualityController。详见 `Evidence/HostMode/2026-08-07/h2-rust-network-qos.md`。

## H2.1.9a–H2.1.9b route-scoped direct/relay transport

Host connection ID 创建后，内部 RAII registry 立即记录建连分支已经权威知道的 direct/relay 类型，并在握手失败、正常退出或异常退出时清理；所有既有 direct access、intranet/TCP punch、IPv6 与 KCP direct 路径保持 direct，只有明确 relay helper 标记 relay。`video_service::run_native` 以当前 display route 的精确 subscriber ID 集合查询聚合值，每秒通过独立 `mediaTransportDiagnostic` 导出 subscriber/direct/relay/unknown counts，route stop 时在 `stopCapture` 前发最终 sample。

Swift 与 evidence 双层要求 counts 完整 partition，unknown 始终显式而不猜测。schema version 7 的性能门禁要求周期 sample、最终 sample 和 `unknownSubscribers == 0`，但本地自动测试不据此声称真实会话使用 direct 或 relay。C ABI、Rust wire 与 Hermes 均未改变。详见 `Evidence/HostMode/2026-08-07/h2-transport-authority-registry.md` 与 `Evidence/HostMode/2026-08-07/h2-transport-telemetry.md`。

## H2.1.10 encryption/send CPU, packet loss and reconnect authority audit

生产链审计确认这三项目前没有可按 current Host media route 关联的权威来源，因此继续保持 unavailable，不新增 schema v8，也不写 0：

- connection task 的 `Stream::send` 同时包含 protobuf、可选 secretbox、Tokio 调度/backpressure 和异步 socket wait；整个 await 只能得到混合 wall time，不能冒充 encryption/send CPU，跨 await 的线程 CPU 计时也不成立；
- direct/relay TCP 的具体 socket 被 `DynTcpStream` 擦除，KCP 又以 TCP variant 包装；pinned `kcp-sys` 只暴露 `waitsnd/sendwnd`，没有可定义 loss percentage 的 retransmission contract；
- client `reconnect_count` 不属于 Host。Host 新 connection ID 或复用 `(peer_id, name, session_id)` 也不能区分媒体恢复、并行远控/文件传输/端口转发和有意的新会话。

所以 dispatch/confirmation wall、process CPU、TestDelay、response timeout、queue drop、socket error、connection-open/session-key reuse 与 Rendezvous retry 均被明确拒绝为代理指标。未来实现分别需要 connection-aware 同步 CPU 观测点、transport-specific optional loss provider，以及带 predecessor/generation 语义的 Host control-session recovery contract；最后一项更适合 H5。详见 `Evidence/HostMode/2026-08-07/h2-encryption-loss-reconnect-authority-audit.md`。

## H2.1.11a native Host user-idle sleep assertion

Host 启动在已隔离 config root 内固定启用 incoming-session keep-awake；authenticated connection RAII 仍是 assertion 生命周期权威。新增纯 policy 后，native Host 只有 `AuthConnType::Remote` 数量大于 0 才持有 assertion，file transfer、port forward、terminal 等非屏幕 scope 不触发；native mode 永远请求 `display=false`，所以不阻止物理显示器熄灭。现有 macOS `WakeLock(display=false, idle=true, sleep=false)` 只对应 `PreventUserIdleSystemSleep`，不覆盖用户显式休眠、盒盖或关机。

system sampler schema v2 每秒保存 Host PID 的总 assertion、`PreventUserIdleSystemSleep` 和 `PreventUserIdleDisplaySleep` 数量。performance run summary 同步升为 v2：active route 每个样本必须 user-idle ≥ 1、display = 0，且 typed counts 不得超过 total；缺 assertion 或 display assertion 泄漏均保存 `status=fail`。route-stop telemetry 仍为 schema v7，Host C ABI、Rust wire、Hermes 与依赖均未改变。当前自动证据尚不冒充 Mac mini 的实际 active/disconnect 生命周期；详见 `Evidence/HostMode/2026-08-07/h2-sleep-assertion-policy.md`。

## H2.1.11b ready → active → disconnected assertion lifecycle runner

新增 `Scripts/run-farpane-host-sleep-assertion-lifecycle.sh` 与独立 validator。操作者先以同一 output prefix 启动 telemetry-enabled Host，再从无 Viewer 的 ready 状态运行脚本；脚本分别保存 `ready-before`、`waiting-active`、`active`、`waiting-ready-after`、`ready-after`，只提示何时连接/断开，不自动操作 GUI、TCC、FarPane 或 Hermes。默认 acceptance 每个稳定阶段至少 10 秒，短时编排必须显式使用 smoke。

生命周期不能只靠 assertion 自证：validator 同时要求断开后出现同 prefix 的 production schema-v7 route evidence，且包含真实 capture frame、accepted packet、finalized writer、非空 finalized transport 和覆盖 active phase 的 runtime。ready 前后 user-idle 必须为 0，active 全程必须 ≥1；所有阶段 display/system-sleep assertion 都必须为 0。summary 使用独立 schema v1、原子 no-replace，失败同样保存完整原因。自动 fixture 只证明合同，Mac mini 真机尚未执行；详见 `Evidence/HostMode/2026-08-08/h2-sleep-assertion-lifecycle-runner.md`。

## H2.2.1 dirty-rect adaptive capture cadence

新增 `HostCaptureCadenceController`，在 negotiated/remote FPS 上限内提供 `idle=3`、`lowMotion=12`、`interactive=30`、`highMotion=60` 四档上限，并由 `HostScreenCaptureAdapter` 通过 `SCStream.updateConfiguration` 更新 `minimumFrameInterval`：

- 降档必须先填满默认 8 帧 rolling window，并满足默认 2 秒最短驻留；
- 状态各自使用低于进入阈值的 hold threshold，避免临界 dirty ratio 来回振荡；
- 从 idle 恢复时保留 latest-frame 快速升档信号，但仍服从最短驻留；
- dirty metadata 缺失、`nil` 或非有限值时立即把内容需求恢复为 highMotion；无 backpressure 时回到会话协商上限，已有压力上限仍然生效，不把未知当作静止；
- idle 仍保持 3 FPS 心跳，不停止 ScreenCaptureKit callback，也不做 CPU 全屏 hash/diff；
- 同一时刻最多一个 configuration update；失败后保留实际已应用 FPS，2 秒退避后重试，旧 stream 的迟到 completion 不影响新 stream。

H2.2.1 本身只使用 dirty area ratio 和变化频率；cadence snapshot 由 H2.2.2 补齐，Swift encode/send pressure 由 H2.2.3 补齐。Rust encoded queue depth 随后由 H2.2.5 接入实时 QualityController；H2.1.8 已提供 route-scoped RTT/effective delay evidence，但尚未作为自适应输入，loss 与 remote viewport 仍需后续小步。尚无正式性能场景，因此不宣称 H2.2 完成或已有性能收益。

## H2.2.2 cadence lifecycle telemetry

`HostScreenCaptureAdapter` 现在以脱敏 `HostCaptureCadenceEvent` 上报 decision、configuration submitted/applied/failed/cancelled；`HostMediaTelemetrySnapshot` 增加：

- 当前 content state、target FPS、最后成功 applied FPS 与 dirty metadata trusted；
- content-state transition 数；
- configuration update attempt、applied、failed、cancelled 计数；
- 当前是否有 configuration update in-flight。

decision 每帧只携带枚举、整数 FPS 和 metadata trust 布尔值，不包含画面、dirty rect 坐标、PID、peer/connection ID、服务器信息或错误文本。异步 update 成功后才推进 applied FPS；失败保留上一实际值，停止 stream 时显式清除 in-flight 并记 cancelled。旧 stream 的迟到 update/stop callback 被 identity guard 丢弃，不污染新 route telemetry。

该 snapshot 经使用面核对只在 `VideoPipeline` 内构造并由测试读取，不属于 Rust ABI、磁盘 schema 或序列化 wire contract。Swift encoder/send、thermal/power 与 production encoded queue pressure 已分别由 H2.2.3–H2.2.5 接入；H2.1.8 的 RTT/effective delay 当前只进入 telemetry/evidence，尚未进入 cadence pressure，loss/relay 等仍不可用。

## H2.2.3 bounded encode/send backpressure

`HostMediaTelemetry` 新增轻量 `HostCaptureBackpressure` 读取面，capture callback 不调用完整 snapshot、不会每帧排序 2,048 项 latency。输入仅包含：

- 当前 encode in-flight；
- 最新一次 encode latency，相对 negotiated FPS 的 frame budget 判断；
- 最近固定 32 个 send accepted/dropped outcome 的 count/drop rate；
- consecutive send drops。

压力状态和 FPS ceiling：

| 压力 | 任一进入条件 | FPS ceiling |
|---|---|---:|
| moderate | in-flight ≥2；latency ≥2× frame budget；连续 drop ≥2；至少 8 项窗口且 drop rate ≥12.5% | 15 |
| severe | in-flight ≥4；latency ≥4× frame budget；连续 drop ≥4；至少 8 项窗口且 drop rate ≥25% | 5 |

最终 target FPS 为 negotiated cap、content tier 与 pressure ceiling 三者最小值。压力升级立即生效，避免继续扩大 backlog；恢复到较低压力必须连续满足默认 8 个 observation 且距上次压力切换至少 2 秒。这样短时恢复不会立刻升档造成二次拥塞。32 项 outcome ring 覆盖写入，不随长会话增长；accepted 会清零 consecutive drop。

snapshot 同步增加 `capturePressureLevel`、pressure transition、latest encode latency、recent send outcome count/drop rate 和 consecutive drops。send outcome 来自 Swift 调用现有 Host Media ABI 后的 accepted/dropped 结果；production Rust encoded queue current depth 由 H2.2.5 独立接入，仍不等同于远端 ACK、RTT 或 loss。

## H2.2.4 thermal and Low Power pressure

同一个轻量 `HostCaptureBackpressure` 现在复用 `HostProcessSampler` 最近一次 1 秒周期样本，不在 capture callback 重复调用 ProcessInfo、IOKit 或 Mach：

- `nominal` 与 `unknown` 不凭空制造压力；
- `fair` / `serious` 进入 moderate，FPS ceiling 为 15；
- `critical` 进入 severe，FPS ceiling 为 5；
- Low Power Mode 开启时至少进入 moderate；
- environment 与 encode/send 压力取较严重者，恢复继续服从完整窗口和 2 秒最短驻留。

首次 environment 状态在 pipeline 启动后的首个约 1 秒 process-sampler tick 可用，并在下一完整 capture frame 进入限帧；不声称同步于系统状态变化的零延迟响应。`unknown` 也不会被展示为 nominal；它保留在 telemetry 中供正式场景判定证据是否充分。

## H2.2.5 production encoded queue pressure

H2.1.6b 已验证并 route-match 的 Rust encoded queue `currentDepth/capacity` 现在进入同一个轻量 `HostCaptureBackpressure`。固定 production capacity 3 下，current depth 2 进入 moderate（15 FPS ceiling），depth 3 进入 severe（5 FPS ceiling）；缺失 sample 保持 unavailable，不当作 0 或拥塞。升级立即生效，恢复仍复用完整 observation window 与最短驻留。

这里只使用可恢复的 current depth，刻意不使用 route-lifetime maximum：maximum 一旦达到 3 就永久保持，若作为实时压力会导致一次峰值后永不恢复。输入先经过 CoreBridge 的 `current ≤ maximum ≤ capacity` 和 telemetry 的同 route capacity 一致性校验，不改变 queue capacity/drop policy、Host ABI、wire 或 Hermes。该压力只描述本地 encoded handoff queue，不是 encrypted writer backlog、RTT、loss、relay/direct 或远端 decoder 状态。详见 `Evidence/HostMode/2026-08-07/h2-encoded-queue-pressure.md`。

## H2.2.6 current route QoS network pressure

H2.1.8 已完成 route/count/availability 校验的 current effective network delay、RTT 与 response-delayed subscriber count 现在进入同一个轻量 `HostCaptureBackpressure`。effective delay `>=150ms` 或 RTT `>=250ms` 为 moderate；effective delay `>=300ms`、RTT `>=500ms` 或当前存在 response-delayed subscriber 为 severe。升级立即生效，恢复复用完整 observation window 与最短驻留；moderate/severe 仍分别只提供 15/5 FPS ceiling，并受 negotiated maximum 限制。

缺少 `TestDelay`/RTT sample 时输入保持 `nil`，不当作 0 或健康网络。cadence 只读取 latest current sample，route maximum 继续只用于 evidence；否则一次网络尖峰会永久阻止恢复。该策略沿用 pinned RustDesk QoS 对 150ms effective delay 的既有边界，并为更高延迟提供保守 severe 档；它不改变 RustDesk QoS、bitrate、wire、C ABI 或 Hermes，也不推断 loss、relay/direct、remote viewport、远端解码/显示或 input-to-photon。详见 `Evidence/HostMode/2026-08-07/h2-network-pressure.md`。

## H2.2.7 local live cadence diagnostic

Mini 真机输入验收观察到 Viewer 编码/呈现约 9–12 FPS，随后约 8.3 FPS，但 Viewer HUD 只有 downstream encoded/presented rate，无法区分 Host 主动降到 low-motion 档，还是目标仍为 30 FPS 而 capture/encode/send/render 中途掉速。

本机 Host 卡片现直接从现有进程内 `HostMediaTelemetry` 投影采集全程均值、target/applied FPS、content state、pressure level 与 configuration update in-flight，并随既有 0.5 秒 Host poll 刷新。字段不通过网络、Host ABI 或磁盘新 schema，也不包含画面、dirty rect、peer/server、地址或凭据。`target/applied=12/12 + lowMotion` 可证明当前核心确实主动应用低活动档；`30/30` 而 Viewer 仍约 8 FPS 则提示继续沿 encode/send/decode/render 定位；target 与 applied 不同或持续调档中则指向 capture configuration lifecycle。

该 UI 是诊断可见性，不是性能修复，也不把 `actualFPS` 的全程均值冒充瞬时帧率。built-core Swift 113/113 与 Release App 构建通过；真实 Mini 读数和持续运动 telemetry 仍待新构建验收。详见 `Evidence/HostMode/2026-08-08/h2-live-cadence-diagnostic.md`。

## H2.2.8 bounded recent capture FPS diagnostic

H2.2.7 的采集全程均值会被长时间静止或历史高帧率稀释，不能回答“最近持续拖拽的 5 秒是否真的升到 30 FPS”。`HostMediaTelemetry` 现额外维护最多 1,202 个单调时间戳，按最近 5 秒窗口计算 capture callback 的近期有效帧率；窗口内不足两帧或最后一帧已离开窗口时明确显示 `0`，不会继续展示过期帧率。固定上限覆盖当前 capture 配置允许的 `240 FPS × 5 秒`，长会话内存不增长，也不读取画面内容。

Host 卡片改为同时显示“采集近5秒/均值”，并继续并列 target/applied、content state、pressure 和调档状态。这样持续运动时可按同一时刻读数分层：近期采集约 30 而 Viewer 仍约 8 FPS，瓶颈位于 capture 之后；近期采集本身约 8，则先检查 dirty-rect 分类、ScreenCaptureKit cadence application 或系统 capture 供给。该指标仍只在 App 进程内使用，不加入 Host ABI、网络、磁盘 evidence schema 或 Hermes。

确定性测试以注入的单调时间模拟 30 FPS，并验证 5 秒无新帧后近期值归零而全程均值保持不变。fresh 定向测试、built-core 全量 Swift 测试和 Release App 构建结果记录于 `Evidence/HostMode/2026-08-08/h2-recent-capture-fps.md`；真实 Mini 读数仍需新构建验收。

Mini 安装该版后的真机读数已确认问题不是 low-motion 主动降档：静止 5 秒为近期/均值 `4.9/19.6 FPS`、target/applied `5/5`、content high-motion、pressure severe；持续拖动时为 `23.4/19.6 FPS`、target/applied `15/30`、pressure moderate 且 update in-flight，Viewer encoded/presented 均为 `19.7 FPS`。因此当前帧率由 pressure ceiling 主导，Viewer 呈现没有在编码值之上再出现明显损失；但仅有聚合 pressure level 仍不能区分 encode、queue、send、network、thermal 的具体触发源。H2.2.9 先补三段近期吞吐，后续再以 pressure component visibility 定位 severe 来源。

## H2.2.9 bounded recent pipeline-stage FPS diagnostic

仅有近期 capture FPS 仍只能把问题分成“采集端”和“采集之后”。Host telemetry 现对编码完成 access unit 与 `rdn_host_media_submit_access_unit` 成功进入 Rust production queue 分别维护同样的 5 秒、最多 1,202 个单调时间戳窗口；Host 卡片显示“采集/编码/入Rust”三段近期 FPS，并保留采集全程均值、target/applied、content state 和 pressure。

三个采样点使用现有真实生产边界：complete ScreenCaptureKit frame、VideoToolbox encoded access unit callback、Rust C ABI 返回 accepted。它们不把 enqueue success 冒充 writer/网络/远端确认：若三者相近而 Viewer 仍低，必须继续查看 Rust writer、network 与 Viewer；若 capture 高而 encoded 低，才指向 encoder/handoff；若 encoded 高而入 Rust 低，结合 drop/queue telemetry 定位 C ABI backpressure。三组 ring 各自固定上限，停止事件超过窗口后归零，不增加 wire、Host ABI、磁盘 evidence schema、依赖或 Hermes 字段。

确定性测试分别注入 30/25/20 FPS 三条时间线并验证显示可分辨，随后推进 6 秒验证三者全部归零。fresh 验证与 arm64 交付记录于 `Evidence/HostMode/2026-08-08/h2-recent-pipeline-stage-fps.md`；真实 Mini 三段读数仍待新构建验收。

Mini 安装三段诊断版后的真机读数为：静止时 capture/encode/Rust admission `23.3/23.4/22.6 FPS`，持续拖动时 `20.8/20.9/20.9 FPS`，两种场景均为 target/applied `15/15`、high-motion、moderate pressure；Viewer encoded/presented 均为 `20.4 FPS`。三段与 Viewer 在约 0.8 FPS 内一致，当前没有 capture→encode、encode→Rust queue 或 Rust→Viewer 的显著吞吐断层；限速 authority 收敛到 moderate pressure ceiling。5 秒近期窗口可能包含调档前样本，因此近期值高于当前 applied 15 本身不证明 SCK 持续违反 pacing。H2.2.10 的具体 cause 与 current/applied 区分成为下一读数。

## H2.2.10 pressure component visibility

Mini 真机已证明 pressure ceiling 主导低 FPS，但原 UI 只有 cadence state machine 经过滞回后的聚合“中/高”，无法知道当前 raw trigger，也无法区分“触发仍存在”和“触发已消失但正在完成恢复窗口”。`HostCaptureBackpressure` 现以单一 assessment authority 同时返回 current observed level 与稳定有序的 cause 集合，原 `level(...)` 直接复用该结果，避免诊断分类和控制策略漂移。

cause 覆盖现有全部策略输入：thermal、low-power、encode in-flight、latest encode latency、consecutive send drops、bounded recent send drop rate、Rust encoded queue occupancy、network delay、RTT 与 response-delayed subscriber。Host snapshot 仅在进程内投影 observed level/cause；本机卡片再使用已有脱敏数值显示具体原因，例如 `Rust队列 3/3`、`网络延迟 350ms` 或 `编码延迟 140.0ms`。若已应用 pressure 仍为 high、current observed 已为 none，则明确显示“滞回恢复中”，不会用空 cause 冒充未知错误。

该变化不调整任何阈值、滞回、queue 或 cadence policy，不加入 Host ABI、wire、磁盘 evidence schema、Hermes 或秘密字段。fresh cause/telemetry tests、built-core Swift 回归、Release App 与 arm64 交付记录于 `Evidence/HostMode/2026-08-08/h2-pressure-component-visibility.md`；真实 moderate 触发源待读取新构建。

## H2.2.11 automatic local live telemetry log

手工复制 Host 卡片读数会中断拖动/滚动并改变被测场景，不能形成连续性能证据。Host App 现为每条媒体 route 自动创建独立 JSONL，在 route start/stop/start failure 强制写入，并在活动期间至多每秒追加一条、每条 route 最多 3,600 个周期样本；达到上限后仍允许最终 lifecycle 记录，不让长连接无限增长。默认目录为 `~/Library/Logs/FarPane/HostMedia/`，文件名含 UTC 时间与随机 UUID，既不会覆盖前一条会话，也不依赖启动环境变量。

schema v1 只记录脱敏性能 allowlist：同一 5 秒窗口的 capture/encode/Rust-admission FPS、全程 capture 均值、target/applied、content/dirty metadata 状态、applied/current pressure 与 cause、encoder/send/Rust queue/network 分量，以及本进程 CPU/内存/thermal/power aggregate。它不记录 local/peer/connection/display ID、server/key/password/credential、文件路径、画面、dirty rect 坐标、压缩 payload 或原始错误文本，也不改变原 route-stop evidence schema。

落盘失败会禁用本 route 后续 live logging 并只输出固定脱敏 stderr，不影响媒体会话。该步骤没有修改 Host ABI、wire、Hermes、cadence/pressure policy、根依赖或已有证据文件；定向 writer 测试、built-core 回归、Release App 和 arm64 交付记录于 `Evidence/HostMode/2026-08-08/h2-automatic-live-telemetry-log.md`。真实 Mini 连续静止/拖动日志仍待新构建采集。

## H2.2.12 strict live-log analyzer

仓库新增 `Scripts/analyze-farpane-host-media-live.py INPUT.jsonl [OUTPUT.json]`，用于在操作结束后严格校验并汇总 H2.2.11 日志。它要求 schema/version、字段 allowlist、从 1 连续 sequence、非回退单调/墙钟时间、唯一 start/final lifecycle、最多 3,600 个 periodic sample、固定枚举与有限有界数值；缺字段、未知字段（包括任何意外敏感字段）、NaN/Infinity、重复 pressure cause、queue 不一致或不完整会话均 fail closed。可选输出使用原子 no-replace，避免覆盖既有诊断。

通过结构校验后，输出 capture/encode/Rust-admission 的 min/median/max、两段 median absolute FPS gap、cadence/content/applied/current pressure/pressure cause 分布，以及按 target/applied/content/pressure/cause 变化切分的连续 regime。`performanceVerdict` 固定为 `diagnostic-only`：短日志可以定位 pressure source 和阶段断层，但不能冒充 §15 的 600 秒/30 分钟正式验收。定向及全部 ScriptTests 结果记录于 `Evidence/HostMode/2026-08-08/h2-live-log-analyzer.md`。

## H2.2.13 sustained near-full queue pressure

Mini 的首份自动日志覆盖 98.4 秒、97 个周期样本并通过 H2.2.12 严格校验。capture/encode/Rust-admission 中位数为 `20.646/20.649/20.509 FPS`，两段 median absolute gap 仅 `0.122/0.000 FPS`；因此没有阶段吞吐断层。队列采样为 `0/3` 59 次、`1/3` 18 次、`2/3` 19 次、`3/3` 0 次，但原策略把每个单次 `2/3` 都立即判为 moderate，造成 40 个 applied-moderate 样本及 `30/30 → 15/15 → 30/30` 循环。send-drop window 峰值仅 `3/32`，没有达到独立 moderate 阈值。

queue near-full 现改为连续三个一秒 production sample 均为 `capacity-1` 才触发 moderate；单次或连续两次 `2/3` 保持 none。实际 full `3/3` 仍立即 severe，recent send-drop、consecutive drop、encode、network、thermal/power 的独立门禁和所有 recovery 行为不变。该变化针对日志证明的 transient occupancy，不降低满队列保护，也不修改 queue capacity、Rust/C ABI、wire、Hermes 或根依赖。

同一日志还证明 dirty metadata 97/97 不可信，content 全程 fail-safe high-motion；这是独立的静态场景效率问题，不在本步用猜测修复。验证与交付记录于 `Evidence/HostMode/2026-08-08/h2-sustained-near-full-queue-pressure.md`。

## H2.2.14 ScreenCaptureKit idle-status fallback

Mini 后续 H2.2.13 真机会话又覆盖 359.6 秒、352 个周期样本并通过严格校验；dirty metadata 仍为 0/352 trusted、content 为 352/352 high-motion，进一步证明该 production route 没有可用 dirty-rect authority。SDK 合同同时明确 `SCFrameStatusIdle` 表示显示内容未变化且没有生成新帧；当前 adapter 此前却和 blank/suspended/started/stopped 一样直接忽略 idle，导致 §11.3 已设计的 frame-status 降级路径实际上没有接入。

adapter 现在只将 `.idle` 送入独立的 fallback observation：连续完整窗口并满足既有 minimum dwell 后才允许降至 idle/3 FPS，且仍保持 `dirtyMetadataTrusted=false`，不把 frame status 冒充 dirty rect。任何 `.complete` 帧若仍缺 dirty metadata，会清空 fallback 窗口并立即恢复 fail-safe high-motion/协商上限；blank、suspended、started、stopped 继续只作为生命周期信号忽略。pressure ceiling、滞回、queue、编码器和网络门禁继续由原 authority 决定。

该变化不读取像素、不做 CPU hash/diff，不新增 timer 或无期停帧机制，也不修改 Host ABI、wire、live-log schema、Hermes、依赖或根配置。验证和交付记录于 `Evidence/HostMode/2026-08-08/h2-screencapturekit-idle-status-fallback.md`；Mini 上能否实际持续收到 idle status、静止档是否稳定以及运动后是否立即恢复仍需要新构建自动日志证明。

Mini 随后的 H2.2.14 真机会话已证明交付身份与构建 `20260808033459` 一致，158.45 秒/156 周期日志也通过严格 schema/lifecycle 校验；但 content 仍为 156/156 high-motion、dirty metadata 0/156 trusted，且没有任何 idle cadence sample。由此不能把 fallback 自动实现冒充真实生效：该 route 没有连续提供可用 idle status，静止与运动阶段仍无法由现有日志区分。下一步必须先记录脱敏的 frame-status 与 dirty-attachment presence/type 分布，再决定是修正 attachment parsing、capture configuration，还是设计新的非像素变化 authority；不得直接猜测固定降帧或加入 CPU 全屏 diff。

## H2.3.1 encoded queue full/disconnect policy

Rust Host media route 的容量 3 `sync_channel` 现在通过单一内部 `try_enqueue_native_media` policy 提交已编码 access unit：

- queue 满载明确分类为 `NetworkBackpressure`，继续返回既有 `RDN_HOST_ERR_BACKPRESSURE`；
- receiver 已关闭明确分类为 `Shutdown`，继续返回既有 `RDN_HOST_ERR_BAD_STATE`；
- 两种拒绝都会把未入队 packet 原样返回给调用边界，不替换或弹出队列中的任何已编码包；
- enqueue 成功后才推进 route 的 `last_pts_us` 并清除 `needs_parameter_sets`，失败仍保留原状态；
- C ABI、错误码、queue capacity 和无 feature 行为均未改变。

定向 Rust 测试先填满 `[keyframe+parameter sets, delta, delta]` 三个包，再提交第四个包；第四个包以 `NetworkBackpressure` 原样返回，receiver 仍严格按前三个 PTS 和 keyframe flags 的原顺序读出。独立测试关闭 receiver 后确认关键帧以 `Shutdown` 原样返回。这证明当前 encoded queue 不采用 newest-wins，也不会为腾位置静默丢弃潜在参考帧；尚未证明 RustDesk 后续 encrypted writer queue、ACK timeout 或真实网络拥塞行为。

## H2.3.2 network backpressure to IDR recovery

Swift `HostControlError` 现在把既有 `RDN_HOST_ERR_BACKPRESSURE` 与 stale epoch / bad state 分开：三者仍属于预期 route drop，只有 encoded queue backpressure 要求 keyframe recovery。App 在收到该结果的同一个 encoder callback 边界，通过 thread-safe、route-local weak pipeline reference 同步调用 `requestKeyframe()`：

- 下一次在请求之后提交给 VideoToolbox 的 H.264/HEVC frame 强制为 keyframe，并携带 SPS/PPS 或 VPS/SPS/PPS；
- 若该 keyframe 仍因 queue 满载被拒，每一次 backpressure callback 都会重新 arm 下一帧 keyframe；
- stale epoch 与 shutdown 不请求 IDR，避免旧 route 的迟到 callback 影响新 generation；
- route-local reference 不读取 AppDelegate 当前 pipeline，因此新 route 即使已经替换属性也不会被旧 callback 操作；
- 该分支仍记录既有 `sendDropped` 并进入 adaptive pressure，不把 recovery 当作 send accepted。

这是 H2.3.2 当时的有界恢复边界；请求前已经提交给 VideoToolbox 的少量 in-flight output 仍可能先完成。下面的 H2.3.3 增加 generation gate 与 session replacement，关闭旧 output 继续进入 Rust submit 的缺口。

## H2.3.3 encoder generation reset and replacement IDR

`HostMediaPipeline` 现在为每个实际创建的 H.264/HEVC encoder 分配单调 generation。收到 queue backpressure 时：

1. 在 pipeline 锁内先使当前 generation 失效、摘除当前 encoder；
2. 旧 encoder 的 access-unit/state/error callback 继续完成自身返回，但 generation gate 禁止它进入 App/Rust submit 或覆盖新 encoder state；已经取到旧 encoder 才发生的同步 encode error 也携带旧 generation，因此不会污染新 route UI；
3. 已完成的旧 access unit 仍收敛 encode latency/packet telemetry，避免 reset 后 `encodeInFlight` 永久悬挂；
4. 专用串行 reset queue 在 VideoToolbox callback 之外调用 encoder 的 `CompleteFrames` + `Invalidate`，避免 callback 内重入等待；
5. 下一帧创建全新 VT session；两个 encoder 的初始 `forceNextKeyframe=true` 保证首个对外 access unit 为 IDR 且携带参数集；
6. pipeline stop 会等待 reset queue 排空，避免遗留旧 session。

若替代 session 的 IDR 仍因 Rust queue 满载被拒，App 会再次走同一 reset；因此不会接受该 generation 后续 delta 再等待偶然关键帧。API 仅使用 Swift package access，不扩大 public product API，也不修改 C ABI 或磁盘 schema。

定向 generation-gate 测试确定旧 generation 在 invalidate 后被拒、新 generation 被接受。两个真实 SCK→VideoToolbox 测试分别在第一代 H.264/HEVC output callback 内触发 recovery，并确认 pipeline 第二个对外 access unit 来自替代 session、PTS 继续单调、是 keyframe 且携带 SPS/PPS 或 VPS/SPS/PPS。该测试证明本机真实编码器 reset 路径，不等同于真实 Rust queue 满载或网络拥塞验收。

## H2.3.4 six-reason drop ledger and evidence schema v2

`HostMediaTelemetry` 现在使用设计中固定的六类 `HostMediaDropReason`，但只有生产链确实接入观测点后才把该项标记为 instrumented；未接入的原因保持 unknown，而不是以 0 冒充“已观察且未发生”：

- `encoderBackpressure`：VideoToolbox 同步/异步 `FrameDropped`，以及 `kVTVideoEncoderNotAvailableNowErr`；异步 drop 通过每帧 PTS context 清理 encode in-flight，并请求下一帧 keyframe；
- `networkBackpressure`：Host Media ABI 明确返回 `RDN_HOST_ERR_BACKPRESSURE`；
- `reconfigure`：`RDN_HOST_ERR_STALE_EPOCH`，以及 encoder generation 已替换后才完成的旧 access unit；
- `invalidFrame`：无效或缺少 status/image 的 complete SCK sample、不支持的 pixel format、VideoToolbox malformed/非背压失败，以及已知 Host Media validation/codec/framing/PTS 拒绝；
- `shutdown`：`RDN_HOST_ERR_BAD_STATE`、pipeline cancel 后到达的 frame/access unit；
- `captureSuperseded`：H2.3.4 当时尚无应用层 raw-frame handoff，因此保持 `instrumented=false`；ScreenCaptureKit 的 idle/blank/suspended/started/stopped 明确表示“未生成 complete frame”，不能把它们误计为 superseded。H2.3.5 已按设计 §11.6 接入 capacity-2 handoff，下面说明新的生产观测点。

未知/未来 Host Media 错误码不猜测为任一六类，单独增加 `unclassified` 完整性计数。所有计数饱和于 `Int.max`，不会因极长会话溢出；`classified + unclassified = total` 可用于检查是否存在尚未解释的 drop。现有 `send.dropped` 保留为 Host Media submit outcome，新的 `drops` 是跨 capture/encode/send 边界的原因 ledger，两者用途不同。

H2.3.4 将显式 route-stop evidence 升级为 additive schema version 2：原 v1 字段保持原名和语义，新顶层 `drops` 为六个固定 `{instrumented, count?}` 指标及 `classified/unclassified/total`。没有 reader 或隐式迁移；旧 v1 文件仍是不可变历史证据，该步骤当时只写 v2 且继续原子 no-overwrite。H2.3.5 已由下面的 additive v3 接续。该变更只涉及本地诊断 JSON 和 package-scope Swift 分类，不修改 Host Control/Media C ABI、Rust wire protocol 或 Hermes。

## H2.3.5 capacity-2 raw-frame newest-wins handoff

`HostMediaPipeline` 现在在 ScreenCaptureKit callback 与 VideoToolbox submit 之间使用专用串行 worker 和总容量 2 的 raw-frame handoff：容量包含一个正在交给 VT 的 active frame 与一个 waiting frame。若 worker 尚未开始，队列可暂存最新两个 frame；满载后新 frame 只替换最老的、尚未提交 VT 的 pending frame，并记录一次 `captureSuperseded`。active frame 一旦被 worker 取出就不可替换，因此本策略不会触碰已经提交 VT 的引用关系，也不会触碰 Rust ordered encoded queue。

每个 complete SCK frame 在 callback 边界先记录 capture geometry/FPS 和归一化 PTS `capture` stage；只有实际 dequeue 的 frame 才产生 `encodeSubmit`。这样 `validFrames - encodeSubmissions` 可以由 `captureSuperseded`、shutdown 或明确的 encoder drop 解释。handoff 的 current/maximum depth 在 pipeline lock 内按同一顺序写 telemetry，避免 queue mutation 与 snapshot 更新乱序；最大值硬限制为 2。cancel 会清空 pending 并按数量记录 `shutdown`，正在处理的 active frame由 generation/active gate 收敛；stop 等待 capture 停止、raw-frame worker 和 encoder reset queue 全部排空后才完成。

生产 pipeline 初始化即把 `captureSuperseded` 标记为 instrumented，0 现在表示“该 route 确实接入观测点且未发生替换”。route-stop writer 改为等待 pipeline drain 后再取 snapshot，并将 evidence additive 升级为 schema version 3：保留 v2 drop ledger，`capture` 新增 `rawFrameQueueDepth` 和 `maximumRawFrameQueueDepth`。旧 v1/v2 文件不迁移、不覆盖；C ABI、Rust wire、Hermes 和根配置均未改变。

## H2.3.6a production C ABI queue saturation harness

Rust `#[cfg(test)]` harness 现在建立真实 `MediaBroker` binding 和 `native_media_begin_route`，保留 production `sync_channel(3)` receiver 不消费，并通过正式 `rdn_host_media_submit_access_unit` C ABI 提交 `[IDR+parameter sets, delta, delta]`。第四个 delta 得到真实 `RDN_HOST_ERR_BACKPRESSURE`；已排队包不被替换。消费一个队列槽位后，以该失败提交相同 PTS 提交 replacement IDR 可成功，证明失败分支没有错误推进 route PTS，且恢复关键帧携带 parameter sets 并保持队列顺序。

harness 只存在于 Rust test build，不增加导出 symbol、feature、依赖、环境开关或生产分支；canonical patch copy 保持逐字同步。它把 H2.3.1 的 helper-level queue policy 提升为正式 Host Media C ABI 边界证据，但还不是单次运行的 `Rust backpressure → Swift drop ledger → VT reset → decoder` 集成测试。Swift 的 error mapping 与真实 H.264/HEVC replacement IDR 目前仍由已有独立测试证明，不能据此宣称测试 decoder 或远端已在强制饱和场景恢复。

## H2.3.6b replacement HEVC IDR to production decoder recovery

真实 `SCStream → HostMediaPipeline → VideoToolbox HEVC encoder` reset 测试现在继续把两代 access unit 送入产品 viewer 使用的 `LiveHEVCDecoder`：

1. 第一代 session 的 startup IDR+VPS/SPS/PPS 通过硬件 decoder 输出 256×144 pixel buffer；
2. 测试随后显式 invalidate viewer decoder，清除其 session 与 parameter-set cache，模拟丢失参考状态后的冷恢复；
3. replacement encoder generation 的首个 access unit 再次经严格 AVCC parser 解析，独立携带 IDR+VPS/SPS/PPS；
4. 同一个 production decoder 类型仅凭 replacement access unit 重建硬件 VTDecompressionSession，并再次输出 256×144 pixel buffer；
5. metrics 最终为 submitted=2、decoded=2、decodeErrors=0、hardwareDecodeActive=true。

该测试在本机具备 Screen Recording 权限和 HEVC 硬编/硬解能力时走真实设备路径；缺权限或硬编能力会明确 skip，不冒充通过。当前 production live viewer 只有 HEVC decoder，因此 H.264 仍只证明真实 encoder generation reset 后产生 self-contained IDR，不声称完成 H.264 decoder recovery。详见 `Evidence/HostMode/2026-08-07/h2-decoder-recovery.md`。

H2.3.6a 与 H2.3.6b 合并形成两端真实边界证据，但仍是两个测试执行：尚未让 6a 的 Rust C ABI `BACKPRESSURE` 在同一进程直接驱动 App 私有 submit callback、schema v3 `networkBackpressure=1`、VT reset 与 decoder。现有可见接口无法从 Swift 建立并暂停内部 `NativeMediaRoute` receiver；增加 test-only exported symbol、Cargo feature、环境开关或 production command 都会扩大共享 ABI/根配置或生产攻击面，本阶段不擅自采用。

## H2.4.1 codec/size-specific first-frame hardware probe

新增 `HostHardwareEncoderProbe`，不再把“16×16 hardware session 可以创建”当成目标尺寸能力证据。每次 probe 固定并记录 codec、width、height、FPS 与 source pixel format，在专用后台队列中：

1. 为精确目标尺寸创建 IOSurface-backed pixel buffer；
2. 以 `RequireHardwareAcceleratedVideoEncoder=true` 创建对应 H.264/HEVC production encoder；
3. 实际提交一帧并等待压缩 callback；
4. 要求首帧是非空 keyframe 且携带 SPS/PPS 或 VPS/SPS/PPS；
5. 仅在首个成功 callback 之后接受 `UsingHardwareAcceleratedVideoEncoder=true` 与非空 encoder ID；
6. creation、submission、callback、timeout 或 software fallback 任一失败均返回稳定 fail-closed reason。

probe 的像素分配保持有界：单边继续接受 Host contract 的 16...16384，但总像素不得超过 7680×4320，避免错误的 `16384×16384` 广告在探测阶段分配约 4 亿像素；这不改变 capture contract 或真实画布，只约束尚未广告的 capability probe。当前本机 1920×1080@30、NV12 full-range 的 H.264 与 HEVC probe 均真实输出关键帧并读回 hardware=true；证据见 `Evidence/HostMode/2026-08-07/h2-hardware-encoder-probe.md`。

H2.4.1 只提供可信探测原语；下面的 H2.4.2 已接入 App。不能仅凭本测试结果直接宣称任意尺寸、持续吞吐或 Intel HEVC 可用。

## H2.4.2 actual-display conservative capability advertisement

App 已删除旧的 16×16 global boolean 与固定 `16384×16384@60` 广告。每个 Host instance 首次 snapshot 时，在主线程读取所有 `NSScreen` 对应 `CGDisplay` 的物理像素与刷新率，形成能覆盖任一当前显示器的保守包络：`max(width) × max(height)`，FPS 上限为当前最高刷新率与 60 的较小值。包络必须先通过 H2.4.1 的有界门禁；无法取得显示器或像素数超出 probe 安全边界时不广告任何 codec。

`HostHardwareEncoderCapabilityDiscovery` 在后台按 `[display cap, min(30, cap), min(15, cap)]` 去重后的降序档位，对 H.264 和 HEVC 分别执行真实首帧 probe：

- 两个 codec 只有在**同一个精确 FPS 档**都通过时才共同广告，shared `maxFPS` 就是该档；
- 不把 H.264@60 与 HEVC@30 拼成未经证明的 shared 结果；
- 若没有共同档，遵循 §11.5 兼容优先级，只广告已通过精确档位的 H.264；仅 H.264 全部失败时才广告独立通过的 HEVC；
- 所有档位失败则 fail closed，UI 明确显示当前显示器尺寸没有通过硬编首帧验证；
- 发给现有 Host Media ABI 的 maxWidth/maxHeight/maxFPS 全部来自该次 discovery，不再使用静态上限。

probe task 由 Host instance ID 与随机 probe ID 双重约束；Host stop、切到 viewer 或新 instance 会 cancel 并清空 token。即使底层 VideoToolbox callback 迟到，也必须同时匹配当前 client identity、snapshot instance 与 active runtime 才能写入 capability，旧结果不能污染新 Host。此步骤不修改 C ABI、Rust wire、Hermes 或根配置。确定性测试覆盖 shared tier 降级、无共同档时 H.264-only、全部失败 fail closed 与危险 display envelope 拒绝；证据见 `Evidence/HostMode/2026-08-07/h2-hardware-capability-advertisement.md`。

## H2.4.3 4K30 first-frame hardware evidence

在同一 `HostHardwareEncoderProbe` production path 上增加本机 3840×2160@30、NV12 full-range 的 H.264 与 HEVC 真实测试。两者都实际分配 4K IOSurface-backed buffer、提交强制关键帧并收到非空压缩 callback；H.264 携带 SPS/PPS、HEVC 携带 VPS/SPS/PPS，callback 后 `UsingHardwareAcceleratedVideoEncoder=true` 且 encoder ID 非空。

该证据只关闭“当前机器能否为该 codec/像素格式/尺寸完成硬件首帧”的能力门禁。单次 callback 在约束上不能证明持续 30 FPS、实际码率、capture/encode/send backlog、CPU/WindowServer/videotoolboxd、内存、能耗或 thermal；因此不把 H2.4.3 写成 4K30 性能基线。当前证据也不能外推 Intel HEVC，Intel 仍须在对应机器运行同一 probe。详见 `Evidence/HostMode/2026-08-07/h2-hardware-encoder-probe.md`。

## H2.4.4 real-session performance scenario runner

新增 `Scripts/run-farpane-host-performance-scenario.sh` 与独立标准库判定器 `Scripts/validate-farpane-host-performance.py`，把一次真实 FarPane Host 会话的三类证据绑定为同一个拒绝覆盖的 output prefix：

- `*.system.samples.csv` / `*.system.json`：H2.1.4 每秒系统进程采样；
- `*.route.json`：production App 在 route stop 后原子写出的 schema v7 脱敏 telemetry；
- `*.run.json`：判定器汇总的场景合同、Host/WindowServer/media services CPU、首末 RSS、pass/fail 和完整失败原因。

runner 只接受 `1080p30`、`4k30-normal`、`4k30-video`，默认每次至少 600 秒；短时预检必须显式设置 `FARPANE_HOST_SCENARIO_MODE=smoke`。它要求操作者传入精确 Host PID，不猜测 Host/Viewer 进程；采样结束后等待 Viewer 断开，以便 production route-stop writer 完成 telemetry。判定器检查真实画布、negotiated FPS、首帧后 hardware=true、software fallback=false、有效 capture/encode/Rust writer 包、raw queue 容量和 drain、Rust encoded queue 周期/final sample 与 capacity、route-scoped QoS delay/RTT 周期/final sample、encoder in-flight drain、drop ledger 完整性、整段 route runtime、每秒系统样本、active route 的 user-idle assertion 存在且 display assertion 为零，以及 §15.3 对应场景 Host 平均 CPU 上限。失败也会原子写 `status=fail` 和原因，不删除原始证据或降低分辨率重跑冒充通过。

正式 1080p 示例（`OUTPUT_PREFIX` 必须与 App 启动时的 route 文件前缀一致）：

```zsh
OUTPUT_PREFIX="$PWD/Evidence/HostMode/<date>/macmini-1080p30"
FARPANE_HOST_TELEMETRY_OUTPUT="$OUTPUT_PREFIX.route.json" \
  /path/to/FarPane.app/Contents/MacOS/RustDeskNative

# 远端 FarPane 已显示画面后，在另一终端运行：
Scripts/run-farpane-host-performance-scenario.sh \
  1080p30 600 "$OUTPUT_PREFIX" <HOST_PID>
```

synthetic smoke 仅验证 runner 编排和判定合同：route 侧使用无 payload 的受控 schema v7 fixture，system side 使用 schema v2 typed-assertion fixture；完整 queue/writer/network/transport periodic+final 与 user-idle-only 路径产出 `status=pass`，缺任一最终 sample、unknown transport、缺 user-idle assertion 或存在 display assertion 均产出并保留 `status=fail`。该测试不是 FarPane 性能数据，不能替代 M4 Pro Mac mini 上真实 10 分钟会话、Instruments 或 Intel 功能门禁。证据见 `Evidence/HostMode/2026-08-07/h2-performance-scenario-runner.md`。

## H2.4.5 connected-static performance contract

同一 runner 新增 `static-1080p30` 与 `static-4k30`，不允许把低分辨率或低 negotiated FPS 冒充静态优化。除 H2.4.4 全部 route/system 门禁外，static profile 要求 Host 平均 CPU `<10%`、最终 trusted idle cadence、target/applied 3 FPS、整段 route 平均 capture FPS `>0 && <=5`、至少一次成功 configuration update、零 update failure/cancellation 且 stop 时无 update in flight。该步骤引入 run summary additive schema v3；H2.4.6 随后升为 v4 并保留全部字段。既有 active profiles 不应用 static-only gate。

自动 fixture 已覆盖 1080p/4K static pass、未降帧、CPU 等于 10%、untrusted/update failure/in-flight fail-preserve、active profile 兼容、no-Viewer runner 失败留证、600 秒 acceptance guard 与 no-replace。它们不构成真实性能结果；Mac mini 仍需保持真实静态桌面 600 秒。证据见 `Evidence/HostMode/2026-08-08/h2-connected-static-performance-contract.md`。

## H2.4.6 30-minute stability performance contract

同一 runner 新增精确 1080p/4K stability profile，并由 runner、sampler、validator 三层独立要求 acceptance 至少 1800 秒。系统侧每秒样本按六个连续窗口取 CPU/RSS/thread 中位数，区分超出 noise floor 的全程持续上升与非单调但明显的首末 RSS/thread 增长；route 侧要求六类 drop reason 完整可归因、final encoded queue drain、零 writer timeout/response-delayed、cadence update 收敛和有效 process samples。system sampler schema v3 在 Host 中途退出时仍保存 partial/completed/exit-status，runner 继续生成 fail summary；run summary additive schema v4 保存窗口与 drop counts。

自动 fixtures 已覆盖 1080p/4K pass、CPU/RSS/thread 持续上升、noisy RSS 明显增长、route ledger/convergence 失败、短 acceptance、active 兼容、no-Viewer 失败留证与 no-replace；synthetic 六样本只验证算法，正式 1800 秒每窗为 300 个真实样本。证据见 `Evidence/HostMode/2026-08-08/h2-stability-performance-contract.md`。

## H2.4.7a app-local Host runtime-state evidence

新增 default-off 的 `FARPANE_HOST_STATE_OUTPUT=<absolute.jsonl>`，App 每秒最多一次追加脱敏 runtime state，Host/route/pipeline 生命周期转换强制留样。schema v1 只允许 sequence/time、Host runtime/ready 状态、Rust snapshot observed timestamp 与 media route/pipeline booleans；未知状态 fail closed，不记录 ID、server、credential、错误详情或媒体内容。

4 个定向测试覆盖 exact allowlist、1 Hz throttle、forced route transitions、默认关闭、拒绝覆盖/歧义路径和未知状态；全量 104 项测试（4 项按条件跳过）0 failure，release App 编译链接通过。本步骤不修改 Rust HostSnapshot/C ABI。因为所有认证连接的 aggregate count 仍只存在于 Rust `AUTHED_CONNS`，当前证据只能证明 Host ready + no screen media route/pipeline，不能冒充 file/port-forward 等也为零。详见 `Evidence/HostMode/2026-08-08/h2-host-runtime-state-evidence.md`。

## H2.4.7b strict idle runner

新增固定场景 `host-ready-no-screen-route` 的独立 runner/validator，按 source byte offset 与 inode 把 App 1 Hz runtime-state 切成窗口专属、拒绝覆盖的 JSONL，并与同 prefix system schema-v3 证据绑定。acceptance 在 runner、sampler、validator 三层都要求至少 600 秒；system sampler 还修正为 N 个每秒样本必须实际保持完整 N 秒 wall-clock window。

validator 要求整段 Host/runtime/registration ready、route/pipeline 均为 false、状态 gap `<=2.5s`、snapshot freshness `<=3s`、Host 平均 CPU `<2%` 且三类 Host sleep assertion 全为 0，同时报告 WindowServer 与媒体服务 CPU。summary 固定写明只覆盖 screen-media-route，`allAuthenticatedConnectionsProvenAbsent=false`；因此不会把缺少 Rust `AUTHED_CONNS` aggregate count 的证据冒充完整“无人连接”。6 个自动测试、3 秒真实 system-sampler smoke、599 秒 acceptance 拒绝与 no-replace guard 已通过。详见 `Evidence/HostMode/2026-08-08/h2-host-idle-performance-contract.md`。

## 验证与边界

- 真实 ScreenCaptureKit + VideoToolbox H.264/HEVC 测试分别验证首个 access unit 的 stage 顺序严格为 `capture → encodeSubmit → packetReady`，且 packet 字节数与 access unit 一致；
- App 的 Host Media ABI 提交路径已编译覆盖 `sendSubmit → sendAccepted/sendDropped`；
- snapshot 定向测试覆盖 Rust 队列 accepted/dropped 计数和同步 encode reject 后 in-flight 清理；真实 H.264/HEVC pipeline 覆盖尺寸、pixel format、capture/encode/packet 计数、硬件状态、编码字节/码率/keyframe 与 latency 分位数；
- process sampler 定向测试验证 CPU、resident、physical footprint、threads、thermal/power 枚举和 telemetry latest/peak；另以真实 1.2 秒窗口验证自动周期采样至少发生一次；
- system-side sampler 早期真实 3 秒 smoke 采到 3 行；H2.1.11a 再以真实 1 秒 smoke 验证每行固定 27 列、schema v2 typed assertion metadata 可解析。两次 smoke 均以 shell PID 验证采样器，不是 FarPane 性能数据；
- 10 个 deterministic cadence 测试覆盖完整窗口+驻留后降到 3 FPS、驻留内禁止反向振荡、快速恢复、state-specific hysteresis、metadata 缺失 fail-safe、negotiated cap、实际 `SCStreamConfiguration.minimumFrameInterval`，以及 encode/send/thermal/Low Power moderate/severe 限帧、恢复门禁和 frame-budget latency 阈值；
- cadence telemetry 定向测试覆盖 state/target/applied、重复 decision 不重复计 transition，以及 update submit→fail、submit→apply、submit→cancel 的计数与 in-flight 收敛；真实 H.264/HEVC pipeline 另验证首帧 cadence snapshot 保持 negotiated 15 FPS 且没有伪造 update；
- bounded outcome 测试写入 40 项后确认只保留最近 32 项、drop rate 精确为 25%，并产生 severe pressure；
- process sampler 定向测试确认 cadence pressure 读取到与 telemetry snapshot 相同的真实 thermal/Low Power 状态；系统 thermal 状态无法由测试安全强制，因此 fair/serious/critical 映射使用 deterministic 输入验证，不冒充真机升温证据；
- evidence export 定向测试验证默认关闭、绝对 `.json` 路径门禁、schema/version/allowlist、成功写入、二次写入拒绝以及原文件字节不变；App 的 route stop/start-failure 路径已编译接入，错误日志不回显输出路径；
- 启用 `rdn-native-core,rdn-native-host` 的定向 Rust suite 运行 9 项 Host bridge 测试，full queue、disconnected queue、production C ABI saturation/replacement-IDR、脱敏 queue/writer payload 与 final-sample-before-stop 顺序均通过；上游既有 warning 保留且无新增 test failure；
- CoreBridge 定向测试验证 backpressure/stale/shutdown 都维持 expected-drop 语义，但只有 backpressure 返回 `requiresMediaKeyframeRecovery=true`；missing parameter sets 与非 media error 不会被误判；App target 编译覆盖 route-local 同步 keyframe recovery，真实 H.264/HEVC encoder tests 已覆盖 `requestKeyframe()` 后输出 keyframe+parameter sets；
- Host media pipeline 定向 suite 新增 generation gate、真实 H.264 reset、真实 HEVC reset 三项：旧 generation 失效，替代 session 首个对外 access unit 为带参数集 IDR，PTS 相对 route 起点继续单调；
- 真实 HEVC reset 测试继续使用 production `LiveHEVCDecoder`：第一代解码后显式清空 decoder，replacement IDR 单独重建硬件解码 session；两帧均输出 256×144、decodeErrors=0；
- H2.4.1 probe 定向测试在本机对 H.264/HEVC 分别完成 1920×1080@30 NV12 首帧编码、关键帧参数集检查与 post-callback hardware readback；16384×16384 在像素分配前 fail closed；
- H2.4.2 capability discovery 测试证明双 codec 只使用精确共同 FPS 档、H.264 兼容 fallback 与全失败 fail closed；App target 编译覆盖实际 display envelope、async probe、stale-instance gate 和动态 C ABI advertisement；
- H2.4.3 在本机真实完成 H.264/HEVC 3840×2160@30 NV12 首帧，均为带参数集关键帧且 post-callback hardware readback=true；不据此声明持续性能；
- H2.4.4–H2.4.6/H2.1.6b–H2.1.11a validator synthetic smoke 覆盖 schema v7 queue/writer/network/transport、system schema v2+ typed assertion evidence（当前 sampler v3）、active/static/stability profiles 完整 pass，以及缺 final sample、unknown transport、display assertion 泄漏、static 未降帧/CPU 超标/cadence update 异常、stability 资源趋势与 route convergence 异常的 fail-preserve 路径；synthetic route 不计入真实性能证据；
- H2.4.7a runtime-state writer 定向测试 4/4，覆盖 allowlist/privacy、periodic throttle、forced lifecycle transition 与 default-off/no-replace/unknown-state fail closed；全量 104 项测试（4 项按条件跳过）0 failure，release App 编译链接通过；
- H2.4.7b idle validator 定向测试 6/6，覆盖 pass、状态 transition、CPU/assertion、状态连续性/freshness、短/incomplete 与 no-replace；runner 真实采集 3 秒 system/state smoke 并通过，599 秒 acceptance 与已有产物均 fail closed；ScriptTests 全量 13/13、Swift 全量 104 项（4 项按条件跳过）0 failure，release App 构建通过；
- drop ledger 定向测试覆盖 H2.3.4 的五个已接生产源原因、未 instrument 的 `captureSuperseded=nil`、异步 encoder drop 的 in-flight 收敛、unknown/unclassified 完整性计数和 CoreBridge stable error mapping；
- raw-frame handoff deterministic 测试覆盖容量 2、无 active 时保留最新两帧、active frame 不可替换、pending newest-wins、cancel 只清 pending、worker 重新调度；生产 pipeline 初始 snapshot 证明 `captureSuperseded=0` 已 instrument，真实 H.264/HEVC pipeline stop 后 current depth=0、maximum depth 在 1...2；evidence allowlist 测试覆盖 schema version 7 的 raw/encoded queue、writer-loop wall、QoS network 与 transport 字段；
- Rust `GenericService::send_video_frame` 已低频导出真实 encoded queue、同步 subscriber fanout/frame-controller wait，以及与当前路由 subscriber 关联的 RustDesk QoS effective delay/RTT 和 direct/relay/unknown transport；§15.1 的 encryption/send CPU、loss/reconnect 仍无权威 route-correlated source；
- native Host wakelock pure policy 定向测试覆盖 remote screen → user-idle-only、非屏幕 scope → none、disabled → none，并确认非 native upstream policy 不变；system sampler 真实 1 秒 smoke 产生 27 列/schema v2，typed-assertion synthetic pass 与 display-leak fail-preserve 均通过；
- assertion lifecycle validator 的完整三阶段+route fixture pass，display assertion/断开后泄漏与 missing-route fixtures fail-preserve；runner acceptance 时长门禁和真实 no-Viewer smoke 证明失败时仍保存 samples/metadata/run summary；
- 尚未保存真实 Instruments trace，因此不声明性能数值或 H2.1 完成。

## 下一步

H2.4.4–H2.4.7b active/static/stability/no-screen-route 性能 runner 与 H2.1.11b assertion lifecycle runner 均已就绪。真实 no-screen-route idle、connected-static、1080p30、4K30 10 分钟、30 分钟 stability 会话和 ready→active→disconnected assertion 生命周期需要 Mac mini 与另一台 FarPane Viewer 人工保持/切换场景，当前不冒充完成。完整“无人连接”仍需要对 Rust `AUTHED_CONNS` aggregate count 的共享 HostSnapshot/C ABI 架构检查点；在该合同明确前，idle summary 固定声明只证明无屏幕 route。H2.2.6 已把 route-scoped current QoS delay/RTT 接入自适应压力，但仍不把 async connection task 的 encryption/send CPU、frame-controller fetch wait、loss 或 relay/direct 猜成其它指标。

后续 authority 审计确认：direct/relay 在 rendezvous 建连分支是权威事实，但进入 `Connection::start` 前未保留，当前 display route subscriber ID 无法在认证后关联 transport；Host 侧也没有不混淆并发新会话的 reconnect counter，可靠传输层下更没有可直接归因的 packet-loss percentage。接入 transport 需要新增内部枚举并贯穿 `ConnectionMeta`、`Connection`、authenticated registry 与所有 direct/KCP/relay 分支，属于独立共享连接架构步骤；本轮保持 unavailable。详见 `Evidence/HostMode/2026-08-07/h2-network-authority-audit.md`。

H2.1.9a 随后以更窄的内部 RAII registry 关闭了 transport authority 缺口，而没有扩大 `ConnectionMeta` 或 authenticated registry：connection ID 分配后立即登记 direct/relay，握手失败或完整 connection future 结束时自动清理；现有 direct access、intranet/TCP punch、IPv6、KCP direct 路径继续经公开 `create_tcp_connection` 标记 direct，只有明确 relay helper 标记 relay。`route_transport_snapshot` 已能对精确 subscriber ID 集合返回 direct/relay/unknown counts，但本步不导出 event/schema，也不声称任何真实会话 transport。详见 `Evidence/HostMode/2026-08-07/h2-transport-authority-registry.md`。

H2.1.9b 已把该 registry 与 `GenericService::send_video_frame` 返回的精确当前路由 subscriber ID 集合关联，每秒通过独立 `mediaTransportDiagnostic` 只导出 subscriber/direct/relay/unknown counts；最新快照在 queue/writer/network 之后、`stopCapture` 之前发出 final sample。Swift 双重校验完整 partition、route epoch 与 finalization，evidence 升为 additive schema v7；性能 validator 要求周期+最终样本且 unknown 为 0，但 telemetry 本身保留 unknown 而不猜测。该自动证据不声明真实会话使用 direct 或 relay。详见 `Evidence/HostMode/2026-08-07/h2-transport-telemetry.md`。

H2.1.10 进一步沿真实 connection writer、`Stream`/TCP/KCP 抽象与 authenticated session 生命周期完成 authority 审计：现有 mixed async send wall 不是 CPU，pinned TCP/KCP abstraction 没有统一 loss contract，Host 新连接/复用 session key 也不是不含歧义的媒体 reconnect。三项继续 unavailable，不新增 schema 字段或零值；安全的未来架构边界已分别记录，reconnect 默认留到 H5 session recovery。详见 `Evidence/HostMode/2026-08-07/h2-encryption-loss-reconnect-authority-audit.md`。

H2.1.11a 已让 native Host 仅在 authenticated remote screen connection 存在时持有 `PreventUserIdleSystemSleep`，不因 file/port-forward 等 scope 保持唤醒，也不持有 `PreventUserIdleDisplaySleep`。system sampler/run summary additive schema v2 对 active route 按 PID/类型 fail closed；真实 Host-ready → active → disconnected-ready 生命周期仍需新构建在 Mac mini 上执行。详见 `Evidence/HostMode/2026-08-07/h2-sleep-assertion-policy.md`。

H2.1.11b 已把该真机步骤固化为拒绝覆盖的三阶段 runner，并要求同 prefix production route evidence 证明真实媒体 route；ready 前后零 assertion、active user-idle-only、显示/显式系统休眠 assertion 禁止项均有独立 gate。真实 Mac mini 数据仍待用户回来执行。详见 `Evidence/HostMode/2026-08-08/h2-sleep-assertion-lifecycle-runner.md`。

H2.3.6c 审计结论：当前公开 Host Media ABI 没有 native route begin/dequeue；route 由真实 `video_service` subscriber 权威创建。没有 Viewer 时 Swift submit 会在填满 queue 之前 fail closed，因此无人值守地把 Rust saturation 与 Swift ledger/reset 拼成同一次运行，必须新增 test-only ABI/Cargo feature 或使用真实双机慢消费。今晚不扩大这些边界，也不以 Swift 合成 error 冒充跨语言证据；详见 `Evidence/HostMode/2026-08-07/h2-cross-language-ledger-boundary.md`。明早优先运行真实 1080p30 smoke/performance 场景并断开 Viewer，随后再决定是否需要受控慢消费测试窗口。
