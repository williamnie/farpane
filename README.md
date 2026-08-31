# FarPane

<p align="center">
  <img src="App/Brand/FarPane-Logo.svg" alt="FarPane" width="420">
</p>

<p align="center">
  面向 macOS 的原生远程桌面客户端<br>
  A native remote-desktop client for macOS
</p>

<p align="center">
  <a href="#中文">中文</a> · <a href="#english">English</a> ·
  <a href="docs/README.md">文档 / Docs</a> ·
  <a href="https://github.com/williamnie/farpane/releases">Releases</a>
</p>

> [!IMPORTANT]
> FarPane 是独立开源项目，不是 RustDesk 官方客户端。连接、认证、加密和网络协议由固定版本的 RustDesk Core 提供。
>
> FarPane is an independent open-source project, not an official RustDesk client. Connection, authentication, encryption, and wire-protocol handling are provided by a pinned RustDesk Core.

> [!NOTE]
> **同时支持控制端与被控端。** FarPane 既可以作为 Viewer 连接并控制远端设备，也可以开启被控 Host，让其他设备连接并控制这台 Mac。
>
> **FarPane supports both Viewer and Host roles.** It can control another device or accept an incoming remote-control session on this Mac.

## 中文

FarPane 是面向 macOS 13 及以上系统的原生远程桌面客户端。作为 Viewer，它通过 VideoToolbox 硬件解码 H265，并用 Metal 直接渲染 NV12 IOSurface；作为 Host，它使用 ScreenCaptureKit 采集屏幕，并通过 VideoToolbox 硬件编码 H264/H265。

### 主要能力

- 原生 AppKit 多设备首页、收藏、别名和最近连接记录。
- RustDesk 自托管 ID/Relay、认证、加密和会话连接。
- Viewer 控制端与被控 Host 双角色；Host 支持后台 Agent、临时/永久密码、入站审批和会话内撤权。
- VideoToolbox H265 硬件解码与 Metal 零 CPU 整帧拷贝渲染。
- ScreenCaptureKit 屏幕采集与 VideoToolbox H264/H265 硬件编码。
- Retina/aspect-fit 坐标映射、鼠标、拖拽、滚轮和键盘输入。
- AppKit 本地输入法提交，以及可选的远端独占键盘模式。
- 显式控制的音频、剪贴板和双向文件传输，以及远端多显示器切换。
- Keychain 可选保存设备密码；密码不会写入配置、参数或日志。
- 内置 FPS、延迟、队列、CPU、内存和解码/渲染指标。
- Universal macOS App：`arm64` 与 `x86_64`。

### 当前状态

FarPane 已支持完整的 Viewer 与 Host 产品链：这台 Mac 既可以连接并控制其他设备，也可以通过被控 Host 接受入站连接。Host 包含屏幕采集、硬件编码、权限检查、后台 Agent、连接审批、密码、键鼠控制，以及可选音频、剪贴板、文件传输和多显示器能力。

下面保留的性能数据来自 Intel MacBook Pro 上通过真实 Hermes 安全中继完成的约 30 分钟 Viewer 会话；它不等同于 Host 全场景性能验收：

| 指标 | 已接受结果 |
| --- | --- |
| 远端画布 | 4096×2304 H265 |
| 运行时长 | 1,800.111 秒（约 30 分钟） |
| 平均 Viewer App CPU | **5.805%** |
| 解码 / 呈现帧数 | 46,789 / 46,431 |
| 稳定性 | 0 次解码错误、参考帧丢失、解码器重置、关键帧请求或包间断 |
| RSS 稳态趋势 | 0.441178 MB/分钟 |

这里的 CPU 是该次验收中 FarPane App 进程的平均值，并非不同硬件、分辨率、网络、画面负载或系统进程的总 CPU。原始采样和校验文件位于 [`Evidence/`](Evidence/)，完整条件与限制见 [`docs/benchmark-results.md`](docs/benchmark-results.md)。

当前边界：

