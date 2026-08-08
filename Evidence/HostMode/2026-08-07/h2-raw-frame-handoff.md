# H2.3.5 capacity-2 raw-frame handoff evidence

- 日期：2026-08-07
- 对应设计：`docs/host-mode-design.md` §11.6、§15.1、§26.5
- 范围：SCK complete frame → capacity-2 Swift handoff → VT submit
- 不包含：Hermes、Rust writer/transport 修改、真实网络拥塞、性能结论或远端真机验收

## Outcome

- handoff 总容量固定为 2：一个 active frame 加一个 pending frame；worker 尚未开始时可暂存最新两帧。
- 满载时只替换最老的 pending frame；active/已提交 VT frame 和 encoded reference packet 永不由 newest-wins 弹出。
- 每次 pending 替换记录 `captureSuperseded`；production pipeline 从 route 创建起即标记该原因已 instrument。
- cancel 按实际 pending 数量记录 `shutdown`，stop 等待 capture、raw-frame worker 与 encoder reset queue 排空。
- telemetry 增加 current/maximum raw-frame queue depth，maximum 受实现硬限制为 2。
- route-stop evidence 等待 drain 后写出 additive schema version 3；v2 drop ledger 保留，capture 增加 current/maximum queue depth。

## Deterministic policy proof

测试顺序为：enqueue 1、2、3；第三帧满载后替换未提交的 1，worker 首先取得 2。2 成为 active 后 enqueue 4 只替换 pending 3；完成 2 后取得 4。随后 enqueue 5 再 cancel，仅 5 被清除，active 4 保留到 finish。该序列证明 newest-wins 只作用于未提交 raw frame。

## Focused verification

```text
swift test --filter 'HostMediaPipelineTests|HostMediaTelemetryTests|HostMediaTelemetryEvidenceTests'
Executed 15 tests, with 0 failures.
```

其中真实 ScreenCaptureKit→VideoToolbox H.264/HEVC 与两个 encoder-reset 测试均实际运行；pipeline stop 后 queue current depth 为 0，观察到的 maximum depth 在 1...2。

## Remaining boundary

- deterministic replacement 使用整数 fixture 验证 handoff policy；本机真实 SCK 测试验证主路径和边界，但未强制制造 capture supersede，不能冒充真实负载 drop 证据。
- 下一步需用本地可控 integration harness 强制 Rust encoded queue 满载，并保存 schema v3 JSON，核对 `networkBackpressure`、generation reset、replacement IDR、`unclassified=0` 与 decoder recovery。
