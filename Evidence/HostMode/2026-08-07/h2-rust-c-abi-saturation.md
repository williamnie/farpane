# H2.3.6a Rust production C ABI queue saturation

- 日期：2026-08-07
- 范围：本地 deterministic Rust test；不连接 Hermes，不修改服务端，不包含密钥
- production boundary：`native_media_begin_route` + `rdn_host_media_submit_access_unit`
- encoded queue capacity：3，拒绝 newest

## 场景与观测

1. harness 建立 Ready test Host binding，并通过 production route constructor 创建 H.264 route；receiver 保持存活但不消费。
2. 正式 C ABI 依次接受 PTS 100 的 IDR+parameter sets、PTS 200/300 的 delta。
3. PTS 400 delta 通过同一 C ABI 返回 `RDN_HOST_ERR_BACKPRESSURE`。
4. receiver 先读出 PTS 100 IDR，已排队 reference packets 未被替换。
5. 使用失败提交相同的 PTS 400 提交 replacement IDR+parameter sets，C ABI 接受；随后队列严格读出 200、300、400，最后一个为带 parameter sets 的 IDR。

这同时证明 full 分支不更新 `last_pts_us`；否则 replacement IDR 会被 `RDN_HOST_ERR_NON_MONOTONIC_PTS` 拒绝。harness 调用正式提交函数和 production queue，不是直接伪造 Swift error code。

## Fresh verification

```text
VCPKG_ROOT=Build/vcpkg MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_BUILD_JOBS=1 \
  cargo test --features rdn-native-core,rdn-native-host --lib \
  rdn_host_bridge::tests::public_access_unit_api_reports_saturation_then_accepts_replacement_idr

test result: ok. 1 passed; 0 failed; 0 ignored; 86 filtered out
```

上游现有 127 条 Rust warning 保留；本次没有 test failure。`Vendor/rustdesk/src/rdn_host_bridge.rs` 与 canonical `CoreBridge/RustDeskPatch/rdn_host_bridge.rs` 经 `rustfmt --check` 且逐字一致。

同一 fresh verification 窗口另确认：

- Host bridge suite：6 passed、0 failed；
- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`：79 passed、0 failed；其中真实 H.264/HEVC pipeline reset tests 均通过；
- `Scripts/build-rust-core.sh arm64`：release dylib 构建成功，产物为 arm64 Mach-O；上游 production build 保留 130 条既有 warning；
- `swift build -c release`：成功；
- `git diff --check`、Rust formatting、canonical copy comparison 与不回显匹配内容的 credential scan：通过。

## 未覆盖边界

- 尚未在同一次进程链中让 Swift 收到该真实 Rust 返回并写出 schema v3 `networkBackpressure=1`；
- 已有 Swift tests 分别覆盖 stable error mapping、drop classification 与真实 H.264/HEVC VT generation reset 后的 IDR+parameter sets，但本证据不把独立测试拼接冒充单次集成；
- 未运行测试 decoder、远端 writer/ACK、Hermes 网络拥塞或真机长时性能场景。

H2.3.6b 已补充 production HEVC decoder 冷恢复证据，见 `h2-decoder-recovery.md`。下一小步为 H2.3.6c：继续寻找不增加 production/test-only ABI、Cargo feature 或根配置的同次跨语言 drop-ledger 集成入口；若只能扩大共享 contract 才能注入，则保留此架构边界并转向真实受控慢消费/网络验收设计。