- Host 需要按用途授予屏幕录制、辅助功能和输入监控权限；显式选择麦克风或虚拟输入设备时还需要麦克风权限。
- 仅支持 macOS 13 及以上系统。
- Viewer 以 H265 硬件解码为正式链路；Host 支持 H264/H265 硬件编码与兼容性协商。
- 音频、剪贴板和文件传输默认关闭，必须由用户显式开启；相关权限可在当前会话中单独撤销。
- Host Mode 代码开发已完成，但双机、Direct/Relay、睡眠/网络/显示切换及不同硬件上的完整发布验收仍需按场景继续补充，见 [`docs/host-mode-design.md`](docs/host-mode-design.md)。
- Release 预览包尚未经过 Apple notarization；源码和本地构建不受此限制。

### 架构

| 层 | 职责 |
| --- | --- |
| RustDesk Core 1.4.9 | Viewer/Host 连接、认证、加密、直连/中继、协议和会话数据面 |
| Core Bridge | 版本化窄 C ABI、压缩视频 packet、Host 控制、状态、指标和语义输入 |
| ScreenCaptureKit | Host 屏幕采集与原生系统音频采集 |
| VideoToolbox | Viewer H265 硬件解码与 Host H264/H265 硬件编码 |
| Metal | IOSurface-backed Y/UV texture、BT.709 转换和低延迟呈现 |
| AppKit / Host Agent | 设备首页、Viewer 会话、被控 Host、权限、后台运行、Keychain 和性能 HUD |

Swift 层不导入 RustDesk protobuf 或内部 Rust 类型，也不提供 CPU 侧整帧 RGBA fallback。完整设计见 [`docs/architecture.md`](docs/architecture.md)。

### 构建与测试

要求：

- macOS 13+
- Xcode 15.2+ / Swift 5.9+
- Rust toolchain
- 构建 RustDesk Core 时需要 CMake、NASM 和脚本固定的 vcpkg 依赖

运行测试：

```sh
swift test
python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'
```

构建当前机器架构的 RustDesk Core：

```sh
Scripts/build-rust-core.sh
```

脚本会检出固定的 RustDesk 1.4.9 commit、应用仓库内补丁、准备固定 vcpkg 依赖，并生成：

```text
Build/CoreBridge/<arch>/liblibrustdesk.dylib
```

当 `arm64` 和 `x86_64` Core 均已准备好后，构建 Universal App：

```sh
Scripts/build-universal.sh
```

产物位于 `Build/FarPane.app`。稳定的本地 Accessibility/Input Monitoring 权限需要 Apple Development 签名身份；仅做不涉及 TCC 的开发时，可显式设置 `RDN_ALLOW_ADHOC_SIGNING=1`。

如果当前机器只能构建自身架构，可显式生成单架构 App；默认不设置时仍严格构建 Universal App：

```sh
RDN_BUILD_ARCHITECTURES=arm64 Scripts/build-universal.sh
# Intel Mac 上使用：RDN_BUILD_ARCHITECTURES=x86_64 Scripts/build-universal.sh
```

脚本只会装入所选架构对应的 `Build/CoreBridge/<arch>/liblibrustdesk.dylib`，缺失时直接失败，不会用另一架构或陈旧 Universal Core 回退。

安装到固定的用户路径：

```sh
Scripts/install-local-macos.sh
```

安装位置为 `~/Applications/FarPane.app`。

### 使用

作为控制端，启动 FarPane 后填写：

1. RustDesk ID Server
2. Server Public Key
3. 远端设备 ID
4. 密码（可以选择保存到本机 Keychain）

FarPane 只把固定 Core 路径作为内部实现细节，不要求用户选择动态库。需要使用鼠标和键盘控制时，请在远端授予相应控制权限；独占键盘模式还需要本机 Accessibility 与 Input Monitoring 权限。

作为被控端：

1. 配置同一 RustDesk ID Server 与 Server Public Key。
2. 在系统设置中授予屏幕录制、辅助功能和输入监控权限。
3. 在首页开启“被控 Host”，确认本机 ID 和临时密码，或设置永久密码。
4. 收到入站请求后在 FarPane 中批准或拒绝；音频、剪贴板和文件传输按需单独开启。

### 验收与性能

正式验收不会用 fixture 冒充真实远程链路。项目分别保留离线 fixture、短时 smoke、真实 H265 session 和 30 分钟正式验收证据。

```sh
Scripts/run-phase2-acceptance-mbp.sh
Scripts/run-phase3-acceptance-mbp.sh
Scripts/run-productization-acceptance-mbp.sh
```

