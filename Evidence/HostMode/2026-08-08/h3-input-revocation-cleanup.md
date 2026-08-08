# H3.3a ordered input revocation cleanup

- 日期：2026-08-08
- 范围：Host Mode §10.2、§12.1；输入权限撤销与连接结束后的 stuck-input 防护
- 网络：未连接或修改 Hermes
- 密钥：未读取、未输出、未写入
- ABI/schema：未修改 Host C ABI、HostSnapshot、event schema 或 wire protocol

## Outcome

pinned RustDesk 输入线程新增 `MessageInput::Release(connectionId)`。keyboard permission 被本机撤销时，连接先将 `keyboard=false` 作为后续网络输入的即时 gate，再把 release marker 排在同一 connection input queue 中；连接 loop 结束时也排入同一 marker。这样，撤销前已接受的输入先完成，cleanup 随后执行，撤销后的输入不能再进入队列，不会出现并发 cleanup 后旧事件又把按键或按钮按下的重排窗口。

cleanup 会：

- 强制释放 `KEYS_DOWN` 中记录的远端按键；
- 清除该 connection 的 relative-mouse 状态；
- 按 connection 追踪成功注入的 left/right/middle/back/forward mouse-down，并只释放尚未收到 mouse-up 的按钮；
- 在 macOS 上继续使用既有串行 `QUEUE` 执行鼠标 release，使它与已排队的鼠标注入保持顺序；
- 重复 cleanup 安全：mouse button 状态 drain-once，第二次为空。

## Root-cause evidence

此前 incoming key/mouse 已通过 `authorized` 与 `peer_keyboard_enabled()` 在 Rust connection 层 fail closed；但 `ipc::Data::SwitchPermission { name: "keyboard", enabled: false }` 只更新布尔值并通知远端，没有释放已经按下的状态。`KEYS_DOWN` 的强制清理仅发生在 service reset/process exit 或超时路径，mouse button 没有 pressed-state authority。因此 permission revocation 不满足设计要求的“立即清空按键/鼠标按钮状态”。

## Ordering and safety boundary

- 已接受 input 与 release marker 使用相同的 `std::sync::mpsc` sender/worker；permission flag 在 enqueue marker 前已关闭。
- macOS worker 内的 mouse action 与 mouse release 都进入相同串行 platform queue。
- connection teardown 在 sender drop 前 enqueue marker，因此 worker 会先处理 cleanup，再观察 channel disconnect。
- 只记录 `mouse_down` 返回成功的按钮；未知 button mask 不注入也不记录。
- 不在日志、事件或 evidence 中记录 key、文字、远端 metadata 或任何认证材料。

## Verification

Fresh verification：

- `cargo test --features rdn-native-core,rdn-native-host native_host_input_release_tests --lib`：2 项执行，0 failure（96 项 filtered out）；覆盖 connection-scoped mouse tracker、drain-once 与 button mask fail closed。
- `rustfmt --edition 2021 --check src/server/connection.rs src/server/input_service.rs`：通过。
- `Scripts/build-rust-core.sh`：release Rust core 构建成功，输出 arm64 `Build/CoreBridge/arm64/liblibrustdesk.dylib`；现有 upstream build 产生 130 warnings。
- 使用该 dylib 运行 `HostBridgeContractTests`：3 项执行，0 failure；独立 built-core loader smoke：1 项执行，0 failure。
- `swift test`：109 项执行，0 failure，4 项 built-core 条件测试按预期跳过（它们已在上一步显式带 dylib 运行）。
- `swift build -c release --product RustDeskNative`：production build 与链接通过。
- canonical patch reverse-check、clean pinned clone patch replay 后 13 个文件逐一比较、bridge mirror comparison、Rust/仓库 diff whitespace checks：全部通过。

`cargo fmt --all -- --check` 仍受 pinned upstream 的既有全仓格式差异与缺失的 `src/ui/inline.rs` 阻塞；它没有指出本次两个 touched Rust 文件，二者已由定向 rustfmt check 验证。本步骤未改动这些 upstream 基线问题。

## Remaining boundary

H3.3 尚未完成：

- Rust `KEYS_DOWN` 仍是 process-global authority；当前 cleanup 依赖设计中的“同一时间只允许一个 active control session”。native single-session authority 尚未进入 Host snapshot/event contract。
- native Host 关闭 legacy Connection Manager 后，还没有 App/Host ABI 的本机 revoke command；本步骤关闭的是 Rust ordered cleanup primitive、既有 IPC revoke path与 connection teardown path，不冒充最终产品 UI 可撤销链。
- immutable session permission snapshot、permission epoch 与迟到事件拒绝仍待 H3.3b/H3.4。
- 未进行真实 CGEvent 按键/按钮注入验收；这需要辅助功能/输入监控权限和安全的真机会话，由用户醒来后执行。当前自动证据只证明 gate、queue、state tracker、核心构建与 ABI 生命周期。

## Next step

H3.3b 应先建立 native single-active-session 与 immutable permission snapshot authority，并定义 permission revision/epoch；随后把本机 revoke command 接到本步骤的 ordered release marker，保证 App 重建后的 snapshot、当前 permission 与 Rust authorization gate 一致。
