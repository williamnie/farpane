# FarPane RustDesk Core 接入调研

更新时间：2026-08-02

本文件补充 `architecture.md`，记录可复用的上游实现及其真实成熟度。结论用于减少重复开发，但不把尚未验证或未合并的代码当作可直接交付的依赖。

## 1. RustDesk PR #15682：原生客户端 Core 接入参考

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

## 2. 其他 Core wrapper

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

## 3. 更新后的实现决策

优先级：

1. Phase 0/1 独立实现并验证 macOS 13 可运行的 VideoToolbox/Metal 最小视频管线。
2. Rust Core Bridge 开始前，先研究 PR #15682 对 `client.rs`、`io_loop.rs`、`ui_interface.rs` 和 codec backend 的改动。
3. 不依赖未合并 PR，也不直接依赖许可证不明确的第三方 wrapper。
4. 所有复用代码记录原始仓库、commit 和许可证；RustDesk 派生部分按 AGPL-3.0 管理。

第一轮实现应验证：

- `4096x2304 @ 30 FPS` 下 VideoToolbox 输出是否稳定为 NV12、Metal 是否真正呈现。
- `CVPixelBuffer`、`CVMetalTexture` 和 command buffer 生命周期是否无泄漏/野指针。
- Intel UHD 630 与 Radeon Pro 5300M 的设备选择是否产生跨 GPU 拷贝。
- 真实 GUI 运行的 CPU、内存、FPS 和丢帧是否达到 `architecture.md` 门槛。

只有这些结果通过后，才进入真实 RustDesk packet/session 集成。
