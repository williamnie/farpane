# H3 automatic completion audit

日期：2026-08-08

## Outcome

H3 尚未满足 `docs/host-mode-design.md` §21 H3 / §26.6 的交付与退出条件。内部输入安全链已有大量自动证据，但产品级认证、审批、会话 capability 状态和 App 重建恢复仍缺共享 Host Control contract 与实现；真实 macOS 输入行为也尚未全部验收。

## Authoritative requirements

H3 必须交付：

1. 永久密码安全存储和 Rust 权威的强度、失败限流、冷却；
2. 五种 approval mode、IncomingConnectionRequest、本机最终决定/超时/单 pending-active 约束；
3. 会话开始 immutable capability snapshot、会话中立即撤销并清理 stuck input；
4. Rust authorization → normalized semantic event → HostInputAdapter → CGEvent，未授权和迟到事件 fail closed；
5. 会话指示、主动断开，且连接状态和权限能在 App 重建后从权威 snapshot 恢复。

## Requirement-by-requirement evidence

| Requirement | Current evidence | Verdict |
|---|---|---|
| H3.1 verifier/storage authority | pinned core 使用协议 verifier、受保护 storage 和 challenge authentication；已有 authority audit | 部分已证明 |
| H3.1 failure limit/cooldown | burst/prefix gate 与 30 分钟 bounded cooldown 有 Rust tests | 已证明 |
| H3.1 secret ingress and wipe | generic JSON 已拒绝 secret；Host C ABI 没有 dedicated mutable-byte entrypoint，也没有 Swift/Rust 双端 wipe | 未实现 |
| H3.1 set/clear/status/UI | Rust command handler 不处理 permanent password；snapshot 无 `passwordPolicy`/更新时间；App 无设置 UI | 未实现 |
| H3.2 five-mode semantics | `HostApprovalPolicy` 与 4 项 tests 固化模式；source search 仅发现 tests 消费该类型 | 仅模型 |
| H3.2 native approval broker | Rust 无 pending request owner；Host events/snapshot/commands 无 incoming/approve/reject/expired | 未实现 |
| H3.2 once/expiry/busy/UI rebuild | 无 connectionId-scoped final-decision state、timeout authority、pending snapshot 或 App modal | 未实现 |
| H3.2 auth-failure abuse control | burst/prefix/cooldown 与 OS credential backoff 有 tests；未向 App 暴露 pending-risk projection | 核心已证明，产品投影缺失 |
| H3.3 immutable permission authority | connection-scoped effective permission epoch、queue/adapter recheck 有 Rust tests | 内部已证明 |
| H3.3 revoke and stuck-state cleanup | ordered key/button cleanup、modifier ownership、cleanup-completion lease 有 Rust tests | 内部已证明 |
| H3.3 capability policy/session projection | HostSnapshot 无 `capabilityPolicies`/`activeConnectionId`/`activeSession`；App 不持有权威 session state | 未实现 |
| H3.3 local revoke/disconnect | Host generic command handler 无 `disableInputForActiveSession`/`disconnectSession` | 未实现 |
| H3.4 authorization and semantic input | mouse/pointer/key typed normalization、platform capability、TCC/session/epoch gates 有完整 Rust/build evidence | 自动链已证明 |
| H3.4 real macOS input | Mini 上 drag、scroll、modifier reconnect、layout/dead key/IME、TCC/session transition、multi-display 尚无完整用户回报 | 真机证据缺失 |
| H3.4 Secure Input | authority 已定位，但 key-only limited / unchanged / all-control pause 尚未选择 | 需要共享决策 |
| H3 exit: App rebuild recovery | snapshot 只有 host/local ID、临时密码 presentation、registration、lastError；不含 connection/permission | 不满足 |

## Current contract evidence

- `CoreBridge/include/rustdesk_native.h` 的 Host Control surface 只有 config/create/start/stop/generic command/copy snapshot/free/destroy；没有 secret-buffer、approval 或 active-session dedicated entrypoint。
- `RdnHost::snapshot_json` 当前只有 `schemaVersion`、`hostInstanceId`、`hostState`、`localId`、`temporaryPasswordPresentation`、`registrationStatus`、`lastError`、`observedAt`。
- `handle_command` 当前只处理 `enableHost`、`disableHost`、`regenerateTemporaryPassword`、`revealTemporaryPassword`，其他命令只回 `unknownCommand`。
- `RustDeskNativeApp` 的 Host UI snapshot 只显示 enabled/running/streaming、状态、local ID、临时密码和错误；没有 pending/active session 或 capability controls。

## Next implementation boundary

不再继续拆分不改变产品完成度的 H3.4 semantic micro-gate。按设计顺序，下一代码工作应在用户明确允许共享 ABI/schema 变更后进行：

1. H3.1b：新增 dedicated mutable-byte permanent-password ABI、输入消费后双端 wipe、Rust strength authority、异步 command result 与 password-policy snapshot；
2. H3.2b：建立 connectionId-scoped native pending approval broker，并扩展 snapshot/event/approve/reject/expiry 与 App 入站 UI；
3. H3.3h：把 active session immutable capabilities、local revoke/disconnect 与 App rebuild recovery 接入同一 snapshot/event authority；
4. H3.4 manual：用 Mini/MBP 完成真实 drag、scroll、modifier cleanup、普通文本/布局/IME、TCC/session transition 和多显示器矩阵；Secure Input 先冻结产品策略。

这些变更不得通过 generic JSON secret、假 UI state 或 App-only session cache 绕过 Rust authority，也不需要修改 Hermes 服务端。

## Verification

- 对照读取设计 §8.1–§8.5、§9.3–§10.3、§12.1、§21 H3、§26.6。
- 搜索并读取当前 Host ABI header、Rust snapshot/command handler、Swift snapshot decoder/App consumer、approval policy consumers。
- 搜索现有 H3 evidence，区分自动 tests/build 与仍明确标注的真机边界。
- 本审计不修改共享 ABI、protobuf、Hermes、CI、根依赖或密钥。
