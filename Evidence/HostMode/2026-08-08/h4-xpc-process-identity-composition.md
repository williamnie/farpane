# H4.3c2 lease-bound XPC identity process composition

## Outcome

真实 `HostAgentProcess` startup composition 现在把 H4.1 single-writer lease、initial authoritative Host snapshot 与 H4.3c1 identity authority 串成同一生命周期：wire build/boot identity 直接来自 lease record，Host instance 在 initial snapshot 成功后绑定，termination 在其他 teardown 和 Core stop 前先使 identity 失效。该 composition 仍不创建或激活 listener。

## Key evidence

- 权威审计发现 `HostAgentBootstrapContext` 已在 acquire single-writer lease 前创建唯一 `UUID`，并把同一 `agentBootID`、configuration `agentBuildID` 写入 immutable lease record。H4.3c1 的独立 UUID generator 会造成 lease/XPC 双 boot identity；本步已删除并修正原 evidence/design update。
- `HostAgentProcessRuntime.start` 只在 `HostAgentBootstrapContext.prepare()` 成功后创建 XPC authority，build ID 直接取 `bootstrapContext.leaseRecord.agentBuildID`，boot ID 直接取同一 record UUID 并仅为 wire canonicalization 转为 lowercase；不读取 Bundle/env/peer，也不生成第二个 UUID。
- identity authority 在 Core runtime 前构造并与 `HostAgentProcessRuntime` 同寿命强持有；Core start 失败不会返回半初始化 runtime/identity owner。
- `snapshotCoordinator.bind` 同步完成 initial snapshot copy 后，`HostAgentProcess` 必须取得 snapshot authority 的 exact `hostInstanceID`，且 identity bind 必须首次返回 `bound`；随后才允许 media pipeline start 和 polling start。缺失/非法/重复异常状态均触发既有 startup termination 并返回 sanitized internal failure。
- `HostAgentProcessLifetime` 自动把 `runtime.invalidateXPCIdentity()` 放在调用方 `prepareTermination()` 之前；runtime `stop` 与 deinit 也再次幂等 invalidate，保证 media/polling teardown、Core stop 和 bootstrap lease release 前 handshake identity 已不可用。
- lifetime 只暴露受 running gate 保护的 bind/snapshot；termination claim 后访问稳定抛 `notRunning`，不会复活 identity。当前 ready identity 仍仅供后续 listener composition 使用。
- source-order tests 覆盖 bootstrap→identity→Core、initial snapshot→identity bind→media/poll、identity invalidation→other preparation→Core stop，并确认三份 product source 没有 listener/connection/accept/activate/resume/exported object。
- 本步没有启用尚禁用的 `HostAgentProcess.run` 入口，没有创建 XPC listener 或 service registration，不定义 snapshot/event/Host command wire，不修改 Host Control/Media ABI、Rust、Hermes、plist、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：updated authority tests 先因 product factory 尚会生成第二个 UUID 而编译失败；integration tests 同时要求尚不存在的 lease-record binding、initial snapshot order 与 termination invalidation order。
- 定向 identity：11 tests，0 failures；包含 7 个 dynamic authority tests 与 4 个真实 product composition/source-order tests。
- 完整 `swift test`：357 tests，4 skipped，0 failures。
- ScriptTests：22 tests，0 failures。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3c3 先把 snapshot copy failure/Host instance contradiction 与 identity invalidation 收敛，再让 H4.2k admission owner 在 ready identity 存在时为 identity-eligible connection 安装 H4.3b 的唯一 handshake interface/handler，设置 interruption/invalidation 清理并 resume。listener 本身只能在完整 process composition 的最后一步 activate；握手成功前不得访问 snapshot/event/Host command。
