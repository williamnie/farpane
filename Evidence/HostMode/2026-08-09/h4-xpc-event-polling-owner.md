# H4.3e4b single-start App event polling owner

## Outcome

新增独立 App-side event polling owner，在 snapshot client ready 后串行驱动 H4.3e4a 的 bounded fetch：有 backlog 或刚完成 authoritative resnapshot 时按 Agent 允许的最短 cadence 追赶，追平后降到固定 idle cadence；取消、断线或 client terminal result 会清除 scheduled work 并阻止迟到回调复活。

## Key evidence

- owner 只依赖 package-scoped `HostAgentXPCEventPollingClient` 的 state snapshot 与 event fetch，不直接接触 `NSXPCConnection`、Mach service、wire encoder、文件、环境或 UI；真实 snapshot client 以现有严格 API conformance，没有第二 cursor/identity authority。
- `start()` 只接受 client `.ready`，同一个 owner 只能成功一次；初次 delay 为 0。状态固定为 idle/scheduled/fetching/failed/cancelled，scheduled 与 fetching 互斥，因此 timer callback、同步 reply 或并发 start 都不能创建第二个 in-flight fetch。
- correlated batch 只有 `hasMore=true` 才按 100 ms catch-up cadence 继续；已追平 batch 与 up-to-date 按 500 ms idle cadence。resynchronized snapshot 固定按 100 ms 重新追赶，使新 snapshot cursor 后的并发事件仍会收敛，同时不短于 H4.3e3 的 Agent event rate limit。
- owner 对不应由 e4a 输出的 gap/invalid-cursor/resnapshot-required `.events` fail closed；invalid response、disconnect、timeout、cancelled 与 invalid-state 都 terminal，并只向 terminal observer 交付一次。
- 每个 delay 返回 owner 强持有的 cancellable task；cancel-before-start 永久阻止启动，scheduled cancel 会取消 task，in-flight cancel 让 completion 因 generation/state mismatch 被忽略。`connectionDidEnd()` 同样取消 scheduled work并一次性报告 disconnected。
- product scheduler 使用固定 utility `DispatchQueue` 和 `DispatchWorkItem`；测试除 deterministic scheduler 外还真实等待 delayed work 执行，并验证 cancel 后 inverted expectation 不触发。
- typed result observer 只收到 H4.3e4a 已验证的 event batch 或 snapshot resynchronization；owner 不解释 command result、不复制 snapshot，也不存 Host/boot/cursor/payload/错误细节。
- 本步尚未在 App lifecycle 中创建/强持有 owner，也未把 result observer 接到 UI model、background readiness 或 reconnect owner；因此不宣称 FarPane GUI 已自动订阅后台 Agent。未定义 Host command，也不启用顶层 Agent entry。
- 未修改 Host Control/Media ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 polling client/task protocols、owner/state/scheduler 不存在而编译失败；实现后转绿。
- event polling owner focused：6 tests，0 failures，包含 product scheduler delay/cancel smoke。
- 完整 `swift test`：421 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3e4c 建立 App-side session lifecycle composition：从 bundle identity 创建 client，首次 snapshot 发布成功后创建并强持有唯一 polling owner，把 event/resynchronized snapshot 交给一个 typed projection sink；connection end/取消按顺序停止 owner 与 client。仍暂不接 Host command，且在明确 readiness authority 前不把 background Host 标为 ready。
