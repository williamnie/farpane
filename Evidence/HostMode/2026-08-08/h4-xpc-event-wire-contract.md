# H4.3e2 strict typed event cursor/batch Data contract

## Outcome

新增独立、严格、bounded 的 App↔Agent event cursor/batch Data contract。它把 H4.3e1 的 replay 结果投影为可相关验证的 typed wire document，同时阻止 `HostCoreEvent.rawJSON`、Agent 媒体诊断及未知 payload 跨 XPC 边界。

## Key evidence

- `eventCursorRequest` exact envelope 固定 schema/wire/request/Host/boot identity、发送时间、canonical payload length，以及 `afterEventId`/`maximumEventCount`；document 上限 64 KiB、单批上限 64，未知键、bool/fraction integer、0/65 batch 与长度矛盾全部 fail closed。
- `eventCursorResponse` exact payload 固定 `outcome`、first-available、latest、resume-after、has-more 与 typed events；up-to-date、batch、gap、invalid-cursor、resnapshot-required 各自有互斥 shape，decode 后仍须与原 request identity/cursor correlation 才可接受。
- batch builder 只接受从 request cursor 下一条开始的连续 H4.3e1 records，数量不超过 request limit，且 `hasMore == (lastConsumed < latest)`；response 的 resume cursor 始终等于已消费 journal 末尾，即使其中部分 Agent-only event 未输出。
- 状态/审批/会话/错误类 event 只投影成空 payload `snapshotChanged`，连续信号在单批内合并到最后 local sequence，App 后续仍以 authoritative snapshot 收敛，不复制第二份业务状态。
- `commandResult` 唯一可携带 typed payload，只允许 bounded identifier-shaped command ID/detail 与固定 `ok/rejected/error/unknownCommand` status；top-level/payload unknown key、控制字符或不允许的 token 均转为 resnapshot-required。
- `mediaControl` 与五类 Agent-owned media diagnostic 被明确 suppress；测试中的 credential-like payload 未出现在 encoded document，但 resume cursor 仍跨过该 record，避免高频内部 telemetry 反压 App。
- 未知 future event、strict Core envelope 不一致或 malformed public payload 不被跳过/透传，而生成无 events、无 resume cursor 的 `resnapshotRequired`；测试确认原始 password/secret/peer metadata 不出现在 wire bytes。
- 本步是纯 Foundation Data contract，没有 `NSXPCConnection`、listener/interface、callback proxy、URL、文件/环境读取或外部状态；没有接 App client/UI/readiness，也没有 Host command request。
- 未修改 Host Control/Media ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 event contract/request/response/projection 类型不存在而编译失败；实现后的首次行为 run 精确暴露 snapshot signal 已合并到最后 sequence，测试按设计验证 coalesced cursor 后通过。
- event-wire focused：8 tests，0 failures。
- event-journal + event-wire related：19 tests，0 failures。
- 完整 `swift test`：406 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3e3 在既有 handshake-gated connection 上增加唯一 bounded event-cursor selector/session handler：只有 compatible handshake 且 snapshot 已成功取过后才能查询 event；使用同一个 process-owned `HostAgentEventState`，保留 rate limit、gap/resnapshot 与 connection teardown。仍不接 App client/UI 或 Host command。
