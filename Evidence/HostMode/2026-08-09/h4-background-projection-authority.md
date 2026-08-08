# H4.3e4d App-owned background projection authority

## Outcome

新增持久 App-side background projection authority。它以 epoch-bound typed sink 消费 H4.3e4c session lifecycle，原子维护一个可观察的脱敏 component view，并为下一次 snapshot-first session 保留最后一次已验证 peer identity。

## Key evidence

- `beginSession()` 单调推进 session epoch、立即撤下旧 snapshot 并发布 waiting；返回 binding 同时携带 previous peer identity 与只属于该 epoch 的 `HostAgentXPCSessionProjectionSink`。新 session 开始后，旧 sink 的 snapshot/event/terminal callback 全部忽略，不能污染当前状态。
- initial snapshot 必须同时满足 response Host/boot 与 peer identity 一致，以及 previous peer → first/unchanged/replaced transition 精确对应；replaced 必须先收到唯一 identity-reset callback，否则投影进入 `failed/invalidProjection`。
- available projection 只保留严格 wire decoder 已验证的 snapshot payload、peer identity 与 snapshot event cursor；不保留 request ID、发送时间、原始 Data、XPC connection、transport error、密码或 Keychain 内容。
- event cursor 仍由 session/client 负责网络 correlation；authority 只复核 Host/boot、单调 cursor 与 payload class。command-result 或 Agent-only suppressed batch 只更新私有 cursor，不改变 view generation、不触发 500 ms idle 空 UI 更新。
- H4.3e4a 应转入 authoritative resnapshot 的 snapshot-changing/gap/invalid event 若错误地作为普通 event 到达，foreign identity、cursor rollback、错误 transition、非 resync trigger、较旧 snapshot observedAt 或 snapshot cursor 落后 trigger latest 都会清空 available view 并 fail closed。
- authoritative resync 在同一 observer delivery 序列中用完整新 payload 原子替换旧 projection；不会把 trigger event 部分应用到旧 snapshot。
- terminal reason 只保留 H4.3e4c 的稳定枚举并清空 projection；view 保守派生 handshake/snapshot/Rendezvous evidence：只有 available snapshot 可给 compatible+available，且 snapshot registration `ready` 才给 Rendezvous registered。
- authority 的 recursive delivery gate 保证 observer notification 有序且允许 observer 同步读取 snapshot；observer 永远在 state lock 外执行。
- 本步不读取或修改 SMAppService registration，不接 SwiftUI/App lifecycle/readiness 自动启动，不创建 XPC connection，不定义 Host command，不实现 reconnect timer，也不启用顶层 Agent entry。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 projection authority/view/session binding 类型不存在而编译失败；实现后转绿。
- background projection authority focused：10 tests，0 failures；覆盖 initial projection、private command cursor、unexpected state event fail-close、resync、same/replaced peer、missing reset、foreign identity、terminal health、stale epoch 与 source boundary。
- 完整 `swift test`：439 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过；本步新增/修改内容的 secret-shape scan 为 clean。

## Remaining boundary

下一步 H4.3e4e 建立 bounded App-side reconnect owner：强持有唯一 session lifecycle，terminal 后按明确 backoff 创建新 epoch/binding 并重新执行 snapshot-first 对账，显式 cancel 后不再重连。registration/Agent enablement 尚未完成前仍不接产品自动启动或宣称后台 Host ready。