最新验证结果与限制见 [`docs/benchmark-results.md`](docs/benchmark-results.md)。运行验收时不要把密码放入命令参数、仓库、日志或聊天记录。

### 发布

向 `v*` tag 推送后，[GitHub Release workflow](.github/workflows/release.yml) 会重新执行测试并创建 prerelease。签名 macOS 二进制由受信任的 macOS 构建机生成并上传；Developer ID notarization 接入前，Release 页面会明确标记预览属性。

### 许可证

FarPane 按 [GNU Affero General Public License v3.0](LICENSE) 开源。项目包含修改后的 RustDesk Core 1.4.9；对应来源、commit、补丁范围和第三方说明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

AGPL 允许使用、修改、再分发和商业收费，但发布或通过网络提供修改后的受保护程序时，必须依照许可证提供对应源代码并保留相应权利。

## English

FarPane is a native remote-desktop client for macOS 13 and later. As a Viewer it uses VideoToolbox for hardware H265 decoding and Metal for NV12 IOSurface rendering. As a Host it captures the display with ScreenCaptureKit and hardware-encodes H264/H265 through VideoToolbox.

### Highlights

- Native AppKit device home screen with favorites, aliases, and recent connections.
- RustDesk self-hosted ID/Relay connectivity, authentication, encryption, and sessions.
- Viewer and Host roles, including a background Host Agent, temporary/permanent passwords, incoming approval, and per-session revocation.
- Hardware H265 decode through VideoToolbox and Metal rendering without CPU full-frame copies.
- ScreenCaptureKit display capture with VideoToolbox H264/H265 hardware encoding.
- Retina-aware aspect-fit mapping, pointer, drag, wheel, and keyboard input.
- AppKit-committed local IME text plus an optional exclusive remote-keyboard mode.
- Explicit audio, clipboard, bidirectional file-transfer, and remote multi-display controls.
- Optional password storage in Keychain; secrets never enter settings, arguments, or logs.
- Built-in FPS, latency, queue, CPU, memory, decode, and render metrics.
- Universal macOS application for `arm64` and `x86_64`.

### Project status

FarPane now implements both Viewer and Host product paths. This Mac can connect to and control another device, or accept an incoming remote-control session with display capture, hardware encoding, permission gates, a background Host Agent, approval/password flows, input control, and optional audio, clipboard, file transfer, and multi-display support.

The retained performance data below is from a roughly 30-minute real secure-relay Viewer session on an Intel MacBook Pro; it is not a complete Host performance qualification:

| Metric | Accepted result |
| --- | --- |
| Remote canvas | 4096×2304 H265 |
| Runtime | 1,800.111 seconds (about 30 minutes) |
| Average Viewer App CPU | **5.805%** |
| Decoded / presented frames | 46,789 / 46,431 |
| Stability | Zero decode errors, reference drops, decoder resets, keyframe requests, or packet gaps |
| Steady RSS slope | 0.441178 MB/min |

CPU here is the FarPane App process average for that accepted run, not total system CPU or a guarantee for other hardware, resolutions, networks, or workloads. Raw samples and checksum manifests are retained under [`Evidence/`](Evidence/); see [`docs/benchmark-results.md`](docs/benchmark-results.md) for the complete conditions and limitations.

Current boundaries:

- Host requires Screen Recording, Accessibility, and Input Monitoring permissions as applicable. Selecting a microphone or virtual input also requires Microphone permission.
- macOS 13 or later only.
- H265 hardware decoding is the qualified Viewer path; Host supports H264/H265 hardware encoding and compatibility negotiation.
- Audio, clipboard, and file transfer are default-off and require explicit user opt-in; individual capabilities can be revoked during a session.
- Host Mode development is complete, while the full cross-device, Direct/Relay, sleep/network/display-transition, and hardware release-acceptance matrix remains pending; see [`docs/host-mode-design.md`](docs/host-mode-design.md).
- Preview release binaries are not yet Apple-notarized; this does not affect source or local builds.

### Architecture

