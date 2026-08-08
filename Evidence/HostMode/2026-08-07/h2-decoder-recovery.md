# H2.3.6b replacement HEVC IDR production decoder recovery

- 日期：2026-08-07
- 范围：本机真实 ScreenCaptureKit、VideoToolbox HEVC hardware encoder 与 production `LiveHEVCDecoder`
- 网络：不连接 Hermes，不修改服务端
- 密钥：不读取、不输出、不写入

## 场景

1. `HostMediaPipeline` 捕获真实 256×144 画面并由第一代 HEVC VTCompressionSession 输出 startup IDR+VPS/SPS/PPS。
2. 在第一个 output callback 边界调用 `recoverFromEncodedPacketDrop()`，使 encoder generation 失效并在 callback 外 flush/invalidate 旧 session。
3. replacement generation 的首个对外 access unit 为 PTS 更大的 IDR+VPS/SPS/PPS。
4. 第一代 access unit 经严格 AVCC parser 后送入 production `LiveHEVCDecoder`，硬件 decoder 输出 256×144 pixel buffer。
5. 显式 invalidate decoder，清除 session 与 parameter-set cache。
6. 仅用 replacement access unit 重建 production hardware decoder，并再次输出 256×144 pixel buffer。

## Fresh targeted verification

```text
RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib \
  swift test --filter \
  HostMediaPipelineTests/testBackpressureResetStartsFreshHEVCGenerationWithIDR

Executed 1 test, with 0 failures
```

测试同时断言：

- 两代 access unit 都是 keyframe 且携带 parameter sets；
- replacement PTS 严格大于第一代；
- decoder submittedFrames=2、decodedFrames=2；
- decodeErrors=0；
- hardwareDecodeActive=true；
- 两次输出尺寸均为 256×144。

## 边界

- 测试依赖本机 Screen Recording 权限、HEVC 硬编和硬解；缺失时明确 skip。
- 当前 production live viewer 只有 HEVC decoder。H.264 已有真实 encoder reset→self-contained IDR 证据，但本步骤不声明 H.264 decoder recovery。
- Rust production C ABI saturation 由 `h2-rust-c-abi-saturation.md` 独立证明。本测试的 recovery trigger 直接调用 production pipeline recovery API，尚未在同一次执行中接收该 Rust test 的真实 `BACKPRESSURE` 返回或写出 schema v3 `networkBackpressure=1`。
- 从 Swift 建立并暂停内部 Rust `NativeMediaRoute` receiver 当前没有可见接口；本步骤没有增加 test-only export、Cargo feature、环境开关、production command 或 Hermes 改动。

## Fresh regression verification

- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`：79 passed、0 failed；
- `swift build -c release`：成功；
- `git diff --check`：通过；
- 当前环境没有 `swift-format` 可执行文件，因此未声称独立 Swift formatter gate；测试文件遵循其既有两空格格式并由 Swift 编译器完整编译。
