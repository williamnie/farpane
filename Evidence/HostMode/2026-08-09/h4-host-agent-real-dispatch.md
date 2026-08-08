# H4.1af real pre-AppKit HostAgent dispatch

## Outcome

真实 `--host-agent` 角色分支已从固定 unavailable 占位切换为完整 product bootstrap；任何 AppKit application/delegate 初始化前完成资格判断，并以 structured terminal code 退出。

## Key evidence

- `AppDelegate.main` 仍先用纯 `RustDeskNativeProcessModePolicy` 分流；HostAgent 分支唯一执行 `exit(HostAgentProcessBootstrap.run())`。
- bootstrap 调用的 source position 严格早于 `NSApplication.shared` 和 `AppDelegate()`；Agent rejection/startup/runtime 不会创建窗口、Dock 菜单或 App delegate。
- 旧 `HostAgentBootstrap.failClosed()` 与 `HostAgentProcessTerminalReporter.report(.unavailable)` 已从真实 App source 移除，不再以固定 69 掩盖 entry/preflight/startup failure。
- direct debug binary 的 argv0 是 build path，不满足固定 LaunchAgent invocation，稳定返回 EX_USAGE 64 与一行 invalid-invocation 诊断。
- 通过 `/bin/bash exec -a RustDeskNative` 构造 exact argv shape 后，debug binary 进入固定 signed-asset gate；当前 bundle 未含 LaunchAgent plist，稳定返回 EX_CONFIG 78 与一行 invalid-launch-configuration 诊断。
- 既有 orchestrator 动态测试证明任一 rejection 都不调用 product runner；因此上述 smoke 不创建 boot state、不读取 bootstrap projection/lease、不加载 Core、不联网。
- local-development eligibility 现在可进入完整 process runtime，但本步没有创建/安装 plist、调用 ServiceManagement、安装 App、启动 eligible Agent 或修改真实配置；Developer ID 仍须 H4.5 notarization evidence。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService registration、plist、CI、根依赖、根配置或数据库，未读取真实配置/密钥，未安装、部署或 push。

## Verification

- TDD RED：真实 dispatch focused test 首次因 App source 缺少 `exit(HostAgentProcessBootstrap.run())` 而失败；切换入口后转绿。
- real dispatch focused：2 tests，0 failures、0 warnings；覆盖 role→bootstrap→AppKit source order、旧 unavailable 移除与 bootstrap 无 AppKit/exit ownership。
- process composition contract：34 tests，1 skipped、0 failures、0 warnings；原“入口禁用”断言已改为验证真实 product bootstrap，同时保留 App source 不直接构造 runtime/state/media/signal 的边界。
- entry preflight focused：8 tests，0 failures、0 warnings；覆盖 exact invocation、固定 identity gate、Developer ID notarization gate 与只经 product bootstrap dispatch。
- lease-bound XPC identity focused：5 tests，0 failures、0 warnings。
- debug + arm64 Release executable rejection smoke：direct invocation 均返回 64/invalid invocation；exact-shaped argv 均返回 78/invalid launch configuration；各自仅一行固定诊断。
- 完整 Swift 回归：502 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：22 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/新增行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

H4.1 自动代码路径已闭合，但 eligible Agent startup、SIGTERM teardown、App/Agent reconnect 仍需要打包注册后在 Mini 真机验收。下一自动步骤转到 H4.2：先冻结 LaunchAgent lifecycle/restart keys 并创建可由 build script 校验但尚不注册的签名 bundle asset。
