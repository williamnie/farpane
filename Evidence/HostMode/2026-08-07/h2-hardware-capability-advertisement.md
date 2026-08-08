# H2.4.2 actual-display conservative capability advertisement

- 日期：2026-08-07
- 范围：FarPane App Host capability discovery 与现有 Host Media ABI advertisement
- 网络：不连接 Hermes，不修改服务端
- 密钥：不读取、不输出、不写入

## Production behavior

1. Host instance 首次 snapshot 时读取全部当前 `NSScreen` 对应 CGDisplay 的物理 width/height 与 maximum FPS。
2. 使用 `max(width) × max(height)` 覆盖任一当前显示器，FPS 上限取当前最高刷新率与 60 的较小值。
3. 后台依次探测 display cap、30、15 FPS 去重档位；每个档位分别真实探测 H.264 和 HEVC。
4. 双 codec 只在同一精确档位都完成首帧 keyframe+parameter sets 且 hardware readback=true 时共同广告。
5. 无共同档时不混合不同 FPS 结果；按兼容优先级广告已验证的 H.264-only，只有 H.264 全失败时才允许 HEVC-only。
6. 全失败或 display envelope 超过 probe 安全边界时，不调用 `setMediaCapabilities`，UI 明确显示 fail-closed 状态。
7. 发送到现有 C ABI 的 maxWidth/maxHeight/maxFPS 均来自本次 discovery；源码不再以 16×16 session boolean 广告固定 `16384×16384@60`。

## Lifecycle isolation

- 每次 probe 绑定 Host instance ID 与随机 probe ID；
- Host stop、切到 viewer 或新 instance 会 cancel task 并清空 token；
- 完成后还必须匹配 active runtime、current snapshot、current HostControlClient identity；
- 迟到 VT callback 或旧 task 结果不会写入新 instance。

## Fresh targeted verification

```text
swift test --filter HostHardwareEncoderCapabilitiesTests

Executed 4 tests, with 0 failures
```

覆盖：

- H.264@60 通过而 HEVC@60 失败后，两者在 30 FPS 精确重测并共同广告 30；
- 没有共同档时只广告已验证的 H.264 compatibility baseline；
- 所有 codec/档位失败时返回 nil；
- 16384×16384 display envelope 在 probe 前拒绝。

## Boundary

- App target 已编译覆盖 production wiring；本步骤没有启动真实 Host 或连接 Hermes，因此尚未保存一次实际 App 启动后的 capability event/readback。
- 首帧 probe 证明 codec/session/目标尺寸可用，不证明持续 FPS、码率、功耗或 thermal 门禁。
- Intel HEVC 仍必须在 Intel 真机运行相同 probe 并读回 hardware=true；不能从本机结果外推。
- 没有修改 C ABI、Rust wire protocol、Hermes、CI、根依赖或根配置。

## Fresh regression verification

- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`：86 passed、0 failed；
- `swift build -c release`：成功；
- `git diff --check`：通过。
