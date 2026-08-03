# RustDesk Native Viewer 参考实现调研

更新时间：2026-08-02

本文件补充 `DESIGN.md`，记录可复用的上游实现及其真实成熟度。结论用于减少重复开发，但不把尚未验证或未合并的代码当作可直接交付的依赖。

## 1. SlopDesk：Swift / VideoToolbox / Metal 参考实现

- 仓库：https://github.com/aislopware/slop-desk
- 调研快照：`b081d3cc08c36a97b240219ea93b9cb408bad143`
- 许可证：MIT
- 当前工具链/系统下限：Swift tools 6.3、macOS 26、iOS 26

重点文件：

- `Sources/SlopDeskVideoClient/VideoDecoder.swift`
- `Sources/SlopDeskVideoClient/MetalVideoRenderer.swift`
- `Sources/SlopDeskVideoClient/ClientCursorCompositor.swift`
- `Sources/SlopDeskVideoClient/FramePacer.swift`
- `docs/21-HANDOFF.md`

可复用思想：

- `VTDecompressionSession` 解析 HEVC，并只在 VPS/SPS/PPS 实际变化时重建 session。
- VideoToolbox 输出 NV12 `CVPixelBuffer`。
- 输出属性包含 `kCVPixelBufferMetalCompatibilityKey` 和 IOSurface backing。
- `CVMetalTextureCacheCreateTextureFromImage` 将 NV12 的 Y/UV plane 映射为 Metal texture。
- Metal shader 完成 BT.709 YUV -> RGB、缩放和呈现。
- command buffer 完成前显式持有 `CVMetalTexture` wrapper 与 `CVPixelBuffer`，避免异步 GPU 读取期间生命周期结束。
- newest-wins 帧节流、客户端光标合成、NALU/parameter-set 防御性解析值得参考。

成熟度边界：

- 仓库 README 明确标记 WIP，当前最低系统为 macOS/iOS 26。
- `docs/21-HANDOFF.md` 明确说明 GUI decode + Metal render 是“编译并评审，但没有真实运行”。
- 文档称同步解码测得约 0.9–1.1 ms，但 Metal device、display link 和真实双机 GUI 路径没有完成运行验证。
- SlopDesk 使用自有 UDP/FEC 协议，不兼容 RustDesk；只移植视频解码、渲染、帧节流和光标层，不移植网络协议。

macOS 13 回移要求：

- 不复制整个 SwiftPM workspace；只抽取视频管线的最小独立实现。
- 将 Swift 6.3 strict-concurrency 代码调整到 Swift 5.9 / Xcode 15.2 可编译范围。
- 删除 macOS 26 UI 和第三方 package 依赖。
- 对 VideoToolbox、CoreMedia、Metal、QuartzCore API 做 macOS 13 availability 编译验证。
- 在 Intel MBP 上真实运行 Metal、VideoToolbox 和 display-link 路径；不得以 headless tests 代替。
- 保留 MIT 许可证和必要版权说明。

## 2. RustDesk PR #15682：原生客户端 Core 接入参考

- PR：https://github.com/rustdesk/rustdesk/pull/15682
- 标题：`feat(ohos): add OpenHarmony client integration and native media backends`
- 调研时 head：`07c14cacf026d6585d3d78e3d9477c1f059de0da`
- 状态：open、非 draft、未合并，GitHub 当前报告 `mergeable_state=dirty`
- 规模：12 commits、42 files、约 `+4623/-607`

重点变化：

- `src/client.rs`
- `src/client/io_loop.rs`
- `src/ui_interface.rs`
- `src/ui_session_interface.rs`
- `src/flutter.rs`
- `src/flutter_ffi.rs`
- `libs/scrap/src/common/codec.rs`
- `libs/scrap/src/common/ohos/*`

可复用思想：

- 保留 RustDesk Rust 层的连接、认证、协议和输入能力。
- 将平台原生媒体后端与通用 client/session 逻辑分开。
- 原生 UI 通过受控事件/FFI 边界消费 session 状态。
- 平台硬件 codec 作为独立 backend，而不是依赖 Flutter 视频层。

使用边界：

- PR 尚未合并且与 master 有冲突，不直接把 PR branch 作为项目依赖。
- 先阅读 diff，提炼 RustDesk client/session 最小入口和事件边界。
- 项目以 RustDesk `1.4.9` tag 为兼容基线；需要的抽象以小范围补丁移植，并保留来源说明。
- OpenHarmony 的 AVCodec/direct-render 实现不能直接用于 macOS；它只证明核心与原生媒体后端可以解耦。

## 3. 其他 Core wrapper

### RustDesk-ArkTS

- https://github.com/FrankHan052176/RustDesk-ArkTS
- 可用于理解 OpenHarmony 原生 UI 如何消费 RustDesk session。
- 仓库 API 元数据未识别到明确许可证；在许可证确认前只阅读接口与架构，不复制代码。

### librustdesk_core

- https://github.com/liyan-lucky/librustdesk_core
- 包含面向 C ABI/NAPI 的连接、登录、鼠标、键盘、显示器等包装思路。
- 视频路径仍偏 RGBA/copy，不能满足本项目零拷贝目标。
- GitHub API 对许可证返回 `NOASSERTION`；在许可证和与 RustDesk AGPL 的派生关系确认前，不复制代码。

### rustdesk-sdk

- https://github.com/yangsengui/rustdesk-sdk
- AGPL-3.0。
- 更偏服务启动、配置与管理，不是完整 Viewer SDK；仅作为接口命名和初始化流程参考。

### RustDesk Issue #4225

- https://github.com/rustdesk/rustdesk/issues/4225
- 证明上游长期关注 macOS Metal 性能，但调研时没有发现已经交付的 macOS VRAM/Metal Viewer 路径。

## 4. 更新后的实现决策

优先级：

1. Phase 0/1 不从空白设计 VideoToolbox/Metal 细节，先对照 SlopDesk 的两个核心文件，抽取 macOS 13 可运行的最小子集。
2. 保持独立实现与测试，不引入 SlopDesk 网络、UDP/FEC、终端、SwiftUI 26 依赖。
3. Rust Core Bridge 开始前，先研究 PR #15682 对 `client.rs`、`io_loop.rs`、`ui_interface.rs` 和 codec backend 的改动。
4. 不依赖未合并 PR，也不直接依赖许可证不明确的第三方 wrapper。
5. 所有复用代码记录原始仓库、commit 和许可证；RustDesk 派生部分按 AGPL-3.0 管理。

第一轮实现应验证：

- SlopDesk 解码器/渲染器关键 API 能否在 macOS 13 + Swift 5.9 编译。
- `4096x2304 @ 30 FPS` 下 VideoToolbox 输出是否稳定为 NV12、Metal 是否真正呈现。
- `CVPixelBuffer`、`CVMetalTexture` 和 command buffer 生命周期是否无泄漏/野指针。
- Intel UHD 630 与 Radeon Pro 5300M 的设备选择是否产生跨 GPU 拷贝。
- 真实 GUI 运行的 CPU、内存、FPS 和丢帧是否达到 `DESIGN.md` 门槛。

只有这些结果通过后，才进入真实 RustDesk packet/session 集成。
