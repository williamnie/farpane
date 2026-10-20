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
- Mac 会话工具栏提供启动台、调度中心和桌面快捷操作，仅在远端为 Mac 且允许键盘控制时启用。远端 FarPane Host 需同步升级以接受启动台和调度中心系统键；桌面操作使用远端 F11 快捷键。
- 显式控制的音频、剪贴板和双向文件传输，以及远端多显示器切换。
- Keychain 可选保存设备密码；密码不会写入配置、参数或日志。
- 内置 FPS、延迟、队列、CPU、内存和解码/渲染指标。
- Universal macOS App：`arm64` 与 `x86_64`。

### 当前状态

FarPane 已支持完整的 Viewer 与 Host 产品链：这台 Mac 既可以连接并控制其他设备，也可以通过被控 Host 接受入站连接。Host 包含屏幕采集、硬件编码、权限检查、后台 Agent、连接审批、密码、键鼠控制，以及可选音频、剪贴板、文件传输和多显示器能力。

下面保留的性能数据来自 Intel MacBook Pro 上通过真实 Linux-host 安全中继完成的约 30 分钟 Viewer 会话；它不等同于 Host 全场景性能验收：

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

### Linux 端（预览）

`Linux/` 下是同一产品的 Linux 原生版本：GTK4/libadwaita 首页与远程会话界面、原生 Host 核心（基于修改后的 RustDesk 核心）、VAAPI/DRM GPU 媒体管线和独立安装器，不需要另装 RustDesk 或系统 FFmpeg。目前在一台 Ubuntu GNOME Wayland 主机上完成了 Mac mini 入站画面、键鼠和中文输入的实机验证；构建、补丁与各项证据见 [`Linux/README.md`](Linux/README.md)。

最近更新（v0.2.9）：

- Mac 输入法提交的中文改为经 IBus 直接交给焦点应用，不再占用剪贴板、不依赖粘贴快捷键；Chrome、Zed、GNOME 文本编辑器实测正常。不接 IBus 的应用（如 Warp）自动回退为剪贴板粘贴，Warp 使用 Ctrl+Shift+V。
- 剪贴板粘贴路径会在一段输入结束后恢复用户原有的剪贴板内容；GNOME Wayland 下剪贴板经 Xwayland 读写。
- 首页窗口样式和小窗口布局修正，会话工具条可收起，提供 Debian/RPM 测试候选的打包工具。

已知问题与限制：

- **验证范围有限**：只在 GNOME Wayland 实机验证。KDE 等其他桌面、X11 会话、多显示器、多用户、锁屏/休眠/重启、24 小时长稳、Linux 发起连接到 Mac 的出站会话，以及音频、文件、富剪贴板与 Mac 的互操作都没有完整验收。
- **内核要求**：控制接口需要 Linux 6.5+（`SO_PEERPIDFD`），不会降级为不安全的 PID 检查。
- **中文输入**：IBus 提交只覆盖运行 IBus 的会话，fcitx 或未运行 IBus 时回退剪贴板粘贴；回退时除 Warp 外都发送 Shift+Insert，GNOME 屏幕阅读器 Orca 开启时会截走 Insert，导致这些应用收不到文字。连续输入期间及其后 1.5 秒内，IBus 表情面板（Ctrl+.）不可用。Mac 端“Ubuntu 中文兼容输入”开关应保持关闭，否则会重复输入。密码框、重连后和长时间使用尚未专门验收。
- **GPU**：VAAPI/DRM 硬件路径只在一种显卡配置上实测，不支持时回退软件编码，性能取决于硬件。
- **资源占用**：首页 GUI 实测约 130 MiB PSS，未达到 60 MiB 的目标。
- **桌面集成**：GNOME 概览第一次打开时可能显示通用图标，关闭再打开概览后恢复。
- **发布状态**：安装包属于测试候选（包名 `farpane-native-candidate`，`runtime_ready=false`），依赖许可来源审计还有 17 条记录未完成；安装和切换需按 [`Linux/docs/native-install.md`](Linux/docs/native-install.md) 在维护窗口进行。

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

产物位于 `Build/.app-staging.noindex/FarPane.app`，避免 Spotlight 自动索引待发布副本。稳定的本地 Accessibility/Input Monitoring 权限需要 Apple Development 签名身份；仅做不涉及 TCC 的开发时，可显式设置 `RDN_ALLOW_ADHOC_SIGNING=1`。

主程序使用 `io.rustdesknative.viewer`，后台 HostAgent 使用独立的 `io.rustdesknative.viewer.host-agent` 签名标识，避免本地网络权限缓存把两个程序的 UUID 混淆。HostAgent 仍由同一 App 的 SMAppService 管理；安装更新后应核验 Host 的屏幕录制、辅助功能和本地网络权限。

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

