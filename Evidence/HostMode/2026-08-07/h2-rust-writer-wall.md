# H2.1.7 Rust writer-loop wall timing evidence

- 日期：2026-08-07
- 范围：production `video_service::run_native` → Host event → Swift telemetry → route-stop schema v5
- 网络：未连接或修改 Hermes
- 密钥：未读取、未输出、未写入

## Outcome

production native video loop now accumulates two route-scoped wall-clock measurements: synchronous subscriber channel fanout around `GenericService::send_video_frame`, and the existing `VideoFrameController` fetch/confirmation wait. It emits at most one cumulative `mediaWriterDiagnostic/sample` per writer/QoS second and a final `routeStopped` sample before `stopCapture`.

Swift accepts only matching route epochs and internally consistent, monotonic cumulative counters. Route-stop evidence is additive schema v5 with sample count, cycles, subscriber dispatches, total/maximum wall times, completed/timed-out confirmation counts, and finalized state. The performance validator requires a periodic plus final sample and rejects missing, inconsistent, or unfinished writer evidence.

## Key evidence

- Rust aggregation is saturating, contains no raw packet, peer, server, credential, or screen data, and ignores cycles with no subscriber.
- CoreBridge rejects fractional/negative fields, count mismatches, impossible maxima, and unknown kinds before the App sees the event.
- `HostMediaTelemetry` rejects cumulative regressions and any sample after finalization instead of merging it.
- Final queue and writer samples remain ordered before the existing route `stopCapture` control event.

## Verification

1. Rust bridge focused suite: `9 passed; 0 failed; 72 filtered out`.
2. Swift focused suites: 19 tests, one built-core smoke skipped until a dylib is supplied, 0 failures.
3. Schema v5 validator smoke: complete writer evidence passes; `writer.finalized=false` exits 1 and preserves a `status=fail` artifact with the final-sample reason.
4. `Scripts/build-rust-core.sh`: release core built successfully as an arm64 Mach-O dylib.
5. `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`: 92 tests, 0 failures; built-core ABI smoke executed.
6. `swift build -c release`: `Build complete`, exit 0.
7. Canonical/vendor bridge byte comparison, upstream reverse-patch check, and `git diff --check`: pass.

## Measurement boundary

- `dispatchWallTotalMicroseconds` measures synchronous fanout into per-connection channels only. Protobuf serialization, encryption/DTLS, async socket writes, and their CPU time occur later in connection tasks and are not attributed here.
- `confirmationWaitTotalMicroseconds` measures the existing `VideoFrameController` fetch wait. A connection may notify frame fetch before its async socket send completes, so this is not network RTT, remote decode/display acknowledgement, or packet loss.
- No threshold is attached to these diagnostics yet. A synthetic validator fixture proves the contract, not real-session performance.

## Next step

Keep encryption/send CPU, RTT/loss, transport type, and relay/direct unavailable until an authoritative route-correlated source is identified. Real 1080p30/4K30 data still requires the two-machine runner and a Viewer disconnect after sampling.
