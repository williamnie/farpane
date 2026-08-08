# H3.4x Native Host privileged-key platform capability

## Outcome

Native Host 现在会在 queue admission 前拒绝平台没有实现的 `CtrlAltDel`；macOS/Linux 不再把该 no-op 记作有效输入，Windows-capable 与 non-Native 行为保持。

## Key evidence

- `is_function_key(ControlKey::CtrlAltDel)` 在所有 desktop platform 返回 handled，但真正的 `send_sas()` spawn 被 `#[cfg(windows)]` 包围；macOS/Linux 最终没有系统动作。
- connection 过去在 typed normalization 后直接 `input_key`，成功入队会提交 `MOUSE_MOVE_TIME` 和 auto-disconnect reset。
- 新的 `native_host_key_input_kind_enabled` 只对 Native Host 的 CtrlAltDel 查询 `platform_sas_supported`；其他 key 不受影响。
- macOS build 通过 `cfg!(target_os = "windows") == false` fail closed；Windows build 可继续进入现有 SAS consumer。
- 回归覆盖 Native Host unsupported/supported、non-Native compatibility 和 LockScreen 保留。

## Verification

- Native Host privileged-key capability targeted test：1 passed。
- 完整 Rust lib：123 passed，0 failed。
- release Rust core：成功生成 arm64 Mach-O dylib。
- built-core Host contract：3 passed；built-core ABI smoke：1 passed。
- 完整 Swift：109 tests，4 skipped，0 failures。
- release `RustDeskNative`：构建成功。
- canonical patch reverse-check、diff checks、bridge mirror comparison：通过。
- pinned HEAD clean replay：16 个 tracked 文件逐一一致，2 个 bridge mirror 一致。

## Boundary and next step

- 未修改 protobuf、Viewer/Host ABI、Hermes、CI、根依赖或数据库。
- 未自动触发 LockScreen/SAS，避免改变用户 GUI 会话；本步只验证 capability/admission policy。
- FarPane Viewer 当前不暴露 CtrlAltDel；若未来提供系统动作 UI，需要独立权限、确认和状态合同。
- 自动工作继续审计其他不依赖 shared contract 的 H3 semantic input 边界；Mini/MBP 仍按既定清单验收 drag、scroll 与 modifier reconnect。
