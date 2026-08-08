# H3.4e typed key semantic normalization

- 日期：2026-08-08
- 范围：pinned RustDesk `connection.rs` / `input_service.rs` 与 canonical patch
- 结论：desktop Host 的 KeyEvent wire→typed semantic→platform adapter 边界已自动实现并验证；键盘布局、Secure Input、系统快捷键和真实 CGEvent 行为仍需真机验收

## Outcome

desktop Host 不再把任意 protobuf `KeyEvent` 直接排入 input queue。网络事件先转换为 `NormalizedKeyInput`，并同时形成明确的 semantic kind 与 action：

- kind：Legacy control/character/unicode/sequence、Map physical、Translate physical/sequence；Windows-only hotkey 仅在 Windows 构建保留；
- action：Down、Up、Press 或 Text；
- `KeyboardMode::Auto` 继续按 pinned consumer 的 Legacy 行为兼容，不改变旧 FarPane 的协商结果。

typed value 携带 connection permission epoch 穿过 input queue；Press 只在 worker 内展开为有序 down/up，两次 platform task 各自重新检查 adapter gate。macOS main queue 持有 `NormalizedKeyInput`，到最终 pinned Enigo/rdev 入口前才投影回 protobuf event。

## Key evidence

1. 缺失 union、未知 keyboard mode、未知/未来 union variant、unknown control key 均 fail closed。
2. mode/union 矩阵固定：Map 只接受 physical `chr`；Translate 只接受 physical `chr`、bounded sequence，以及 Windows 构建的 win2win hotkey；Legacy/Auto 只接受 control、有效 scalar character/unicode 与 bounded sequence。此前 Map+错误 union 可能经 `chr()` 默认值变成 keycode 0，现在不能到达 adapter。
3. stateful key 明确区分 Down/Up/Press；同时设置 down+press 的歧义事件拒绝。Unicode/sequence 规范成 Text，并清除不参与 consumer 语义的 flags，避免同一文本被误展开成两次注入。
4. Legacy character/unicode 必须是非 NUL Unicode scalar；surrogate、越界 scalar 与 NUL 拒绝。
5. sequence 必须是非空 UTF-8、不得含 NUL，且最多 4096 bytes；该上限与 FarPane Viewer `rdn_client_send_text` 的既有 `MAX_TEXT_BYTES` 一致，不修改 wire schema。
6. macOS Map/Translate physical position 限制为现有 C ABI 相同的 7-bit virtual hardware keycode `0...0x7f`；0 是合法的 `kVK_ANSI_A`，没有误拒绝。
7. modifier 只接受左右 Alt/Control/Shift/Meta、CapsLock、NumLock 以及 deprecated Alt aliases；unknown/重复 modifier fail closed，Alt/Option/Menu 同一 logical alias 不能重复。
8. Viewer C ABI 的 semantic character/special/physical key 与 bounded UTF-8 text producer 均继续生成可被 Host normalizer 接受的事件。
9. 没有修改 protobuf、C ABI、HostSnapshot、Hermes、CI、根依赖、数据库或凭据。

## Verification

在 pinned RustDesk 1.4.9 worktree，以项目 vcpkg root 和 `rdn-native-core,rdn-native-host` features 运行：

- `normalizes_wire_key_semantics_before_queueing`: 1 passed, 0 failed。
- Viewer `maps_basic_semantic_keys` 与 `validates_bounded_utf8_text_without_logging_content`: 2 passed, 0 failed。
- pointer/mouse semantic、Retina、mapping epoch、adapter gate、permission epoch、remote button cleanup、single-session lease：12 passed, 0 failed。
- 合计相关 Rust tests：15 passed, 0 failed。
- Rust lib test 报告 127 个 pinned/upstream warnings；release core 报告 131 个 warnings，没有编译错误。
- `Scripts/build-rust-core.sh`: release core 成功，arm64 Mach-O dylib 生成。
- built-core Host lifecycle/ABI: 3 passed, 0 failed。
- built-core loader ABI smoke: 1 passed, 0 failed。
- `swift test`: 109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`: success。
- canonical patch 与 13-file generated diff 一致；reverse-check 成功，clean pinned clone apply 后 13 个受控文件逐一一致，`connection.rs` / `input_service.rs` rustfmt check 成功。
- 根与 Vendor `git diff --check`: clean；无 staged changes。

## Remaining boundary

- typed normalization 证明 malformed/ambiguous event 不能到达 adapter，不证明具体键盘布局、dead key、IME、AltGr、Fn/media key或系统快捷键在真实 macOS 上符合预期。
- pinned macOS Enigo/rdev 最终仍依赖 Accessibility/Input Monitoring；Secure Input、TCC 被撤销、锁屏/LoginWindow 和 Fast User Switching 必须如实降级并真机验收。
- 当前 Press down/up 是两个按序 platform tasks，每个 task 执行前检查 permission epoch；已开始的单个同步 task不能中途取消，由同队列 cleanup 收敛。
- key pressed-state 仍位于 pinned process-global tracker；H3.3c single-active remote lease 限制并发 authority，但 HostSnapshot/revoke/App rebuild 的共享 schema 尚未建立。
- 4096-byte sequence 是当前 FarPane Viewer/Host 内部边界；若未来需要更大文本，应走独立 clipboard/transfer contract，不应无界扩大 key event。

## Next step

H3.4 的 mouse/pointer/key typed semantic 边界已经齐备。下一次先审计剩余 H3 退出条件与共享检查点，选择一个不需要猜测 schema 的 bounded step；若下一步必然要求 HostSnapshot/event/command ABI 决策，则只形成精确 contract evidence，不擅自修改共享 ABI。