| Layer | Responsibility |
| --- | --- |
| RustDesk Core 1.4.9 | Viewer/Host connection, authentication, encryption, direct/relay transport, protocol, and session data plane |
| Core Bridge | Versioned narrow C ABI, encoded packets, Host control, state, metrics, and semantic input |
| ScreenCaptureKit | Host display capture and native system-audio capture |
| VideoToolbox | Viewer H265 hardware decoding and Host H264/H265 hardware encoding |
| Metal | IOSurface-backed Y/UV textures, BT.709 conversion, and low-latency presentation |
| AppKit / Host Agent | Device home, Viewer sessions, Host mode, permissions, background operation, Keychain, and performance HUD |

The Swift layer does not import RustDesk protobuf or internal Rust types, and there is no CPU full-frame RGBA fallback. See [`docs/architecture.md`](docs/architecture.md) for the complete design.

### Build and test

Requirements:

- macOS 13+
- Xcode 15.2+ / Swift 5.9+
- Rust toolchain
- CMake, NASM, and the pinned vcpkg dependencies when building RustDesk Core

Run the test suites:

```sh
swift test
python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'
```

Build RustDesk Core for the current machine architecture:

```sh
Scripts/build-rust-core.sh
```

The scripts verify the pinned RustDesk 1.4.9 commit, apply the tracked patch, prepare pinned vcpkg dependencies, and produce:

```text
Build/CoreBridge/<arch>/liblibrustdesk.dylib
```

Once both `arm64` and `x86_64` Core libraries are available, build the Universal App:

```sh
Scripts/build-universal.sh
```

The result is `Build/FarPane.app`. Stable local Accessibility/Input Monitoring permissions require an Apple Development signing identity. For development that does not exercise TCC, ad-hoc signing can be explicitly enabled with `RDN_ALLOW_ADHOC_SIGNING=1`.

When a machine can only build its native architecture, explicitly request a
single-architecture App. The default remains a strict Universal build:

```sh
RDN_BUILD_ARCHITECTURES=arm64 Scripts/build-universal.sh
# On an Intel Mac: RDN_BUILD_ARCHITECTURES=x86_64 Scripts/build-universal.sh
```

The script packages only the matching
`Build/CoreBridge/<arch>/liblibrustdesk.dylib` and fails if it is missing; it
does not fall back to another architecture or a stale Universal Core.

Install to the stable per-user location:

```sh
Scripts/install-local-macos.sh
```

The installed application is `~/Applications/FarPane.app`.

### Usage

As a Viewer, launch FarPane and provide:

1. RustDesk ID Server
2. Server Public Key
3. Remote device ID
4. Password, optionally stored in the local Keychain

The bundled Core path is an implementation detail rather than a user-facing setting. Grant remote-control permission on the peer before using pointer and keyboard input. Exclusive keyboard mode also requires local Accessibility and Input Monitoring permission.

As a Host:

1. Configure the same RustDesk ID Server and Server Public Key.
2. Grant Screen Recording, Accessibility, and Input Monitoring permissions in System Settings.
3. Enable “被控 Host” on the home screen, then use the displayed device ID and temporary password or configure a permanent password.
4. Approve or reject incoming requests in FarPane. Enable audio, clipboard, and file transfer separately when needed.

### Acceptance and performance

Formal acceptance never substitutes a fixture for a real remote session. The repository distinguishes offline fixtures, short smokes, real H265 sessions, and retained 30-minute acceptance evidence.

```sh
Scripts/run-phase2-acceptance-mbp.sh
Scripts/run-phase3-acceptance-mbp.sh
Scripts/run-productization-acceptance-mbp.sh
```

See [`docs/benchmark-results.md`](docs/benchmark-results.md) for current results and limitations. Never place a password in command arguments, repository files, logs, or chat.

### Releases

Pushing a `v*` tag runs the [GitHub Release workflow](.github/workflows/release.yml), repeats the test gates, and creates a prerelease. Signed macOS binaries are produced and uploaded from a trusted macOS signing host. Until Developer ID notarization is wired in, the Releases page explicitly identifies these binaries as previews.

### License

FarPane is licensed under the [GNU Affero General Public License v3.0](LICENSE). It includes a modified RustDesk Core 1.4.9. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the pinned source commit, modification scope, and third-party notices.

The AGPL permits use, modification, redistribution, and commercial distribution. When conveying or making a modified covered program available over a network, comply with the license's corresponding-source and notice requirements.
