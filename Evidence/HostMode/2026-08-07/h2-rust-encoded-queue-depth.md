# H2.1.6a Rust encoded queue depth 追踪证据

- 日期：2026-08-07
- 范围：production Rust Host encoded queue 的 current/maximum depth 内部原语
- 结论：定向测试、production arm64 core 重建、Swift 全量测试与 Release build 通过；本步不构成 queue depth 对外 evidence export 或持续性能基线

## 实现边界

- 每条 `NativeMediaRoute` 与对应 sender 共享同一 tracker。
- 成功 `try_send` 才增加 current，并更新 maximum；full/disconnected 失败不改变计数。
- `video_service::run_native` 成功取得 packet 后立即递减 current；maximum 保留到 route 生命周期结束。
- counter lock 覆盖 `try_send`，consumer 的 dequeue 记录无法先于成功 enqueue 的计数发布。
- queue capacity 仍为 3；C ABI、错误码、wire、drop policy 和 Hermes 均未修改。
- production 当前只写 tracker，没有公开 reader；schema v3 不声称已有 Rust encoded queue depth。

## Fresh verification

1. Rust bridge 定向测试：`cargo test --manifest-path Vendor/rustdesk/Cargo.toml --features rdn-native-core,rdn-native-host --lib rdn_host_bridge::tests`
   - `6 passed; 0 failed; 81 filtered out`
   - 覆盖 current `0 → 3 → 0`、maximum 保持 3、第四包 backpressure 不改变深度、disconnected 不改变深度，以及正式 C ABI saturation/replacement-IDR drain。
2. Production core：`Scripts/build-rust-core.sh`
   - release build 成功；生成 arm64 Mach-O `Build/CoreBridge/arm64/liblibrustdesk.dylib`。
3. Swift 集成：`RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`
   - `88 tests, 0 failures`；包含 built-core ABI load/verification。
4. App Release：`swift build -c release`
   - `Build complete`，exit 0。

## 尚未证明

- route-stop JSON 尚未导出 Rust current/maximum depth；需要后续 additive 内部诊断事件与 fail-closed decoder。
- 没有权威 RTT、loss、transport type、encryption CPU 或远端 ACK 输入；不得填零或由 Swift accepted/dropped 反推。
- 没有执行 1080p30/4K30 两机 10 分钟场景，因此不宣称性能门禁通过。
