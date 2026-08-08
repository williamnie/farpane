# H4.3e3 snapshot-gated XPC event cursor session

## Outcome

既有 identity-admitted XPC connection 从 handshake-plus-snapshot 扩展为严格的 snapshot-gated event cursor session：同一连接只有成功取得 authoritative snapshot 后，才能从该响应的 exact `lastEventId` 查询 H4.3e2 typed event batch。产品 handler 直接使用 `HostAgentProcess` 持有的同一个 boot-lifetime event journal；顶层 Agent entry 仍保持 fail closed。

## Key evidence

- Clang protocol 保留现有 handshake → snapshot 继承链，并新增继承 snapshot service 的 `RDNHostAgentXPCEventService`；唯一新 selector `fetchEventsWithRequestData:reply:` 仍只接受 bounded `NSData` 并返回 nullable `NSData`，没有 collection、URL、NSError、proxy 或任意对象解档。
- 每连接 handler 现在显式区分 negotiation、snapshot fetch/ready 和 event fetch。event 在 compatible handshake 前、snapshot 成功前、snapshot 正在生成时及 event 正在生成时均返回 nil；成功 snapshot 只以 response 的 exact `lastEventID` 建立 cursor。
- event request 必须同时匹配 negotiated wire version、Host instance、agent boot identity 和 connection-local exact cursor。旧 cursor、未来 cursor、其他 connection 的 cursor 或 identity 不会触发 journal replay，也不会消耗注入的单调时钟。
- snapshot 与 event 各有独立的 100 ms connection-local monotonic rate limit。一次 selector 只能保留一个 in-flight reservation，避免并发 request 对同一 cursor 重复取批；document/replay/projection/encoding 失败会恢复原 cursor，但保留已发生的 rate-limit attempt。
- batch response 只将 session 推进到受 H4.3e2 约束的 `resumeAfterEventID`；up-to-date 保持原 cursor。gap、invalid-cursor、unknown/malformed public event 导致的 resnapshot-required 会撤回到 compatible，后续任何 event retry 都必须先重新取得 snapshot。
- snapshot refresh 可在 ready 状态主动执行；成功后以新 `lastEventID` 原子替换旧 cursor，失败则恢复旧 ready cursor。snapshot 与 event selector 的 reservation state 阻止两者并发交错提交。
- `HostAgentProcess.run` 将同一个 `HostAgentEventState` 沿 `HostAgentProcessStartup.prepare` → `HostAgentProcessRuntime.start` → listener admission shell 注入每连接 handler；event XPC 不创建第二 journal，也不读取文件、环境或外部进程状态。
- H4.3e2 projection 增加 journal record Host instance 与 lease/snapshot XPC identity 的 exact 对账；foreign journal Host 不会重新绑定 wire identity，而是返回 resnapshot-required。Agent-only media diagnostics 仍不出进程，但可按 contract 推进 resume cursor。
- 测试通过真实 anonymous `NSXPCListener`/`NSXPCConnection` 完成 handshake → snapshot → event 的跨 XPC round-trip，并覆盖 pre-snapshot rejection、exact cursor advance、stale cursor rejection、independent rate limit 和 eviction gap 后强制重新 snapshot。
- 本步没有新增 App-side event polling/subscription owner、callback proxy、UI/readiness 或 Host command selector；未修改 Host Control/Media ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：service/factory tests 首次因 event service protocol、selector、session state 和 process-owned journal 注入不存在而编译失败；gap/rate/round-trip tests 在接线前同样无法构造目标行为。
- related XPC focused：89 tests，0 failures，包含真实 anonymous XPC round-trip。
- 完整 `swift test`：410 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3e4 扩展 App-side session client：在首次 snapshot 发布后，以其 exact cursor 发起 bounded event fetch，并在 batch/up-to-date 时推进，在 gap/resnapshot-required 或 peer replacement 时回到 snapshot-first 对账。暂不接 UI/readiness、Host command 或顶层 Agent entry。
