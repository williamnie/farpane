# H4.3c5 process-owned XPC listener activation

## Outcome

未来真实 `HostAgentProcessRuntime` 现在强持有由同一 process identity authority 构造的 product admission owner；Mach-service listener 只在 initial authoritative snapshot 已绑定 identity、media owner 与 snapshot polling 均成功启动后才显式 activate。任何 startup failure、snapshot identity failure 或 termination 都会先使 identity 失效，由唯一 observer terminally cancel listener/handshake connections，再继续其他 teardown 与 Core stop。顶层 `--host-agent` mode 仍保持 fail closed，因此本步不宣称后台服务已在真机启动。

## Key evidence

- runtime startup 固定顺序为 secure bootstrap/single-writer lease → lease-bound XPC identity authority → `HostAgentXPCListenerAdmissionShell.makeProductShell(identityAuthority:)` → owned Core runtime；owner 与 authority 一同由 runtime 强持有，没有第二 identity source 或 detached listener owner。
- product shell 构造只创建 fixed signing-gated listener、设置 delegate 与 identity invalidation observer，不 activate。`activate()` 再次进入 `withReadyIdentityForAdmission`；waiting/invalidated identity、cancelled owner 或重复 activation 都返回 false，不调用平台 listener。
- listener activation gate 以 condition state `inactive → activating → active → cancelled` 串行化。并发 cancel 等待在途 platform activation 返回，再 invalidate listener；不会先 invalidate 后又 activate。activation/invalidation action 均在 condition lock 外执行。
- `HostAgentProcess` 只有在 initial snapshot copy 成功、exact Host instance 首次 bind 返回 `bound`、media pipeline owner start 与 500 ms polling owner start 全部成功后，才经 running lifetime gate 调用 `activateXPCListener()`。任一 guard 失败走同一 sanitized startup termination。
- termination claim 后 lifetime 首先调用 runtime identity invalidation；authority observer 同步取消 active listener、清空并 invalidate 最多 8 条 handshake connection，随后才执行 media/polling preparation 和 `ownedRuntime.stop`。runtime stop/deinit 的重复 identity invalidation 继续幂等兜底。
- listener activation 不改变 H4.3c4 的 peer gate、atomic identity admission、唯一 handshake selector、bounded active map 或脱敏 counters；仍没有 snapshot/event/Host command remote interface。
- `RustDeskNativeApp` 继续不创建 Host Agent states、不调用 `HostAgentProcess.run`，`--host-agent` 仍由 `HostAgentBootstrap.failClosed()` 返回 unavailable；测试只注入 anonymous listener actions，没有注册或访问真实 Mach service。
- 本步没有修改 Host Control/Media ABI、XPC wire schema、Objective-C selector、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：新测试先因 listener activation state/API、runtime same-authority owner 与 lifetime activation path 不存在而编译失败。
- 定向 activation/composition：17 tests，0 failures；包含 7 个 handshake lifecycle、5 个 admission shell、5 个真实 process composition/source-order tests。
- 完整 `swift test`：370 tests，4 skipped，0 failures。
- ScriptTests：22 tests，0 failures。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3d1 冻结严格、有界的 snapshot-first wire envelope：只能从 `HostAgentSnapshotState` 的 sanitized projection 构造全量 snapshot，携带 agentBootId/Host instance/local event cursor，且 handshake compatible 前不可请求、snapshot 成功前不可订阅事件或发送 Host command。该合同完成前 App client 与顶层 Agent entry 继续禁用。
