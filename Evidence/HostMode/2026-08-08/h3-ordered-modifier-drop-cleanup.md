# H3.4p Native Host ordered modifier Drop cleanup

- 日期：2026-08-08
- 范围：pinned RustDesk desktop `server/connection.rs` 与 canonical patch
- 结论：Native Host connection Drop 不再从连接线程执行 out-of-band modifier key-up

## Root cause

H3.3a 已建立 connection-scoped ordered cleanup：permission revoke 与 connection-loop teardown 先旋转 input epoch，再将 `MessageInput::Release` 排到同一 input queue；macOS consumer 又把 state snapshot 和真实 release 排到与 adapter 相同的 serial main queue。因此，所有先前已接受的 key/mouse task 都应在 cleanup 前有确定顺序。

但是 `Connection::drop` 仍遍历 `pressed_modifiers` 并直接调用 `rdev::simulate(KeyRelease)`。该调用来自 connection thread，不经过 input queue 或 macOS adapter queue，形成两个问题：

- ordered `Release` 已释放真实 pressed-key state 后，Drop 可能再次制造 modifier key-up；
- 若 adapter queue 仍有先前已接受的 key-down，Drop 的直接 key-up 可能先执行，之后 queued key-down 又把本机 modifier 留在按下状态。

## Implementation

- 新增内部 Native Host ordered-cleanup policy，并在 `Connection::drop` 使用 full-instance-lifetime `native_host_instance_is_live` authority。
- Native Host Drop 只清空 connection-side `pressed_modifiers` bookkeeping；真实 key/button release 统一由既有 ordered `MessageInput::Release` 执行。
- Host stop 会先 drain runtime，instance-live flag 直到 host destroy 才复位，所以 stop/drain 窗口仍走 ordered policy。
- non-Native desktop 保留 pinned upstream direct `rdev` cleanup compatibility。
- 未修改 wire semantics、protobuf、Host ABI/snapshot/event/command、Hermes、CI、根依赖、数据库或凭据。

## Verification

- Native/non-Native Drop cleanup policy test 已包含在完整 Rust lib run 中。
- `cargo test --features rdn-native-core,rdn-native-host --lib`：121 passed，0 failed；覆盖 input epoch/mapping/adapter、typed semantics、modifier admission/action、remote button release、session scope/lease、Accessibility、Aqua session、Host bridge/media 与其他 pinned lib 回归。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings、无编译错误。
- built-core Host lifecycle/ABI：3 passed；built-core loader ABI smoke：1 passed。
- `swift test`：109 tests，4 conditional skips，0 failures。
- `swift build -c release --product RustDeskNative`：success。
- `connection.rs` 通过 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- pinned HEAD 临时快照 clean apply 后，16 个 tracked patch 文件与 Vendor 逐一一致；两个 bridge source mirror 逐字一致。

## Remaining boundary

自动测试证明 Native Host 的 cleanup authority 不再被 Drop 线程绕过，并覆盖完整编译/ABI 链；它不能替代 Mini 上真实 modifier down、permission revoke、controller disconnect 和本地键状态的 CGEvent 验收。若 input worker 发生进程级 panic，当前策略仍以 fail-closed connection shutdown 为准，不在任意线程重建无序注入 fallback。

## Next step

继续审计是否还有可自动收敛的 H3.4 cleanup/semantic side-effect 边界；若剩余事项均需要 shared snapshot/UI、Secure Input 策略、布局/IME/快捷键或多显示器真机判断，则停止扩张并转向明确检查点。
