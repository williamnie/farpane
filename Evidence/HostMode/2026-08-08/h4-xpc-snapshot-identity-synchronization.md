# H4.3c3 snapshot/XPC identity safety synchronization

## Outcome

HostAgent 的后续 authoritative snapshot refresh 现在与 process-lifetime XPC identity fail-closed 联动：一次有效 snapshot 已绑定 Host instance 后，只要后续 Core snapshot copy 失败或出现 Host instance contradiction，就通过受 lifetime gate 保护的路径永久 invalidate XPC identity。stale event sequence/observedAt 仍按原 snapshot policy 降级或拒绝，不被误判为 identity contradiction。本步仍不创建、accept、resume 或 activate XPC connection/listener。

## Key evidence

- `HostAgentSnapshotIdentityInvalidationReason` 只有脱敏、固定的 `copyFailed` 与 `hostInstanceMismatch`；不携带底层 Error、Host ID、路径、配置、server 或 key。
- `HostAgentSnapshotRefreshCoordinator.bind` 现在必须显式提供 identity invalidation callback，没有 silent no-op product overload。coordinator 在 snapshot copier 抛错，或 publish 精确返回 `rejected(.hostInstanceMismatch)` 时发出信号。
- callback 以同一 condition lock 保证整个 coordinator lifetime 最多交付一次，并在锁外执行，避免重入 lifetime gate 造成锁反转；后续 snapshot 即使恢复 available 也不能复活已失效的 process identity。
- stale event sequence 不覆盖较新 authority；stale observedAt 继续清空 snapshot projection，但两者都不宣称 process Host identity 已矛盾，因此不触发 XPC identity terminal invalidation。
- 真实 `HostAgentProcess` 在绑定 snapshot copier 时以 weak lifetime 同时绑定 invalidation callback；callback 经 `HostAgentProcessLifetime.invalidateXPCIdentity()` 的 running gate 到达 runtime authority，不旁路 runtime owner。termination 已 claim 时 gate 拒绝回调访问，而 termination preparation 本身已先执行同一 identity invalidation。
- initial copy failure、startup 窗口中的 contradiction 或回调先于首次 identity bind 时，waiting authority 也会先永久失效；随后既有首次 bind guard 失败并走 sanitized startup termination。
- 本步没有改变 Host Control/Media ABI、XPC wire schema、Objective-C selector、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库；Agent entry 仍禁用，H4.2k 仍拒绝所有 connection，未安装、部署或 push。

## Verification

- TDD RED：新增测试先因 reason 类型和 required bind callback 不存在而编译失败。
- 定向 snapshot/identity：25 tests，0 failures；包含 13 个 snapshot state/coordinator tests、7 个 identity authority tests、5 个真实产品 composition/source-order tests。
- 完整 `swift test`：360 tests，4 skipped，0 failures。
- ScriptTests：22 tests，0 failures。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3c4 才改造 H4.2k admission owner：identity-eligible connection 只有在 ready process identity 存在时才能安装 H4.3b 唯一 handshake interface/handler，必须设置 interruption/invalidation 清理并只 resume 该 connection。listener 本身仍留到完整 process composition 的最后一步 activate；握手成功前不允许 snapshot/event/Host command。
