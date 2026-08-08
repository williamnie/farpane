# H3.4a macOS input-adapter epoch gate

- 日期：2026-08-08
- 范围：Host Mode §10.2、§12.1、§26.6；connection worker 到 macOS main dispatch queue 的最终授权窗口
- 网络：未连接或修改 Hermes
- 密钥：未读取、未输出、未写入
- ABI/schema：未修改 Host C ABI、HostSnapshot、event schema 或 wire protocol

## Outcome

authenticated remote input 现在经过两次同源 permission epoch 校验：

1. connection input worker 从队列取出 mouse、pointer/touch 或 key event 时复核 immutable snapshot；
2. macOS main dispatch queue 真正开始执行该 platform task 时，再用同一 snapshot 对 connection-scoped epoch 做 acquire-load 比较。

因此，已经离开 connection queue、但在 macOS platform task 执行前发生 revoke 的迟到事件会 fail closed。重新启用输入会生成新 epoch，旧 task 不能复活。仅用于远端光标显示的 `simulate=false` mouse event 仍标记为 `NonInjecting`，不会被错误当成 CGEvent 注入，也不因 keyboard permission 关闭而丢失。

## Root-cause evidence

H3.3b 只在 `Connection::handle_input` worker 调用 `handle_mouse` / `handle_pointer` / `handle_key` 前复核 epoch。macOS 的三个入口随后都会用 `Queue::main().exec_async` 再投递一次；worker check 与 `handle_*_`/Enigo/rdev 实际执行之间存在独立异步窗口。撤销发生在该窗口时，旧 task 原先仍能进入 CGEvent/Accessibility adapter。

cleanup 也有同源顺序问题：旧实现会在 connection worker 线程先读取 process-global `KEYS_DOWN` 和 connection-scoped mouse-button state，再把 release 操作投到 macOS main queue。如果先前已授权 task 尚未执行，cleanup 可能先看到空 state，之后旧 task 才按下按键或按钮。

本步骤新增 one-shot `InputAdapterGate`，由 connection 捕获 immutable authorization 与 `Arc<InputPermissionEpoch>`，在 macOS main queue closure 开始时执行。`release_remote_input_state` 在 macOS 上也改为把“读取 pressed-state、清空 relative mode、实际 release”作为一个 ordered main-queue task；它排在此前 adapter task 后、此后 connection input task 前，不再提前读取尚未落地的状态。

## Coverage and compatibility

- remote simulated mouse、pointer/touch、key down/up/press 都由 connection worker 构造 gated adapter task；press 生成的 down/up 各自复核 epoch。
- Windows/Linux 复用同一 gated API，但没有第二层异步 main-queue hop，因此在现有同步 platform 入口执行前复核。
- 既有非 remote 内部调用继续使用 ungated `handle_*` wrapper，例如本机 lock-screen helper；网络输入没有这些旁路，仍从 connection worker 进入 gated variant。
- cleanup 永远绕过 permission gate，以保证 revoke 后仍可释放已按下状态。
- native Host 的 process-global key ledger 由 H3.3c single-active-control-session 约束；非 native upstream 的既有多连接行为未被本步骤扩大或收窄。
- 未修改 Enigo/rdev、共享 Cargo dependency、Hermes、配置文件或根工程设置。

## Verification

Fresh verification：

- `cargo test --features rdn-native-core,rdn-native-host input_adapter_gate --lib`：1 项执行，0 failure（102 项 filtered out）；覆盖 current、revoked、re-enabled old/new generation 与 non-injecting gate。
- `cargo test --features rdn-native-core,rdn-native-host input_permission_epoch --lib`：2 项执行，0 failure（101 项 filtered out）。
- `cargo test --features rdn-native-core,rdn-native-host native_host_input_release_tests --lib`：2 项执行，0 failure（101 项 filtered out）。
- `cargo test --features rdn-native-core,rdn-native-host native_host_remote_slot --lib`：2 项执行，0 failure（101 项 filtered out）。
- `Scripts/build-rust-core.sh`：release core 构建成功，更新后的 dylib 为 arm64 Mach-O；pinned upstream 保留 130 个既有 warnings。
- 使用新 dylib 运行 `HostBridgeContractTests`：3 项执行，0 failure；独立 built-core loader smoke：1 项执行，0 failure。
- `swift test`：109 项执行，0 failure，4 项 built-core 条件测试按预期跳过（已在前两条命令显式带 dylib 执行）。
- `swift build -c release --product RustDeskNative`：production build 与链接通过。
- touched Rust format、repository/vendor diff whitespace、canonical patch reverse-check 通过；clean pinned clone replay 后 13 个 canonical 文件逐一一致。

## Remaining boundary

H3.4 尚未完成：

- 当前 platform boundary 仍直接消费 RustDesk protobuf mouse/key/pointer payload，没有独立、类型化且可单测的 FarPane `HostInputAdapter` semantic model。
- display switch/scale 尚未绑定 revisioned display mapping；connection ID 已进入 mouse/pointer state，但没有统一 semantic envelope。
- Secure Input、登录窗口、系统快捷键、键盘布局、Accessibility/Input Monitoring 降级与真实 CGEvent revoke/backlog 仍需 Mini 真机验收。
- gate 在一个 platform task 开始时复核；已经开始执行的单个同步 task不会被中途打断，而是由随后同队列 cleanup 收敛。这避免 task-level 迟到注入，但不宣称每个内部 CGEvent 都有独立原子取消点。
- HostSnapshot/event/command 仍没有 current permission、active session 与 revoke contract，App rebuild 恢复属于 H3.3/H3.2 的共享 schema 检查点。

## Next step

下一小步审计并固化 revisioned display/coordinate mapping：确认 RustDesk `MouseEvent` 坐标、当前 display、scale/reconfigure 与 connection/display epoch 的真实来源，再决定能否在不改共享 Host ABI 的前提下建立最小 semantic mapping contract。