在 **共享设置 → 启动 → 开机自启** 中，可以选择登录 Mac 后自动打开 FarPane。开关读取系统登录项状态；需要系统批准时可直接打开“登录项与扩展”。退出应用不会取消此登录项，关闭开关才会取消下次登录启动。该功能不提供登录前的远程控制；明确关闭“允许连接此 Mac”后，自动启动不会重新启用被控端。

普通远程会话首次收到视频分辨率、或远端分辨率变化时，窗口会自动按画面比例调整大小，并根据本机 Retina 缩放和屏幕可用区域适配，避免标题栏或固定窗口比例造成额外黑边。同一分辨率下会保留手动调整的窗口大小；全屏期间不调整窗口，尚未应用的分辨率变化会在退出全屏后适配。

断开连接或关闭远程会话后，首页恢复连接前的窗口大小，默认内容区域为 1060×720 点；本次运行中手动调整的首页大小会保留，不受远端分辨率影响。全屏中返回首页时，尺寸恢复会延迟到退出全屏后执行。

HUD 可直接拖动，并记住普通会话的位置；缩放窗口或切换全屏时会保持在可见范围内。“接收 FPS”是控制端收到编码帧的速率，“呈现 FPS”是本地画面更新速率。

若连接 Ubuntu Wayland 后，Mac 输入法选字确认却没有上屏，可在会话中开启 **编辑 → Ubuntu 中文兼容输入**。该选项默认关闭、按设备记忆，在非 ASCII 文本提交后补发 `Ctrl+Shift+V`，适用于远端 RustDesk 的 `Shift+Insert` 自动粘贴失效、目标应用支持 `Ctrl+Shift+V` 的情况。英文保持原有输入方式；若目标应用已能正常自动上屏或出现重复文字，应关闭此项。使用 Mac 输入法时请保持普通键盘模式，独占键盘模式使用远端输入法。

### 诊断日志

在两端菜单选择 **FarPane → 打开诊断日志…**，或运行：

```sh
open "$HOME/Library/Logs/FarPane"
```

- 控制端：`ViewerSession/viewer-session-*.jsonl`，自动记录接收/呈现 FPS、距上一帧的时间、网络延迟、队列、解码错误、连接状态与自动重连结果。
- 被控端：`HostMedia/host-media-live-*.jsonl`，记录采集、编码、提交、网络压力和降帧原因。

Host 遇到系统停止屏幕采集（ScreenCaptureKit `-3821`）时，会在同一显示器上按 1、2、4 秒退避重建采集，60 秒内最多尝试三次。连接、编码器和时间戳保持连续；用户主动停止、权限失效或显示器不可用时不自动恢复。降帧配置更新失败保留旧配置并按原有间隔重试。Host 日志 schema v4 的 `captureRecovery` 记录错误码、尝试、重启和耗尽次数；`restartedStreams` 表示采集启动成功，是否恢复出帧仍需对照采集、编码和 Viewer 指标。

控制端每秒采样，包括 HUD 隐藏时；每 3,600 条记录轮转，保留最近 24 个文件及最多 7 天历史，断开时追加最终记录。轮转后的文件保留同一 `sessionStartedAt` 和连续 `sequence`。日志只含固定诊断字段，不记录密码、服务器地址、设备 ID 或画面；原始连接错误文本也不会落盘。`forceRelay` 只表示配置策略，不能证明实际传输路径。

Viewer 日志 schema v2 增加白名单 `stateReason`，区分暂时离线、主动断开、密钥不匹配、握手和连接建立失败；未知错误只记 `unclassified` 或通用分类。已出画面的会话断开后，保存了密码的连接最多按 0.5、1.5、3、6 秒间隔重试四次。建连阶段的暂时离线（`stateCode=16`）和已识别的网络建连失败（`stateCode=17`）允许继续重试，认证失败、远端主动断开及其他不可重试错误仍会终止恢复；首次连接失败不会触发这个恢复循环。

停帧时记下发生时间（JSONL 时间为 UTC），保留两端相应文件。接收停止而 Host 仍在提交时，继续检查传输与接收路径；接收继续而呈现停止时，检查解码错误与队列。`coreMetricsAgeMS` 可判断 Core 指标回调是否陈旧，序号缺口不等于 UDP 丢包率。这些记录能帮助定位停顿阶段，不能单独证明运营商 QoS；WireGuard 的握手、收发统计与隧道内连通性需要另行对照。

### 验收与性能

正式验收不会用 fixture 冒充真实远程链路。项目分别保留离线 fixture、短时 smoke、真实 H265 session 和 30 分钟正式验收证据。

```sh
Scripts/run-phase2-acceptance-mbp.sh
Scripts/run-phase3-acceptance-mbp.sh
Scripts/run-productization-acceptance-mbp.sh
```

