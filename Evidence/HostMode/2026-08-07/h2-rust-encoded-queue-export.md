# H2.1.6b Rust encoded queue 低频导出证据

- 日期：2026-08-07
- 范围：production Rust writer queue → Host event → Swift telemetry → route-stop schema v4
- 网络：未连接或修改 Hermes
- 密钥：未读取、未输出、未写入

## Outcome

容量 3 的 production Rust encoded queue 现在在既有 writer/QoS 一秒周期内发出 aggregate `sample`，并在 route guard 结束或 Host unbind 时先发 `routeStopped` 最终 sample、后发 `stopCapture`。事件复用 Host Control schema v1 callback，不增加或修改 C ABI/wire；Swift 只接收匹配当前 route 且满足 `current ≤ maximum ≤ capacity` 的整数值。

每路 `HostMediaTelemetry` 保留 sample count、latest current、maximum、capacity 和 finalized。route-stop evidence 升至 schema v4；validator 要求至少一个周期 sample 加最终 sample、capacity=3、深度有界和 finalized=true。缺字段或容量漂移保持 unavailable/fail，不填零。

## Key evidence

- Rust 单元测试证明 aggregate payload 无 peer/server/password/key/payload/data，并证明同一事件序列严格为 periodic sample → final sample → stop control。
- CoreBridge decoder 拒绝 unknown kind、fractional/negative/zero/out-of-capacity depth，并按 connection/codec/display revision 匹配 route。
- Swift telemetry 拒绝同一路由 capacity 漂移，maximum 单调保留，finalized 只会从 false 变 true。
- evidence allowlist 只新增 `send.encodedQueueSamples/current/maximum/capacity/finalized`；不含 route identity、画面或错误文本。

## Verification

1. Rust bridge focused suite：`8 passed; 0 failed; 81 filtered out`。
2. Swift focused suites：17 tests，1 个未提供 dylib 的既有 built-core smoke skip，0 failures。
3. validator schema v4 synthetic smoke：完整 queue evidence `status=pass`；`encodedQueueFinalized=false` 时 exit 1 且 no-replace `status=fail` artifact 保留 final-sample 原因。
4. canonical/vendor bridge byte sync 与 upstream patch reverse-check：pass。
5. `Scripts/build-rust-core.sh`：release core 构建成功，产物为 arm64 Mach-O dylib。
6. `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`：`90 tests, 0 failures`，built-core ABI smoke 未跳过。
7. `swift build -c release`：`Build complete`，exit 0。

## Boundary

- 当前 queue sample 来自 production writer loop，但 synthetic validator fixture 不是真实 FarPane 会话，不能作为 1080p30/4K30 性能证据。
- current/maximum/capacity 只描述 FarPane 自有 encoded handoff queue；不等于 RustDesk 后续 encrypted writer queue、网络 RTT/loss、relay/direct、远端 ACK latency 或 encryption CPU。
- 真机性能门禁仍需两台 FarPane 保持 10 分钟场景并在采样后断开。
