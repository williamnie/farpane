# H3.4t Viewer character NUL semantic parity

## Outcome

Viewer key producer 现在拒绝 `Character` 的 NUL scalar，不再对 Host 必然拒绝的输入返回发送成功。普通有效 Unicode scalar 的既有映射保持不变。

## Key evidence

- `rdn_bridge::key_name(RDNKeyCode::Character, 0)` 原本能生成包含 NUL 的 `String`，`rdn_client_send_key` 会据此返回成功并发送 wire event。
- Host `NormalizedKeyInput::from_wire` 对 legacy character/unicode NUL fail closed；Viewer text API 的 `validated_text` 也拒绝 NUL。旧行为因此是 producer success、remote no-op。
- `Character` 分支现在先验证 Unicode scalar，再明确过滤 `\0`；无效 scalar 与 NUL 都返回 `None`，事件不会进入 wire。
- producer 回归覆盖 scalar 0，两个 tracked bridge mirror 与 vendored source 完全一致。

## Verification

- `cargo test --features rdn-native-core,rdn-native-host --lib maps_basic_semantic_keys`：1 passed。
- 完整 Rust lib：122 passed，0 failed。
- release Rust core：成功生成 arm64 Mach-O dylib。
- built-core Host contract：3 passed；built-core ABI smoke：1 passed。
- 完整 Swift：109 tests，4 skipped，0 failures。
- release `RustDeskNative`：构建成功。
- canonical patch reverse-check、diff checks、bridge mirror comparison：通过。
- pinned HEAD clean replay：16 个 tracked 文件逐一一致，2 个 bridge mirror 一致。

## Boundary and next step

- 未修改 ABI shape、protobuf/wire、Host ABI/snapshot、Hermes、CI、根依赖或数据库。
- 本步只消除 NUL 的假成功，不宣称真实键盘布局、dead key、IME、快捷键或文本输入已完成真机验收。
- 下一步由 Mini/MBP 真机验证拖拽、滚动、快速重连后的修饰键清理和普通文本输入；自动工作继续处理不需要 shared contract 的 H3 输入边界。