最新验证结果与限制见 [`docs/benchmark-results.md`](docs/benchmark-results.md)。运行验收时不要把密码放入命令参数、仓库、日志或聊天记录。

### 发布

普通分支推送和 PR 不触发 GitHub Actions。只有推送 `v*` tag，或手动运行 [GitHub Release workflow](.github/workflows/release.yml) 并指定已有的 `v*` tag，才会执行测试、构建并创建 prerelease。签名 macOS 二进制由受信任的 macOS 构建机生成并上传；Developer ID notarization 接入前，Release 页面会明确标记预览属性。

打包时，松散的 `.app` 副本应留在隐藏的 `.noindex` 目录中，DMG 可以放在普通发布目录。不要在正式应用运行期间直接启动另一架构的待发布 `.app`（包括 `--help`）；这会让相同 Bundle ID 对应不同 Mach-O UUID，干扰本地网络授权。安装脚本会清理重复注册。手动验收或挂载 DMG 后，先卸载镜像，再执行 `python3 Scripts/register-installed-app.py /Applications/FarPane.app`（使用实际安装路径），确认只有正式安装版本保留注册；该命令不删除副本或重置权限。

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
- Launchpad, Mission Control, and Show Desktop toolbar actions for Mac peers with keyboard control. The remote FarPane Host must also be updated to accept the Launchpad and Mission Control keys; Show Desktop uses the remote F11 shortcut.
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

### Linux (preview)

`Linux/` holds the native Linux edition of the same product: a GTK4/libadwaita home and session UI, a native Host core (built on a modified RustDesk core), a VAAPI/DRM GPU media pipeline and a dedicated installer; RustDesk and a system FFmpeg are not required. Inbound video, keyboard/mouse and Chinese input from a Mac mini have been verified on one Ubuntu GNOME Wayland host. Build steps, patches and evidence are in [`Linux/README.md`](Linux/README.md).

Recent changes (v0.2.9):

- Text committed by the Mac input method is handed to the focused application through IBus, without touching the clipboard or relying on a paste shortcut; verified in Chrome, Zed and GNOME Text Editor. Applications that are not IBus clients (such as Warp) fall back to a clipboard paste, using Ctrl+Shift+V for Warp.
- The clipboard paste path restores the user's previous clipboard after a typing run; on GNOME Wayland the clipboard is accessed through Xwayland.
- Polished home window styling and small-window layouts, a collapsible session toolbar, and Debian/RPM test-candidate packaging tools.

Known issues and limitations:

- **Limited verification**: only GNOME Wayland has been tested on real hardware. Other desktops such as KDE, X11 sessions, multiple monitors, multiple users, lock/sleep/reboot, 24-hour stability, outbound sessions from Linux to a Mac, and audio, file and rich-clipboard interoperability with the Mac are not fully accepted.
- **Kernel**: the control channel requires Linux 6.5+ (`SO_PEERPIDFD`) and does not fall back to an unsafe PID check.
- **Chinese input**: IBus commits only work in sessions running IBus; with fcitx or without IBus the clipboard paste is used. That fallback sends Shift+Insert to every application except Warp, and the GNOME screen reader Orca captures Insert when enabled, so those applications then receive no text. The IBus emoji panel (Ctrl+.) is unavailable while typing and for 1.5 s afterwards. Keep the Mac "Ubuntu Chinese compatibility input" switch off, or text is entered twice. Password fields, reconnection and long sessions have not been specifically tested.
- **GPU**: the VAAPI/DRM hardware path has been measured on one GPU configuration; unsupported systems fall back to software encoding, and performance depends on hardware.
- **Resource use**: the home GUI measured about 130 MiB PSS, above the 60 MiB target.
- **Desktop integration**: the GNOME overview may show a generic icon the first time; it recovers after closing and reopening the overview.
- **Release status**: packages are test candidates (package name `farpane-native-candidate`, `runtime_ready=false`), and 17 records in the dependency license-source audit are still open. Install and switch over in a maintenance window as described in [`Linux/docs/native-install.md`](Linux/docs/native-install.md).

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

The result is `Build/.app-staging.noindex/FarPane.app`, which keeps staged copies out of Spotlight indexing. Stable local Accessibility/Input Monitoring permissions require an Apple Development signing identity. For development that does not exercise TCC, ad-hoc signing can be explicitly enabled with `RDN_ALLOW_ADHOC_SIGNING=1`.

The app uses signing identifier `io.rustdesknative.viewer`, while HostAgent uses `io.rustdesknative.viewer.host-agent` so the local network permission cache can distinguish their executable UUIDs. HostAgent remains managed by the app's SMAppService; verify Host screen recording, Accessibility, and local network access after installing an update.

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

