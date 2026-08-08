# H3.4w privileged pseudo-key canonical action gate

## Outcome

Host typed key normalization 现在只接受无 modifiers 的 `LockScreen`/`CtrlAltDel` Down，防止 Up、Press 或歧义 modifier 组合触发系统级动作。

## Key evidence

- `is_function_key` 只根据 control-key enum 分支，不检查 `KeyEvent.down`/`press`；LockScreen 会启动锁屏线程，CtrlAltDel 会启动 SAS 线程。
- input worker 会把 `SemanticKeyAction::Press` 展开为 down 和 up 两次 adapter 调用；旧 contract 因而可能执行系统动作两次。
- pinned `event_lock_screen()` 与 Windows `event_ctrl_alt_del()` 都生成 Legacy、`down=true`、`press=false`、无 modifiers 的消息，提供了明确兼容基线。
- normalizer 现在要求 privileged pseudo-key action 为 Down 且 modifiers 为空；既有通用 down+press 歧义拒绝继续生效。
- 回归覆盖两个 pseudo-key 的 canonical Down，以及 Up、Press、modifier 四类边界；测试只检查 normalization，未触发真实锁屏/SAS。

## Verification

- Host key normalization targeted test：1 passed。
- 完整 Rust lib：122 passed，0 failed。
- release Rust core：成功生成 arm64 Mach-O dylib。
- built-core Host contract：3 passed；built-core ABI smoke：1 passed。
- 完整 Swift：109 tests，4 skipped，0 failures。
- release `RustDeskNative`：构建成功。
- canonical patch reverse-check、diff checks、bridge mirror comparison：通过。
- pinned HEAD clean replay：16 个 tracked 文件逐一一致，2 个 bridge mirror 一致。

## Boundary and next step

- 未修改 protobuf enum、Viewer/Host ABI、Hermes、CI、根依赖或数据库。
- 本步不自动执行真实 LockScreen/SAS，避免改变用户 GUI 会话；产品层是否向 FarPane Viewer 暴露这些动作仍需权限/UI 决策。
- 自动工作继续审计其他不依赖 shared contract 的 H3 semantic input 边界；Mini/MBP 仍按既定清单验收 drag、scroll 与 modifier reconnect。
