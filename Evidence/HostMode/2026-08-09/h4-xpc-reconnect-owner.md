# H4.3e4e bounded App-side XPC reconnect owner

## Outcome

新增 single-start App-side XPC reconnect owner，把 H4.3e4d projection session binding 与 H4.3e4c session lifecycle 组合为可长期恢复且可显式终止的 snapshot-first 会话所有权；product factory 仍为惰性构造，不会自行启动 XPC。

## Key evidence

- `start()` 只从 idle 成功一次，首次不延迟：先向 projection authority 申请新 epoch/binding，再把 binding 的 previous peer identity 与 typed sink 交给唯一 session factory，最后启动 session。owner 同时最多强持有一个 session。
- product session factory 精确调用 `HostAgentXPCSessionLifecycle.makeProduct`；每次恢复都创建新 lifecycle/client/XPC connection，并重新执行 handshake→authoritative snapshot→polling，不复用旧 transport 或 cursor。
- recoverable terminal 固定为 incompatible、invalid-response、disconnect、timeout；连续失败 delay 为 250、500、1000、2000、4000、5000 ms，之后保持 5000 ms。jitter 上限为 nominal 的 25%，最终 delay 再 clamp 到 5000 ms。
- 只有 typed initial snapshot 已先通过 projection sink 且 authority 仍为 available，owner 才进入 active 并把连续失败计数归零；普通 event/resync 导致 projection fail closed 时，owner 会取消 session 并停止重连。
- session factory throw、fresh lifecycle start=false、local invalid-state、unexpected cancellation 与 projection reject 都进入稳定脱敏 local failure，不对确定性 composition 错误无限重试。
- owner 对 delayed work 保留唯一 cancellable task；timer fire 后先清除 task 再建立下一 session。owner/session generation 同时拒绝旧 timer、旧 terminal、旧 projection callback 与 cancel 后的 factory completion。
- explicit cancel 先把 owner 标为 terminal 并旋转 generation，再取消 timer 与 session；session cancel 同步回调不能安排新 retry。测试另覆盖 cancel 与 blocking/throwing factory 并发，以及 jitter closure reentrant cancel，均不能被后续状态写回覆盖。
- product scheduler 使用专用 utility DispatchQueue 和 cancellable DispatchWorkItem；真实 delay execution/cancel smoke 通过。product factory 不调用 `start()`，构造后 owner/projection 都保持 idle。
- relay 对 owner 使用 weak reference，避免 owner→session→sink→owner retain cycle；scheduled action 同样 weak capture owner。
- 本步不读取或修改 SMAppService registration，不接 SwiftUI/App lifecycle/readiness 自动启动，不定义 Host command，不启用顶层 Agent entry。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 reconnect owner/session/scheduler/projection authority protocol 不存在且 binding initializer 不可访问而编译失败；实现后转绿。
- reconnect owner focused：13 tests，0 failures；覆盖 single-start、recoverable terminal、backoff reset/cap/jitter、active/scheduled/factory-race cancel、jitter reentry、local failure、projection reject、inert product factory、Dispatch scheduler smoke 与 source boundary。
- 完整 Swift 回归：452 tests，4 skipped，0 failures；`Test Suite 'All tests' passed`。
- 脚本回归：22 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/新增行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.3e4f 建立只读 background component health composition：组合 SMAppService registration observation 与 reconnect/projection 派生的 handshake/snapshot/Rendezvous evidence，形成单一可观察 readiness snapshot；仍需显式 activation policy，不能因为 registration enabled 或 owner connecting 就自动启动或显示 ready。
