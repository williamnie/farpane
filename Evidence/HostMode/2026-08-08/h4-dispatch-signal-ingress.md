# H4.1p latched DispatchSource signal ingress

## Outcome

HostAgent 现在有一个尚未接入入口的安全 termination ingress：固定 SIGTERM/SIGINT 由 DispatchSource 接收，并通过一次性 latch 跨越“signal controller 已安装、runtime 尚未启动/绑定”的窗口。POSIX handler 不执行 Swift、锁或 Core stop。

## Key evidence

- `HostAgentTerminationRequestLatch` 支持 request-before-bind 与 bind-before-request，两条顺序都只交付一次。
- first request 和 first bind 分别拥有唯一权威；duplicates 返回 false，不替换 handler、不重复交付。
- delivery 在释放 `NSLock` 后同步执行，handler 内重入 request 返回 false 且不死锁。
- 交付后 latch 清空 handler；带对象 capture 的测试确认 delivery 执行一次，随后 capture 可释放。
- `HostAgentProcessSignalController` 只安装 SIGTERM/SIGINT；先保存原 `sigaction`，再将 handler 设为 `SIG_IGN`，之后创建并 activate `DispatchSourceSignal`。
- Dispatch event handler 只调用 latch；源码不存在 `Darwin.signal` 或 `__sa_sigaction` custom POSIX callback。
- controller bind 将已锁存或未来信号映射为 `lifetime.requestTermination(reason: .appExit)`，由 H4.1o 保证 single stop。
- cancel/deinit 幂等：先移除 handler、cancel 两个已激活 source，再按安装逆序恢复原 dispositions。
- 首次 signal 不取消 controller/恢复默认 handler；因此 Core stop 窗口内的第二信号仍由 ignore + DispatchSource 吸收，并被 latch 判为 duplicate。
- `RustDeskNativeApp.swift` 尚未构造 controller，当前没有真实信号或网络副作用，exit 69 保持。

## Verification

- TDD RED：latch 类型不存在时 4 个顺序/重入/释放测试先编译失败；signal controller 文件不存在时 source contract 先失败。
- 定向 latch：4 tests、0 failures；定向 source contract：1 test、0 failures。
- `swift test`：204 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check：无 whitespace error。

## Remaining boundary

本步没有发送真实 SIGTERM/SIGINT：controller 尚未被入口实例化，若单独 smoke 只会测试当前 exit-69 stub。下一小步应组合完整但仍可禁用的 process runner：先安装 controller，再 prepare runtime，bind lifetime，wait terminal outcome，cancel/restore signals，并把 startup/stop outcome 映射为固定 diagnostic/exit；随后才能用子进程真实 signal smoke 支撑入口切换。
