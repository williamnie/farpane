# H3.3h1 Rust internal active-session authority

- 日期：2026-08-08
- 范围：pinned RustDesk connection lifecycle、canonical Native Host bridge 与补丁重放
- 结论：Native Host 已建立单一 Rust active-session authority，作为后续 shared snapshot/revoke/disconnect ABI 的内部前置步骤

## Problem boundary

H3.3c 已在 `AUTHED_CONNS` 中为 Remote connection 建立单活动 lease，但这个 lease 只解决并发准入，不能投影会话身份、当前 capability 或 Host-stop 清理。App rebuild 后也没有可恢复的 active-session 状态。若直接在 Swift 事件或 UI 中各自推断，会形成第二套会话真相，并可能在 connection cleanup 前提前释放产品会话。

本步只建立 Rust 内部 authority，不修改 Host ABI、HostSnapshot schema、protobuf、Hermes、CI、根依赖、数据库或凭据；也不向 Mini 部署未完成的 core。

## Implementation evidence

1. `NativeSessionBroker` 最多持有一个 `NativeActiveSession`。begin 仅接受 active capabilities 为 initial capabilities 子集的快照；完全相同的重复 begin 幂等，异构同 connection ID 返回 invalid，其他 connection 返回 busy。
2. canonical connection ID 由当前 Host instance ID 与 Rust core connection ID 组成，不采用远端提供的 ID。remote ID/name/platform 先做有界清洗，并在事件中固定标记 `remoteMetadataTrust=untrusted`。
3. initial capabilities 是授权时的 immutable baseline；active capabilities 由 connection 当前 keyboard/mouse、clipboard、system-audio effective permission 计算。`viewDisplay` 始终包含在固定 allowlist 中。
4. broker 登记发生在既有 `AuthedConnID` reservation 成功后、`authorized` 提交前；无 Host binding、broker busy 或 invalid 都中止授权，避免产生没有产品 owner 的已授权会话。
5. 本机 `SwitchPermission` 与远端 option 更新会同步 active capabilities；同值更新不发事件。生命周期事件为 `sessionStarted`、`sessionCapabilitiesChanged`、`sessionEnded`，并伴随无状态的 `snapshotChanged` 通知。
6. connection end 由 `AuthedConnID::drop` 调用，因此 session end 位于既有 ordered input cleanup-completion lease 之后。Host unbind/reset 会清空 broker并向残留 connection 的 IPC sender 发送 `Close`。
7. 事件 payload 不含密码、服务器、公钥、地址、输入内容、剪贴板内容、画面或原始错误；远端元数据只用于显示且不参与 authority。

## Verification

- `native_active_session_broker_is_single_and_capability_snapshot_safe`: 1 passed。
- `native_active_session_lifecycle_emits_sanitized_events_and_closes_on_reset`: 1 passed。
- 完整 Rust library tests（`rdn-native-host` feature）：129 passed, 0 failed。
- `Scripts/build-rust-core.sh`: release arm64 core 构建及导出符号门禁通过；只有 pinned/upstream warnings，无编译错误。
- 使用新构建 core 的 `swift test --quiet`: 130 passed, 0 skipped, 0 failed。
- `swift test --package-path ScriptTests --quiet`: 20 passed, 0 failed。
- `swift build -c release --arch arm64`: success。
- canonical/vendor `rdn_host_bridge.rs` mirror、rustfmt check、root/Vendor whitespace check 通过。
- 从锁定 RustDesk `6c578292e8ebbbec708b76986ba8c4bc7c509747` 与 hbb_common `7e1c392c62d39c364127307cd408421dd5f8cfb0` 分别 clean clone；应用两份 canonical patch、复制两份 canonical bridge 后，16 个 RustDesk patched files、2 个 hbb_common patched files 与 2 个 bridge files 逐一一致。

## Remaining boundary

- Host Control ABI 与 HostSnapshot 尚未暴露 active-session aggregate，App rebuild 后不能恢复会话显示。
- 尚无按 canonical connection ID 执行的 revoke keyboard/mouse、clipboard、audio 或 disconnect command。
- TCC 与 active Aqua session 的运行时变化不会主动同步到 active capabilities；这一点必须与 adapter fail-closed 和后续 snapshot UI 一起收敛。
- `passwordAndLocalApproval` AND mode 仍保持 fail closed，等待产品默认值/持久化决策。
- initial capabilities 是历史授权基线，后续 active capabilities 可经现有明确 permission 路径变化；shared contract 必须保留二者语义差异。
- 当前步骤不替代双 controller、撤权 backlog、App rebuild 与断线重连真机验收。

## Deployment state

Mini 当前安装的 `/Applications/FarPane.app` 为 build `20260808131034`，包含 last-window Host 生命周期修复，但继续使用此前已验证的 core。本步的新 active-session core 仅在仓库构建与测试中使用，未部署。

## Next step

在既有 Host ABI 修改授权范围内，新增 shared active-session snapshot 与精确 revoke/disconnect command；以同一个 Rust broker 为唯一数据源，并让 Swift rebuild 从 snapshot 恢复，不从事件重建第二套状态。
