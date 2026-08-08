# H4.1s Agent-owned sanitized snapshot authority

## Outcome

HostAgent process composition 现在具备同一 Core owner 的 snapshot copy 通道和原子、脱敏 snapshot authority。启动后先完成 initial copy；每个 accepted Host event 都以 journal local sequence 触发 refresh，成功后才交给 downstream consumer。当前入口仍禁用。

## Key evidence

- `HostAgentSnapshotProjection` 复制 Host state/local ID/registration、pending approval、active session、password policy、last error 与 observedAt，但类型和构造源码都不访问 `snapshot.rawJSON` 或 `snapshot.revealedTemporaryPassword`；temporary-password presentation 永远固定为 `redacted`。
- state 以 lock 原子发布 `waiting|available|copyFailed|hostInstanceMismatch|staleSnapshot`、saturating refresh generation/failed count、关联 event sequence、pinned host instance 和 last accepted observedAt。
- copy failure、expected/pinned host-instance mismatch、较旧 observedAt 都清空当前 projection，避免未来 IPC 把 stale 数据冒充 ready；较旧 event sequence 被拒绝并保留较新的 available projection，防止迟到 refresh 反向覆盖。
- coordinator 在 runtime bind 前合并到最高 pending sequence；bind 后立即 initial/latched refresh。刷新中到达的新请求被合并并在当前 copy 后继续 drain，单一 copier 串行执行；第二 bind 被拒绝，不替换 authority。
- coordinator 不保留 underlying copy Error；失败只进入固定 `copyFailed`，下一 accepted event 可恢复。
- Swift `HostAgentCoreControlSurface` 增加现有 `HostControlClient.copySnapshot` 能力；Core runtime 与 owned runtime 在各自 owner lock 下只允许 running copy，stop 已认领后固定 `notRunning`，不建立旁路 client owner。
- lifetime gate 只在 `.running` 提供短期 runtime strong reference，runtime 自身再与 stop 串行；产品 copier `[weak lifetime]` 打破 `runtime event callback → coordinator → copier → lifetime → runtime` retain cycle。
- `HostAgentProcess` 强制接收 event state、snapshot state 和显式 downstream consumer；accepted event 的 sequence 先请求同步 snapshot refresh，再 forward。
- `RustDeskNativeApp.swift` 不创建 snapshot state、不调用 process runner，当前 `--host-agent` 继续由 `HostAgentBootstrap.failClosed()` 处理。

## Verification

- TDD RED：snapshot state/coordinator 不存在时 7 个 projection/refresh 测试编译失败；runtime/lifetime copy surface 不存在时 2 个 running-only 测试编译失败；产品 snapshot composition source contract 在接线前失败。
- 定向 snapshot state 8、Core/owned/lifetime copy 3、相关 process/event source contracts 4：15 tests，0 failures。
- `swift test`：232 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check：无 whitespace error。

## Remaining boundary

本步的 snapshot authority 会在 initial copy 和 accepted event 时刷新，但还没有 0.5 秒级的 bounded registration poll；Rust registration state 可能在没有事件时变化，因此不能据此宣称后台 component health 已持续更新。下一小步应增加由 process lifetime 明确 start/cancel 的单一 polling owner，防重入、在 stop 前取消，并把 poll copy failure 写入同一 snapshot state。之后仍需 Agent media owner、authenticated XPC 和真实子进程 signal smoke，才可切换入口。
