# H3.3b connection-scoped input permission epoch

- 日期：2026-08-08
- 范围：Host Mode §10.2、§12.1；输入事件的 immutable permission snapshot 与 revoke cutover
- 网络：未连接或修改 Hermes
- 密钥：未读取、未输出、未写入
- ABI/schema：未修改 Host C ABI、HostSnapshot、event schema 或 wire protocol

## Outcome

pinned RustDesk 的每个 desktop connection 现在持有独立 `InputPermissionEpoch`。其单个 `AtomicU64` 同时编码 permission bit 与 generation：偶数为 disabled，奇数为 enabled。mouse injection、pointer/touch 与 key event 入队时各自捕获不可变 `InputPermissionSnapshot`；input worker 在调用 platform input service 前再次比较当前 epoch，只允许完全相等的 enabled snapshot。

keyboard permission 被本机撤销时，connection 先轮换到 disabled epoch，再发送远端 permission update，并排入 H3.3a 的 release marker。因此：

- 撤销前已经入队、但尚未被 worker 接受的旧 epoch 事件会被丢弃；
- 撤销后网络事件仍先被 `peer_keyboard_enabled()` 拒绝，内部 enqueue helper 也因拿不到 enabled snapshot 而 fail closed；
- 重新启用会产生新 epoch，旧 session snapshot 不会重新有效；
- connection teardown 同样先 disable/rotate，再排入 release marker；
- 重复设置相同状态不轮换 epoch，避免无意义地使同一 permission generation 失效；
- generation 接近 `u64` 饱和时拒绝重新启用，避免 wrap 后旧 snapshot 发生 ABA。

仅用于显示远端光标、`simulate=false` 的 mouse message 标记为 `NonInjecting`，不因 keyboard permission 关闭而消失；它不能进入输入注入分支。block-input 等独立 capability 也没有被错误并入 keyboard epoch。

## Root-cause evidence

H3.3a 前，Rust 只在网络 message handler 入队前检查 `authorized` 与 `peer_keyboard_enabled()`；input worker 对 dequeued message 不复核 permission。H3.3a 加入 ordered release 后，撤销前的 backlog 仍会在 marker 前执行。此处不是 stuck-state cleanup 缺失，而是授权判断与 platform adapter 接收之间缺少不可变 generation。

本步骤把安全切点固定在 input worker：revocation 的 atomic epoch rotation 与 worker 的 acquire load 构成明确 cutover。rotation 前已被 worker 接受的单个事件仍按顺序位于 release 前；rotation 后才被 worker 观察到的旧事件全部丢弃。

## Coverage

- `MouseEvent` 只有 `simulate=true` 时必须携带 current snapshot；cursor-only message 保持 non-injecting。
- `PointerDeviceEvent` 必须携带 current snapshot。
- `KeyEvent` 必须携带 current snapshot。
- file-transfer、terminal、view-camera scope 在 login response 后显式 disable connection input epoch。
- local keyboard permission switch 与 common connection teardown 都轮换 epoch。
- `MessageInput::Release` 与 block-input control messages不受 keyboard epoch 拦截，保证 cleanup 任何时候都能执行。

## Verification

Fresh verification：

- `cargo test --features rdn-native-core,rdn-native-host input_permission_epoch --lib`：2 项执行，0 failure（98 项 filtered out）；覆盖 queued message 从 valid 到 stale、disable/re-enable generation、same-state stability、cursor-only non-injecting 与 saturation fail closed。
- `cargo test --features rdn-native-core,rdn-native-host native_host_input_release_tests --lib`：2 项执行，0 failure（98 项 filtered out），证明上一阶段 release tracker 与新 worker gate 共同编译运行。
- `rustfmt --edition 2021 --check src/server/connection.rs src/server/input_service.rs`：通过。
- `Scripts/build-rust-core.sh`：release core 构建成功，arm64 dylib 已更新；pinned upstream 保留 130 个既有 warnings。
- 使用新 dylib 运行 `HostBridgeContractTests`：3 项执行，0 failure；独立 core loader smoke：1 项执行，0 failure。
- `swift test`：109 项执行，0 failure，4 项 built-core 条件测试按预期跳过（已在前两条命令显式带 dylib 执行）。
- `swift build -c release --product RustDeskNative`：production build 与链接通过。
- canonical patch reverse-check、clean pinned clone replay 后 13 个文件逐一比较、bridge mirror、repository/vendor diff whitespace checks：通过。

## Remaining boundary

H3.3 仍未完成：

- epoch 目前是 Rust connection-internal authority，还没有进入 native HostSnapshot/event/command，所以 App 重建后无法展示或主动撤销当前 session capability；
- native Host 尚未建立 single-active-control-session authority；process-global `KEYS_DOWN` cleanup 仍依赖该产品约束；
- platform adapter 尚未携带 permission epoch。worker 已接受、随后才发生 revoke 的单个事件会按 FIFO 位于 release 前，而不是在 CGEvent 执行点再次取消；最终 H3.4 semantic HostInputAdapter 仍需带 epoch 并在 adapter 边界复核；
- 未运行真实 CGEvent revoke/backlog 真机验收；需要 Mini 的 Accessibility/Input Monitoring 权限与安全测试步骤。

## Next step

H3.3c 应建立 native single-active-control-session authority，先在 Rust authorization lifecycle 对第二个 remote-control session fail closed，并用不含 peer metadata 的 aggregate state 为后续 HostSnapshot/session UI contract 提供唯一来源。共享 event/snapshot schema 仍留到明确的下一检查点，不在本步骤暗改。
