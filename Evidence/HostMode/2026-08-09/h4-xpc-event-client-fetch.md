# H4.3e4a App-side bounded event fetch and authoritative resnapshot

## Outcome

App-side snapshot-first session client 现在能在同一 authenticated XPC connection 上执行一次 bounded event cursor fetch：普通结果精确推进 connection-local cursor，状态失效信号和 replay 不连续则先自动重取 authoritative snapshot，再恢复 ready。该边界不建立持续 timer/polling owner，也不接 UI/readiness。

## Key evidence

- `HostAgentXPCSnapshotClientTransport` 与生产 connection transport 新增 `fetchEvents`，remote proxy 升级为 H4.3e3 的 derived `RDNHostAgentXPCEventService`；handshake、snapshot 与 event 仍共用固定 Mach service、同一个 `NSXPCConnection` 和 Data-only interface，没有 callback proxy、URL、NSError 或任意对象解档。
- client 只允许从 `.ready(peer,lastEventID)` 发起 event request，使用握手保存的 exact wire version、同一 Host/boot identity、当前 cursor、固定 product batch 上限 64、新 canonical request ID 与 timestamp。并发第二次 fetch、pre-ready/terminal 状态不会调用 transport。
- response 必须通过 H4.3e2 strict decode 与 request correlation；up-to-date 保持 cursor，普通 batch 只采用受 contract 验证的 `resumeAfterEventID`。malformed、nil、错误 request/identity/cursor 或矛盾 shape 会 terminal fail closed 并 invalidate connection。
- 包含 `snapshotChanged` 的 batch 不作为最终状态直接返回；gap、invalid-cursor 和 resnapshot-required 同样自动进入 `.refreshingSnapshot`，生成新 correlated snapshot request。成功 refresh 只采用 response 的 authoritative `lastEventID` 恢复 ready，并以 `resynchronized(snapshot,triggeringResponse)` 同时交付原因和新快照。
- event fetch 与其 resnapshot 各自沿用 5 秒 bounded timeout；cancel、interruption/invalidation、timeout 和 late reply 均最多完成一次。ready 后 event in-flight 断线还会触发既有 connection-ended hook，供未来 lifecycle owner 重建完整 snapshot-first connection。
- 测试 transport 覆盖 exact cursor/64 limit、duplicate fetch、batch advance、gap resnapshot、snapshotChanged resnapshot、invalid response、timeout/cancel 与 late reply；真实 anonymous `NSXPCListener`/`NSXPCConnection` 覆盖 App client snapshot ready 后的 typed event batch round-trip。
- 本步没有实现持续 catch-up/idle polling cadence、automatic has-more drain、App lifecycle owner、UI/readiness 或 Host command；调用方若立即重复 fetch 仍需遵守 Agent 100 ms event limit，下一步由唯一 polling owner 固定该 cadence。
- 未修改 Host Control/Media ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 event result/state、client API 与 transport method 不存在而编译失败；随后实现后转绿。
- snapshot/event client focused：14 tests，0 failures，包含真实 anonymous XPC event round-trip。
- 完整 `swift test`：415 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3e4b 建立唯一 App-side event polling owner：只在 session ready 时按不短于 100 ms 的 cadence 串行 fetch，`hasMore` 继续 bounded catch-up，up-to-date 进入低频 idle poll，resynchronized 后从新 snapshot cursor 继续；cancel/disconnect 必须终止所有 scheduled work。仍暂不接 UI/readiness 或 Host command。
