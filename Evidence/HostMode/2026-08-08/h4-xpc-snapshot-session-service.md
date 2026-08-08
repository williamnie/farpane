# H4.3d2 handshake-gated snapshot XPC session

## Outcome

现有 identity-admitted XPC connection 从 handshake-only 扩展为严格的 handshake-plus-snapshot session：同一连接必须先完成一次 compatible negotiation，才可通过唯一 `NSData` selector 获取 H4.3d1 的全量脱敏快照。产品 listener/runtime 已注入 `HostAgentProcess` 自己持有并由 event/poll 更新的同一个 snapshot authority；顶层 Agent entry 仍保持 fail closed。

## Key evidence

- Clang protocol 保留原 `RDNHostAgentXPCHandshakeService`，新增继承它的 `RDNHostAgentXPCSnapshotService`，只增加 `fetchSnapshotWithRequestData:reply:`；输入输出仍只有 bounded `NSData`/nullable `NSData`，没有 collection、URL、NSError 或任意对象解档。
- 每连接 handler 状态固定为 `awaitingHandshake → negotiating → compatible(wireVersion)|incompatible`。合法 handshake 是 one-shot；malformed document 恢复 awaiting 以允许修正重试，明确 compatible/incompatible 后都拒绝 renegotiation，并发 32 次只有一次可产生 terminal response。
- snapshot handler 先解码 H4.3d1 request，再要求 compatible wire version、exact Host instance 与 agent boot identity；waiting/incompatible、错误 identity、无 `.available` projection、invalid document/clock/encoding 全部只返回 nil，不泄露底层 Error。
- snapshot request 以 connection-local 100 ms 最小间隔限频，限频权威使用 `DispatchTime` monotonic milliseconds；Unix wall clock 只写 wire `sentAt`，系统时间回拨不会污染防刷状态。
- admission shell 对每条 accepted connection 安装 derived interface 与独立 handler，仍受 fixed peer gate、ready process identity、最多 8 条活动连接及 interruption/invalidation teardown 保护；没有 remote interface fallback。
- `HostAgentProcess.run` 将其 `HostAgentSnapshotState` 沿 `HostAgentProcessStartup.prepare` → `HostAgentProcessRuntime.start` → `makeProductShell` 注入，因此 XPC 不创建第二 projection/state；listener activation 的 initial snapshot identity/media/polling 顺序未改变。
- 测试通过真实 anonymous `NSXPCListener`/`NSXPCConnection` 完成 handshake reply 后 snapshot reply 的跨 XPC round-trip，并验证 pre-handshake snapshot 被拒绝。
- 本步未定义 event/Host command selector、App-side product client、任意文件接口或类型解档；未修改 Host Control/Media ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：service tests 首次因 snapshot session interface/handler 不存在而编译失败；composition tests 随后因 listener/runtime 尚未接收同一 snapshot authority 而编译失败。
- snapshot service focused：9 tests，0 failures，包含真实 anonymous XPC round-trip。
- related XPC/composition focused：33 tests，0 failures。
- 完整 `swift test`：386 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3d3 实现独立 App-side XPC session client：固定 Mach service、先 handshake、只在 compatible response 对账成功后请求并接受 snapshot，agentBootId 变化时清空旧 intent；暂不接 event subscription、Host command 或 UI，也不启用顶层 Agent entry。
