# H4.1r bounded Agent-owned Host event state

## Outcome

HostAgent process composition 现在要求一个进程期内存 event state。Core callback 事件先进入有界 journal，只有 accepted event 才在锁外转给显式 downstream consumer；后台事件不再只能依赖未来调用方临时接收，也没有默认丢弃路径。

## Key evidence

- `HostAgentEventState` 是 package-scoped Swift 类型，不新增 C ABI、磁盘 schema 或 XPC wire；状态不落盘、不记录日志。
- product limits 固定 capacity 256、单 envelope 16 KiB，最大 raw envelope retention 约 4 MiB；测试注入也只能在 capacity 1...1,024、envelope 256 B...64 KiB 范围内，越界配置直接失败。
- 第一条 accepted event 固定 `hostInstanceId`；零 eventId、跨 instance、当前保留窗口内重复、超限 envelope 与 local sequence exhaustion 被拒绝并累计 saturating rejection count。
- local sequence 按 lock 内实际 arrival order 从 1 连续递增；不因 Rust callback 可能来自多线程而把数值更小但唯一的 eventId 误判为 stale。
- journal 满时只移除最旧 record，同时维护 bounded retained-ID set 和 saturating eviction count；snapshot 返回 `firstAvailableSequence`、`latestSequence`、完整当前 records 与计数，为未来 catch-up gap 判定提供明确证据。
- `consume` 先完成 ingest，再在锁外同步调用 downstream consumer；动态重入 snapshot 通过，duplicate 不会再次 forward。
- `HostAgentProcess` 现在要求调用方传入 `HostAgentEventState`，并以 `eventState.consume(event, onAccepted: onEvent)` 连接真实 Core callback；仍无默认 no-op consumer。
- `RustDeskNativeApp.swift` 不创建 state、不调用 process runner，当前 entry 继续 `HostAgentBootstrap.failClosed()`。

## Verification

- TDD RED：state 类型不存在时 6 个 ingest/concurrency 测试编译失败；产品 runner 尚未接 state 时 source contract 5 项失败；`consume` 尚不存在时锁外 forward 测试编译失败。
- 定向 state 8 tests + process source contracts 2 tests：10 tests，0 failures。
- `swift test`：220 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check：无 whitespace error。

## Remaining boundary

event journal 不是 authoritative Host snapshot，也不是 XPC 服务。下一小步应让 Agent owner 从同一 running Core 获取并原子发布 sanitized `HostCoreSnapshot`，用 event sequence 触发 refresh，并明确 snapshot copy failure/hostInstance mismatch 的 fail-closed 状态；在 snapshot-first authority、downstream media owner 和真实子进程 signal smoke 完成前，仍不得把 `--host-agent` 切到真实 runner或宣称后台 ready。