Use **共享设置 → 启动 → 开机自启** to launch FarPane after signing in to your Mac. The switch reflects the system login item and offers a link to System Settings when approval is required. Quitting the app preserves this choice; switching it off disables future login launches. This does not enable remote control before login, and explicitly disabling Host remains effective after the next launch.

Disconnecting or closing a remote session restores the home window's previous size, with a default content area of 1060×720 points. Manual home-window resizing is retained during the current app run and is independent of the remote resolution. When returning home in fullscreen, restoration waits until fullscreen ends.

Drag the HUD to reposition it. Normal sessions remember its position and keep it visible after resizing or fullscreen transitions. Received FPS measures encoded frames arriving at the Viewer; presented FPS measures local display updates.

### Diagnostic logs

Choose **FarPane → 打开诊断日志…** on each endpoint, or run:

```sh
open "$HOME/Library/Logs/FarPane"
```

Viewer logs are in `ViewerSession/viewer-session-*.jsonl`; Host media logs are in `HostMedia/host-media-live-*.jsonl`. The Viewer records frame rates, time since the last received/presented frame, delay, queues, decoder errors, connection states, and recovery outcomes every second, even with the HUD hidden. Files rotate after 3,600 records and retain at most 24 files for seven days. Rotation preserves `sessionStartedAt` and consecutive `sequence` values; disconnect appends a final record. Logs exclude credentials, server addresses, device IDs, images, and raw error messages. `forceRelay` records configuration policy rather than the actual transport.

Viewer log schema v2 adds an allowlisted `stateReason` for temporary offline, manual close, key mismatch, handshake, and connection establishment failures. Unknown text is recorded only as `unclassified` or a generic category. After a streaming session disconnects, connections with saved credentials retry at most four times with delays of 0.5, 1.5, 3, and 6 seconds. Temporary offline (`stateCode=16`) and recognized network connection establishment failures (`stateCode=17`) permit another attempt during connection establishment; authentication failures, explicit peer closes, and other non-retryable errors stop recovery. Initial connection failures do not enter this recovery loop.

When the system stops Host screen capture with ScreenCaptureKit error `-3821`, capture restarts on the same display after delays of 1, 2, and 4 seconds, with at most three attempts per 60 seconds. The connection, encoder, and timestamp baseline remain intact. User stops, permission failures, and unavailable displays do not trigger recovery. Failed frame-rate configuration updates retain the old configuration and retry. Host log schema v4 adds numeric `captureRecovery` diagnostics; `restartedStreams` counts successful starts, so verify frame delivery separately using pipeline and Viewer metrics.

Note the failure time and keep the corresponding logs from both endpoints; JSONL timestamps use UTC. Compare Host submission, Viewer reception, and presentation to locate the stalled stage. `coreMetricsAgeMS` tracks Core callback freshness; sequence gaps do not measure UDP packet loss. Diagnosing ISP QoS also requires contemporaneous WireGuard handshake/transfer statistics and tunnel connectivity evidence.

### Acceptance and performance

Formal acceptance never substitutes a fixture for a real remote session. The repository distinguishes offline fixtures, short smokes, real H265 sessions, and retained 30-minute acceptance evidence.

```sh
Scripts/run-phase2-acceptance-mbp.sh
Scripts/run-phase3-acceptance-mbp.sh
Scripts/run-productization-acceptance-mbp.sh
```

See [`docs/benchmark-results.md`](docs/benchmark-results.md) for current results and limitations. Never place a password in command arguments, repository files, logs, or chat.

### Releases

Branch pushes and pull requests do not trigger GitHub Actions. Only pushing a `v*` tag or manually running the [GitHub Release workflow](.github/workflows/release.yml) with an existing `v*` tag runs the tests, builds the viewer, and creates a prerelease. Signed macOS binaries are produced and uploaded from a trusted macOS signing host. Until Developer ID notarization is wired in, the Releases page explicitly identifies these binaries as previews.

Keep unpacked `.app` copies in a hidden `.noindex` directory; DMGs can remain in the regular release directory. Do not launch another architecture's staged app, even with `--help`, while the installed app is running: different Mach-O UUIDs sharing one bundle identifier can disrupt local network authorization. The installer removes duplicate registrations. After manual bundle or DMG checks, unmount the image and run `python3 Scripts/register-installed-app.py /Applications/FarPane.app` with the actual installed path. This preserves all copies and permissions while keeping only the installed app registered.

### License

FarPane is licensed under the [GNU Affero General Public License v3.0](LICENSE). It includes a modified RustDesk Core 1.4.9. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the pinned source commit, modification scope, and third-party notices.

The AGPL permits use, modification, redistribution, and commercial distribution. When conveying or making a modified covered program available over a network, comply with the license's corresponding-source and notice requirements.
