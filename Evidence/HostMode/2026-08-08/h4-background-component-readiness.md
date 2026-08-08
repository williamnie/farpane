# H4.2a Background component readiness policy

## Outcome

App 侧现在有一个 package-scoped、无 I/O 的后台 Host 组件 readiness policy。它把 ServiceManagement registration、authenticated handshake、权威 snapshot 和 Rendezvous registration 保持为四份独立证据；只有同一 observation 中四者全部健康才返回 `ready`，因此 launchd 注册成功、审批已发起或进程可达都不能单独冒充可连接状态。

## Key evidence

- registration 明确区分 `notRegistered`、`requiresApproval`、`enabled` 和 `serviceUnavailable`；前三类非 enabled 结果优先于任何伪造的下游健康信号。
- enabled 之后仍须按序满足 handshake `compatible`、snapshot `available`、Rendezvous `registered`；disconnected、version incompatible、snapshot 缺失、checking/offline 都返回稳定的非 ready availability。
- `requiresApproval` 是独立状态，可由后续 UI 引导 System Settings；不会把“已调用 register”或“等待用户审批”展示为 running/ready。
- `HostAgentBackgroundComponentHealth` 保留四个 typed component 状态和计算结果，不接受 PID、plist 存在性、路径、server/key、credential、raw snapshot 或自由文本。
- 所有类型均为 package scope；本步没有冻结 App↔Agent XPC message/schema，没有新增 selector、payload、command 或 ABI。
- 本步不 import/use `ServiceManagement`，不创建 LaunchAgent plist，不调用 `SMAppService.register/unregister`，不打开 System Settings，也不启动 HostCore。
- 不修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：5 个 readiness tests 先因 component types/policy 不存在而按预期编译失败。
- 定向 readiness policy：5 tests，0 failures。
- `swift test`：282 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

本步只冻结“什么证据组合才可称 ready”，尚未读取真实 `SMAppService.status`，也没有 authenticated XPC handshake/snapshot 输入。下一小步可在不创建 plist/注册服务的前提下，实现 macOS 13 `SMAppService.Status` 到上述 registration 状态的窄适配器，并保持 product App 未调用；共享 XPC wire 仍需主线明确跨端 schema 后再实现。
