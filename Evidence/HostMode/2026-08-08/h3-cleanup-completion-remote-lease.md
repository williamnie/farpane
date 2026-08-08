# H3.4q Native Host cleanup-completion Remote lease

- 日期：2026-08-08
- 范围：pinned RustDesk desktop `server/connection.rs`、`server/input_service.rs` 与 canonical patch
- 结论：Native Host 的 single-active Remote lease 直到旧会话 ordered input cleanup 实际完成后才释放

## Root cause

H3.3c 用 `AuthedConnID` 在 `AUTHED_CONNS` 内实现 Native Host 单 Remote lease。旧 connection loop 结束时会旋转 permission/mapping epoch并发送 ordered `MessageInput::Release`，但 lease guard 仍留在 `Connection` 字段中，随后随 connection drop 立即释放。

这与 macOS adapter 的真实时序不一致：input worker 收到 Release 后只调用 `QUEUE.exec_async`，实际 pressed-key/button drain 要等待同一 serial main queue 上更早的 adapter task。旧 lease 已释放、旧 cleanup 尚未执行的窗口内，新 Remote 可以取得 lease并注入新按键；旧 cleanup 随后会 drain process-global `KEYS_DOWN`，错误释放新会话状态。

## Implementation

- teardown 仅对 Native Host authenticated Remote 从 `Connection` 取出 `AuthedConnID`，将 guard 随 ordered `Release` marker 交给 input worker。
- `release_remote_input_state_then` 在 platform cleanup 后执行 completion：macOS completion 位于 serial queue cleanup closure 尾部，其他 desktop platform 位于同步 cleanup 之后。
- cleanup completion drop 旧 guard 后，`AUTHED_CONNS` 才释放 Remote slot；因此新 Remote 不会跨越旧 adapter/cleanup barrier。
- permission revoke 的 Release 不转移 lease；FileTransfer、PortForward、ViewCamera、Terminal 与 non-Native 生命周期保持原行为。
- Host instance live authority覆盖 stop/drain；未引入 main-thread 同步等待或 Host stop deadlock。
- 未修改 wire semantics、protobuf、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- Native Host cleanup lease policy test：1 passed，覆盖 Remote、四类 non-Remote、unauthenticated 与 non-Native 分支。
- `cargo test --features rdn-native-core,rdn-native-host --lib`：122 passed，0 failed；覆盖 input release/epoch/mapping/adapter、typed semantics、modifier admission/action/drop、single-session lease、session scope、Accessibility、Aqua session、Host bridge/media 与其他 pinned lib 回归。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures。
- `swift build -c release --product RustDeskNative`：success。
- touched Rust files 通过 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

本步用内部 ownership 把 Remote slot 生命周期绑定到 cleanup completion，并通过完整编译/测试链验证；自动测试不能模拟真实 macOS main dispatch queue backlog、CGEvent 状态与控制端快速重连。Mini 上应验证：按住 modifier 时断开，立刻重连并输入，旧 cleanup 不得释放新会话按键且旧会话不得留下 stuck key。

## Next step

继续审计 remaining cleanup state 是否都带 connection scope；若只剩 shared HostSnapshot/UI、Secure Input 策略、布局/IME/快捷键和多显示器真机边界，则停止自动扩张并进入检查点。
