# H4.1t Process-owned bounded snapshot polling

## Outcome

HostAgent process composition 现在具备由进程生命周期持有的单一 500 ms registration snapshot poll。它在 runtime snapshot copier 绑定后启动，在唯一 Core stop attempt 前同步取消并 drain；当前 `--host-agent` 入口仍禁用。

## Key evidence

- `HostAgentSnapshotPollingOwner` 创建固定 utility queue `DispatchSourceTimer`，deadline/repeating 为 500 ms、leeway 为 50 ms；产品调用方不能注入 interval。
- `HostAgentSnapshotPollingGate` 只允许一次 start；同一时刻最多一个 tick，重入 callback 被拒绝。cancel 先转 terminal cancelled，再等待在途 tick 结束，之后 start/tick 永久失败。
- coordinator poll 复用当前最新 local event sequence/host instance，不把时间轮询伪装成 Host event；刷新期间多个 tick 仅以 `pollPending` 合并为一次追加 copy。
- coordinator `cancelAndWait()` 原子拒绝后续 bind/event/poll，清空 pending work，并以 condition 等待当前 copy/drain loop 完成；copy 返回时若已取消，不继续 pending event/poll。
- polling owner 的 cancel 对 active、尚未 activate 的 suspended timer 都安全；并发 cancel caller 等待同一个 cancelling owner，并依次 drain polling gate 与 snapshot coordinator。
- `HostAgentProcessLifetimeGate` 的首个 termination winner 在 condition lock 外执行一次 termination preparation，完成后才调用唯一 `stopRuntime`；重入 stop request 不死锁、不重复 preparation/stop。
- 产品 `HostAgentProcess` 在 snapshot bind 后才 start polling owner，并把 `pollingOwner.cancel` 注入 lifetime preparation；因此正常信号、bind failure、error teardown 都走相同 stop-before-Core ordering。
- `RustDeskNativeApp.swift` 仍不创建 event/snapshot state、不调用 process runner；timer owner 只经过 debug/release 编译与 source contract，没有在真实 Agent 进程中启动。

## Verification

- TDD RED：polling gate、poll/coalescing、termination preparation 与 product wiring 不存在时相关测试编译/契约失败；coordinator cancel-and-drain 缺失时停止竞态测试编译失败。
- 定向 polling gate 3、snapshot poll/cancel 3、lifetime preparation 1、产品 source contract 1：8 tests，0 failures。
- `swift test`：240 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check：无 whitespace error。

## Remaining boundary

本步只补齐 Agent 进程内 component snapshot 的无事件持续刷新与有序停止，尚未建立媒体 owner、authenticated XPC 或真正启用后台入口。下一小步应构建 Agent-owned media event/stream lifecycle，使媒体资源也由 process lifetime 明确 start、cancel、drain；真实子进程 signal/poll smoke 需等入口具备完整 event/media consumer 后执行。
