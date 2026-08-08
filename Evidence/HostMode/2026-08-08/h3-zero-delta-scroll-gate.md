# H3.4u zero-delta scroll semantic no-op gate

## Outcome

Viewer producer 与 Host typed normalizer 现在都会在 queue admission 前拒绝零增量 wheel/trackpad event，避免没有任何平台输入动作的消息刷新 Native Host activity authority。

## Key evidence

- Viewer `rdn_client_send_pointer` 原本把 Scroll/PreciseScroll delta clamp 到 `[-120,120]` 后直接发送，即使结果为 `(0,0)`。
- Host `NormalizedMouseInput::from_wire` 原本接受两个轴都为零的 `MOUSE_TYPE_WHEEL` / `MOUSE_TYPE_TRACKPAD`；macOS adapter 仅对非零轴调用 Enigo，因此最终 no-op。
- connection 会把成功入队视为 authorized input，提交 peer-input activity 并刷新 auto-disconnect；零滚动因此产生了与实际输入不一致的副作用。
- Viewer 新的 coordinate normalization 在 clamp 后要求至少一个非零轴；Host wheel/trackpad typed branches 使用相同 invariant。Swift `ScrollDeltaMapper` 已有零值过滤，无需修改。

## Verification

- Viewer producer targeted test：1 passed。
- Host mouse normalization targeted test：1 passed。
- 完整 Rust lib：122 passed，0 failed。
- release Rust core：成功生成 arm64 Mach-O dylib。
- built-core Host contract：3 passed；built-core ABI smoke：1 passed。
- 完整 Swift：109 tests，4 skipped，0 failures。
- release `RustDeskNative`：构建成功。
- canonical patch reverse-check、diff checks、bridge mirror comparison：通过。
- pinned HEAD clean replay：16 个 tracked 文件逐一一致，2 个 bridge mirror 一致。

## Boundary and next step

- 未修改 ABI shape、protobuf/wire、Host ABI/snapshot、Hermes、CI、根依赖或数据库。
- 本步不改变任何非零滚动 delta，也不把自动回归冒充真实滚轮/触控板方向和手感验收。
- Mini/MBP 真机仍需验证 discrete wheel 与 precise trackpad；自动工作继续审计其他不依赖 shared contract 的 H3 semantic input 边界。
