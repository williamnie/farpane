# H4.1o single-stop Agent lifetime gate

## Outcome

HostAgent 启动成功值现在是一个明确的 process-lifetime owner，而不是裸 runtime。它强持有完整 Core/bootstrap/lease 所有权，直到首个终止请求完成唯一一次 stop attempt；等待与重复请求不再各自操作 Core。

## Key evidence

- `HostAgentProcessLifetimeGate` 使用 `running → stopping → terminated` 三态和 `NSCondition`，运行态直接强持有 generic runtime。
- 首个 `requestTermination(reason:)` claim runtime 并同步 stop；后续请求在 stopping/terminated 都立即返回 false，因此 stop callback 重入也不会等待自身造成死锁。
- first reason wins：重复请求不能覆盖 reason；Core stop 至多执行一次。
- runtime 在 stop closure 返回前保持强引用；等待者只在 stop 成功或抛错后、terminal outcome 已发布时返回。
- stop Error 被丢弃，outcome 仅含原始 `HostStopReason` 与固定 `stopped|stopFailed`，不保留自由文本。
- gate 未显式终止即析构时，以 `appExit` 使用相同 single-stop 路径；已终止 gate 析构不重复 stop。
- deterministic concurrency test 在首个 stop 被 semaphore 阻塞时发出 duplicate，验证 duplicate 立即返回；释放 stop 后事件顺序为 `stopEntered → stopFinished → waitReturned`。
- `HostAgentProcessStartup.prepare` 成功时把 runtime 立即包装成 `HostAgentProcessLifetime`；wrapper 只把 stop 委托给现有 H4.1l owner。
- 产品 lifetime 源码明确没有 `signal()` 或 `DispatchSource.makeSignalSource`；App 入口仍不调用 startup prepare，exit 69 保持。

## Verification

- TDD RED：gate/outcome 类型不存在时 4 个生命周期测试先编译失败；产品 lifetime 文件和 startup wrapping 不存在时 source contract 先失败。
- 定向 lifetime gate：4 tests，0 failures；产品 lifetime/source contract：1 test，0 failures。
- `swift test`：199 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Remaining boundary

本步提供 blocking wait primitive，但尚未建立 async-signal-safe ingress。下一小步应在 executable 层用 `DispatchSourceSignal` 管理 SIGTERM/SIGINT 的 process-owned source（避免在 POSIX handler 内调用 Swift/锁），把首个信号映射为一次 `appExit` termination，并验证 source cancel/handler 生命周期；该层完成前仍不得启用入口或真正 wait。
