# H4.3c4 identity-authorized handshake connection lifecycle

## Outcome

H4.2k admission shell 现在具备真实但仍不可达的 handshake-only connection lifecycle：只有 fixed listener、H4.2j peer identity gate 与 process identity ready 三项同时成立，才会安装 H4.3b 唯一 interface/handler、设置 interruption/invalidation cleanup、记录活动连接并 resume。identity waiting/invalidated、owner cancelled、foreign listener 或不合格 peer 全部在配置前 fail closed。Mach-service listener 本身仍未 activate。

## Key evidence

- product shell 仍只从 `HostAgentXPCListenerFactory.makeListener()` 获得固定 Mach-service listener，沿用 listener-level signing requirement；foreign listener 在读取 connection metadata 前拒绝，owned listener 再执行 euid/audit-session/executable peer gate。
- `HostAgentXPCProcessIdentityAuthority.withReadyIdentityForAdmission` 在同一 authority lock 内提供 immutable build/Host/boot identity，并覆盖 interface construction、connection configuration、active registration 与 resume；waiting/invalidated 不执行 body，identity invalidation 不能穿过该临界区形成 stale-resume race。
- authority 只允许安装一个 process-lifetime invalidation observer；若已 invalidated，observer 在 authority lock 外同步补发。invalid/contradictory Host bind 与显式 termination 均至多通知一次，第二 observer 不能替换 owner。
- 每个 accepted connection 只安装 `HostAgentXPCHandshakeInterfaceFactory.makeInterface()` 和持有该次 immutable identity 的 `HostAgentXPCHandshakeHandler`；product configurator只设置 `exportedInterface`、`exportedObject`、`interruptionHandler`、`invalidationHandler`，随后只对该 connection 调用 `resume()`。没有 remote interface、snapshot、event 或 Host command surface。
- interruption 先从有界 active map 移除并主动 invalidate connection；随后到达的 invalidation 幂等忽略。authority invalidation 或 owner cancel terminally 拒绝新 admission，先原子清空 active map，再在锁外 invalidate 所有 connection。
- active map 固定最多 8 条 handshake-only connection，并在配置/resume 前原子预留容量；第 9 条直接 fail closed。它只以进程内 `ObjectIdentifier` 关联强持有的 connection，不保存/输出 PID、uid、audit session、path、签名、Host ID、boot ID、request payload 或底层 Error。snapshot 只含 attempt/peer reject/handshake unavailable/accepted/active/closed 的 saturating counts 与 cancelled bit；旧 `rejectedInterfaceUnavailableCount` 已更名为真实语义 `rejectedHandshakeUnavailableCount`。
- product clock 只生成当前 Unix milliseconds；越界时返回 0，由既有 H4.3b handler fail closed。测试 clock/connection actions 全注入，不激活 listener、不访问 Mach service。
- 本步没有接入 `HostAgentProcessRuntime`、启用 Agent entry 或 activate listener，也没有改变 Host Control/Media ABI、XPC wire schema、Objective-C selector、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：新测试先因 atomic ready-admission API、invalidation observer、handshake lifecycle initializer 与扩展 snapshot 不存在而编译失败。
- 定向 admission/identity：20 tests，0 failures；包含 5 个 handshake lifecycle tests、5 个 listener shell tests、10 个 process identity authority tests。
- 完整 `swift test`：368 tests，4 skipped，0 failures。
- ScriptTests：22 tests，0 failures。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3c5 才在真实 `HostAgentProcessRuntime` 中以同一 identity authority 构造并强持有 product admission owner，在 initial snapshot identity bind 成功后显式 activate 唯一 listener，并在 termination/identity invalidation 时先 cancel connections 再停止 Core。仍只能完成 handshake；snapshot-first envelope、event subscription 与 Host command 保持后续独立合同。
