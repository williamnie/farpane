# H3.4v zero-delta relative-mouse semantic gate

## Outcome

Host typed mouse normalization 现在会在 queue admission 前拒绝 `(0,0)` relative move，避免无位移事件切换 relative mode、刷新 cursor tracking 和 Native Host activity authority。

## Key evidence

- `NormalizedMouseInput::from_wire` 原本只验证 relative event 没有 button bits，并把 delta 限制到 `[-10000,10000]`；`(0,0)` 会得到 `SemanticMouseKind::RelativeMove`。
- adapter 对 accepted relative event 无条件调用 `set_relative_mouse_active(conn, true)` 和 `mouse_move_relative(dx,dy)`，随后尝试更新 `LATEST_PEER_INPUT_CURSOR`。
- Native Host connection 以 queue send 成功为 activity commit，更新 `MOUSE_MOVE_TIME`/auto-disconnect；因此 zero-delta event 具有状态副作用但没有实际指针位移。
- normalizer 现在在 clamp 后要求至少一个轴非零；现有极值 clamp test 与新增 zero-delta rejection 同时覆盖。

## Verification

- Host mouse normalization targeted test：1 passed。
- 完整 Rust lib：122 passed，0 failed。
- release Rust core：成功生成 arm64 Mach-O dylib。
- built-core Host contract：3 passed；built-core ABI smoke：1 passed。
- 完整 Swift：109 tests，4 skipped，0 failures。
- release `RustDeskNative`：构建成功。
- canonical patch reverse-check、diff checks、bridge mirror comparison：通过。
- pinned HEAD clean replay：16 个 tracked 文件逐一一致，2 个 bridge mirror 一致。

## Boundary and next step

- 未修改 Viewer ABI、protobuf/wire、Host ABI/snapshot、Hermes、CI、根依赖或数据库。
- FarPane Viewer 当前只生产 absolute Move；本步防御旧版或其他 RustDesk peer 的 malformed/no-op relative input，不宣称 gaming relative mode 已完成互操作验收。
- 自动工作继续审计其他不依赖 shared contract 的 H3 semantic input 边界；Mini/MBP 仍按既定清单验收 absolute drag、scroll 与 modifier reconnect。
