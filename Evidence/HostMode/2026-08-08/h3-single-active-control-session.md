# H3.3c native single active remote-control session

- 日期：2026-08-08
- 范围：Host Mode §10.3、§12.1；native Host authorization lifecycle 的单 active control lease
- 网络：未连接或修改 Hermes
- 密钥：未读取、未输出、未写入
- ABI/schema：未修改 Host C ABI、HostSnapshot、event schema 或 wire protocol

## Outcome

pinned RustDesk 的 native Host 生命周期现在最多允许一个已授权 `ConnType::Remote`。连接在提交 `authorized = true` 前，必须在 `AUTHED_CONNS` 的同一把锁内完成检查和 reservation；若已有 remote control lease，第二个连接收到不含 peer metadata 的 `Another remote control session is active` 并立即结束。

lease 复用既有 `AuthedConnID` RAII 生命周期。连接关闭时先执行 H3.3a/H3.3b 的 input disable、epoch rotation 与 ordered release，随后 `AuthedConnID::drop` 从 `AUTHED_CONNS` 移除连接；只有旧连接完成这段清理后，新 remote 才能取得 lease。这样不会在旧连接仍可能注入输入时提前允许重连。

## Root-cause evidence

此前 login success 会先设置 `self.authorized = true`，随后才把连接放入 `AUTHED_CONNS`，而 upstream 本身允许多个 `ConnType::Remote`。若只在 authorization 前读取一次 active count，两个并发登录可以同时看见空集合并双双通过。

本步骤将 availability check 与 candidate push 合并在一次 `AUTHED_CONNS` lock critical section 内，授权标志只在 reservation 成功后提交。并发测试使用 8 个同时竞争者，结果严格只有一个 winner。

native Host 的策略作用域使用 `HOST_INSTANCE_LIVE`，而不是 media binding。`rdn_host_stop` 会在 server connection drain 前先解除 media binding；若用 `native_host_is_bound()`，stop-drain 窗口会错误退回 upstream 多会话策略。instance-live 标志覆盖完整 native Host 生命周期，直到 runtime 已停止并准备销毁 Host instance。

## Compatibility boundary

- busy gate 仅在 native Host instance 存活时启用；非 native upstream 行为保持不变。
- 仅 `ConnType::Remote` 占用并竞争 control lease；file transfer、port forward、view camera 与 terminal 不被误拒绝。
- busy error 不携带远端 ID、设备名、IP 或其他 peer metadata。
- 未新增共享 ABI/schema、配置项、Hermes 请求或根依赖。

## Verification

Fresh verification：

- `cargo test --features rdn-native-core,rdn-native-host native_host_remote_slot --lib`：2 项执行，0 failure（100 项 filtered out）；覆盖 mode/scope matrix、8 个并发竞争者单 winner 及 release 后重新可用。
- 首次编译准确暴露了测试代码对 `JoinHandle` 的借用后 consume 错误；改为先 `join` 再统计后通过，production implementation 未因此改变。
- `cargo test --features rdn-native-core,rdn-native-host input_permission_epoch --lib`：2 项执行，0 failure（100 项 filtered out）。
- `cargo test --features rdn-native-core,rdn-native-host native_host_input_release_tests --lib`：2 项执行，0 failure（100 项 filtered out）。
- `Scripts/build-rust-core.sh`：release core 构建成功，更新后的 dylib 为 arm64 Mach-O；pinned upstream 保留 130 个既有 warnings。
- 使用新 dylib 运行 `HostBridgeContractTests`：3 项执行，0 failure；独立 built-core loader smoke：1 项执行，0 failure。
- `swift test`：109 项执行，0 failure，4 项 built-core 条件测试按预期跳过（已在前两条命令显式带 dylib 执行）。
- `swift build -c release --product RustDeskNative`：production build 与链接通过。
- canonical patch reverse-check、clean pinned clone replay 后 13 个文件逐一比较、bridge mirror、repository/vendor diff whitespace 与 touched Rust format checks：通过。

## Remaining boundary

H3.3 仍未完成：

- authority 目前只存在 Rust connection lifecycle；HostSnapshot/event 尚不能展示 aggregate active-session state，App 也没有 terminate/revoke command 或 rebuild recovery。
- H3.2b 的 native pending approval broker 尚未实现，所以 single-pending request 仍不是本步骤的覆盖范围。
- H3.4 仍需把 semantic input adapter 与 permission epoch 带到最终 CGEvent 边界。
- 需要在 Mini 上用两个 FarPane controller 真机验收：第一台已连接时第二台明确 busy，第一台断开并完成清理后第二台可连接，且没有 stuck key/button。

## Next step

下一小步先审计 H3.4 从 Rust semantic input 到 macOS `CGEvent` 的真实 adapter authority，明确哪些事件仍绕过 epoch 或依赖 process-global state；共享 HostSnapshot/event/command schema 留在独立检查点，不在本步骤暗改。
