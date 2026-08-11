# H6.1a Host audio product ownership audit

## Outcome

H6.1 尚未实现，下一步必须先建立 default-off Host audio policy ABI。
Pinned RustDesk 已经拥有 macOS microphone capture、Opus wire、Viewer decode/buffer/
playback 和 connection-scoped revoke；FarPane 当前在 Host 与 Viewer 两端都显式关闭
音频，因此不会意外启用上游缺省能力。

本审计冻结 Host ABI v18 与 Viewer ABI v17 的后续边界；本步没有修改共享 ABI、
RustDesk wire、Hermes、依赖或产品运行行为，也不宣称音频可用。

## Current authoritative chain

1. Release Core 只启用 `rdn-native-core,rdn-native-host`，没有启用上游
   `screencapturekit` feature；因此 macOS Host 音频主路是 cpal native default input，
   即系统默认麦克风。
2. Pinned RustDesk audio service 负责输入采集、采样率/声道归一化、Opus 编码、
   `AudioFormat`/`AudioFrame` 发送以及按 connection permission 订阅。
3. Pinned Viewer `Remote` audio thread 与 `AudioHandler` 负责 Opus 解码、有界缓冲、
   重采样/声道转换及 cpal default output 播放；音频 payload 不需要进入 Swift ABI。
4. 已有 active-session `DisableAudio` 命令通过 exact connection authority 发送
   `SwitchPermission(audio=false)`，Host subscription 与 capability snapshot 随之收敛。
5. 当前 Host start 固定并回读 `enable-audio=N`；native Viewer
   `configure_native_viewer` 固定 `disable_audio=true`。两端均未产品启用。

## Confirmed gaps

- `RdnHostCreateOptions`/`HostServerConfiguration` 没有 immutable、default-off
  `enableAudio` policy；Host 只能固定写 `N`。
- `RDNConnectionConfig`/`CoreConnectionConfig` 没有 default-off `receiveAudio`；native
  Viewer 只能固定禁用播放。
- App 没有 `NSMicrophoneUsageDescription`、microphone TCC preflight/request、后台
  bootstrap audio policy 或 Home 明示开关。
- `BridgeUi.set_permission` 不投影远端 audio permission，Viewer 无法呈现真实音频状态。
- incoming approval 的 requested capabilities 只检查远端 `disable_audio`，尚未与 Host
  local audio policy 求交集；当前关闭状态下仍可能错误呈现 `hearSystemAudio` 请求。
- FarPane 没有 bounded audio-input catalog 或显式虚拟设备选择 owner。
- 单机安装 smoke、双机麦克风/虚拟设备、撤权、断线、延迟/CPU/互操作均未验收。

## Frozen next contract

- Host ABI v18 增加 immutable `enableAudio` Boolean，Swift 默认 false；必须在任何
  identity/network runtime 前持久化并 readback `enable-audio=Y/N`，现有调用方继续
  不 opt in。
- Viewer ABI v17 后续增加 immutable `receiveAudio` Boolean，Swift 默认 false；只有
  true 才允许 native config 清除 `disable_audio`，无需把编码或 PCM payload 送入 Swift。
- 麦克风是主路；App 明确取得/观察 microphone TCC 后才可发布 Host opt-in，权限缺失
  只关闭音频，不影响屏幕/输入 ready。
- system audio 不启用 ScreenCaptureKit 自动 loopback；仅允许用户显式选择第三方虚拟
  input device。首个产品步骤先使用系统默认麦克风，device catalog/virtual selection
  独立实现。
- approval、active capability、subscription 与 Viewer permission presentation 必须消费
  同一 effective audio policy；拒绝、撤权、disconnect/replacement 都 fail closed。
- RustDesk `AudioFormat`/`AudioFrame` wire、Opus capture/playback owners 保持不变；
  不需要 Hermes、protobuf、根依赖或数据库修改。

## Verification

- RED：focused regression 仅因审计脚本缺失而失败。
- GREEN focused ScriptTest：1/1。
- Ownership audit：`implementation-required`；11/11 established evidence、8/8
  confirmed gaps、14/14 source anchors。
- Full Swift tests: 1008 executed, 4 environment-dependent tests skipped, 0
  failures.
- Full ScriptTests: 183/183.
- Isolated fresh arm64 release build: passed.
- Python compile and `git diff --check`: passed.

## Next boundary

下一自动步骤为 `host-audio-explicit-policy-abi-contract`：只建立 Host ABI v18
default-off policy、启动前持久化/readback 与 local approval policy intersection；不在
同一步加入 Home/TCC、Viewer playback opt-in 或虚拟设备选择。
