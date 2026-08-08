# H2.4.1 codec/size-specific first-frame hardware probe

- 日期：2026-08-07
- 范围：本机 VideoToolbox H.264/HEVC hardware capability probe
- 目标：1920×1080 与 3840×2160、30 FPS、NV12 full-range
- 网络：不连接 Hermes，不修改服务端
- 密钥：不读取、不输出、不写入

## Production path

`HostHardwareEncoderProbe` 对每个 codec 使用准确的目标尺寸、FPS 和 source pixel format 创建 IOSurface-backed buffer，调用现有 production Host encoder，真实提交第一帧。只有同时满足以下条件才返回 available：

- 压缩 callback 输出非空 keyframe；
- access unit 携带 H.264 SPS/PPS 或 HEVC VPS/SPS/PPS；
- callback 后读取 `UsingHardwareAcceleratedVideoEncoder=true`；
- encoder ID 非空；
- 无 creation/submission/callback/timeout/software-fallback failure。

probe 在专用后台串行队列运行，不阻塞调用方 executor。单边范围沿用 Host contract 的 16...16384，总像素另限制为不超过 7680×4320；错误的 16384×16384 输入在分配 pixel buffer 前返回 `invalidConfiguration`。

## Fresh targeted verification

```text
swift test --filter HostHardwareEncoderProbeTests

Executed 5 tests, with 0 failures
```

本机结果：

- H.264 1920×1080@30：首帧 keyframe+parameter sets，hardware readback=true；
- HEVC 1920×1080@30：首帧 keyframe+parameter sets，hardware readback=true；
- H.264 3840×2160@30：首帧 keyframe+parameter sets，hardware readback=true；
- HEVC 3840×2160@30：首帧 keyframe+parameter sets，hardware readback=true；
- 16384×16384@60：allocation 前 fail closed。

## Boundary

- 这是能力探测原语，不是吞吐/功耗基线；没有据此声明 1080p30/4K30 持续性能或 Instruments 门禁通过。
- H2.4.2 已把该 probe 接入实际 display target 的 production advertisement，详见 `h2-hardware-capability-advertisement.md`。
- 当前证据来自本机，不能外推 Intel HEVC；Intel 必须在对应机器完成同一首帧 probe 并读回 hardware=true 才能参与协商。

## Fresh regression verification

- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`：88 passed、0 failed；
- `swift build -c release`：成功；
- `git diff --check`：通过。
