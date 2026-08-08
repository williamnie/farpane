# H3.4y desktop control-key consumer coverage

## Outcome

Desktop Host typed key normalization 现在只接受最终 consumer 能处理的 control key；无 desktop 映射的媒体/电源键不会再成功入队后 no-op。

## Key evidence

- protobuf `ControlKey` 包含 `VolumeMute`、`VolumeUp`、`VolumeDown`、`Power`，但 desktop input service `KEY_MAP` 不包含这四项。
- `process_control_key` 只在 `KEY_MAP.get(control.value())` 成功时执行 key down/up；未命中时静默返回。
- Native Host 过去会在 normalizer 后将这些事件入队，并把 queued=true 提交为 peer-input activity/auto-disconnect reset。
- `legacy_control_key_is_supported` 现在以 `KEY_MAP` 为普通 control-key authority，同时显式保留由 `is_function_key` 消费的 `CtrlAltDel`/`LockScreen`。
- 回归覆盖 Unknown 和四个无 consumer enum 的拒绝，H3.4w 的两个 pseudo-key canonical Down 仍通过。

## Verification

- Host key normalization targeted test：1 passed。
- 完整 Rust lib：123 passed，0 failed。
- release Rust core：成功生成 arm64 Mach-O dylib。
- built-core Host contract：3 passed；built-core ABI smoke：1 passed。
- 完整 Swift：109 tests，4 skipped，0 failures。
- release `RustDeskNative`：构建成功。
- canonical patch reverse-check、diff checks、bridge mirror comparison：通过。
- pinned HEAD clean replay：16 个 tracked 文件逐一一致，2 个 bridge mirror 一致。

## Boundary and next step

- 未修改 protobuf、Viewer/Host ABI、Hermes、CI、根依赖或数据库。
- 移动端 main-service input 有独立 media-key projection，本步只约束 desktop connection 的 typed Host path。
- 若未来 macOS 需要媒体键，应先实现并真机验证明确 consumer，再扩展 capability；不能只放宽 normalizer。
- 自动工作继续审计其他不依赖 shared contract 的 H3 semantic input 边界；Mini/MBP 仍按既定清单验收 drag、scroll 与 modifier reconnect。
