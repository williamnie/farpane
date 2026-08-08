# H4.3e1 Agent event journal catch-up authority

## Outcome

现有 Agent boot-lifetime event journal 新增原子、有界的 cursor replay authority，使未来 App 能从 snapshot 的 `lastEventID` 判断连续追赶、分页继续、已经追平、窗口缺口或非法未来 cursor。该步只建立进程内权威查询，不把 raw Host event payload 暴露给 XPC。

## Key evidence

- `replay(afterSequence:limit:)` 与 ingest/eviction 共用 `HostAgentEventState` 的同一把锁；返回 records、latest sequence 与 `hasMore` 来自同一原子 journal 视图，不会拼接不同时间点的 cursor 状态。
- product batch 默认 64 条，调用上限固定 256；0、257 及更大 limit 抛出 typed `invalidLimit`，不会绕过 journal 自身的 256 条产品容量边界。
- 空 journal 或 cursor 等于 latest 返回 `upToDate`；cursor 小于 latest 时只返回严格大于 cursor、按 local arrival sequence 连续排列的 prefix，并以 batch 最后一条与同一视图 latest 比较 `hasMore`。
- 如果 `afterSequence + 1 == firstAvailableSequence`，说明调用方已经拥有窗口前的全部事件，允许从 first available 连续 replay；如果下一条更早，则返回包含 first/latest 的明确 `gap`，未来 owner 必须丢弃 incremental state 并重新获取 authoritative snapshot。
- cursor 大于 journal latest 返回 `invalidCursor`，不会把另一个 Agent boot、旧身份或损坏持久化状态的未来 cursor 当作已追平。
- replay 返回的 `HostAgentEventRecord` 仍是 package-scoped 进程内值；本步没有定义 XPC selector/Data schema、没有编码 `HostCoreEvent.rawJSON`、没有 event callback/proxy，也未接 App client/UI/readiness。
- 未修改 Host Control/Media ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 `HostAgentEventReplayResult`、`HostAgentEventReplayError` 与 `replay` 尚不存在而编译失败。
- event-state focused：11 tests，0 failures。
- 完整 `swift test`：398 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3e2 定义独立、严格、bounded 的 event cursor/batch Data contract：只投影 App 所需的脱敏 typed event，不透传 raw Core envelope；明确 up-to-date/batch/gap/invalid-cursor wire 结果，并继续不接 selector、client、UI 或 Host command。
