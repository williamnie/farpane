# H4.2y authoritative Home Host routing

## Outcome

Home Host switch 现已从 legacy-only `setHostModeEnabled` 切换到单一产品路由：系统 registration、完整 legacy migration assessment 与当前 background sheet flow 共同决定开关真值、可操作性和 enable/disable 动作。自动测试未运行 App，因而没有显示真实 sheet、停止真实 Host 或调用 ServiceManagement mutation。

## Key evidence

- pure policy 分离四种动作：停止 legacy Host、开始 registration、开始 unregistration、no-op；用户关闭 legacy Host 绝不会被解释为注册后台组件。
- `notRegistered` 且 legacy durable intent/runtime 仍在时，开关保持 on，关闭只走带 `releaseClient` 的 legacy stop；旧 owner 静止后再次开启才进入已确认的 migration→registration flow。
- `enabled` / `requiresApproval` 且 legacy evidence eligible 时，开关保持 on，关闭进入 explicit unregistration；若 legacy 仍有 ownership，则开关禁用并先复用 H4.2r/s/t coordinator 尝试安全 quiescence，pending approval/active session 不会被自动打断。
- registration service unavailable、legacy evidence failure、双 owner 冲突或任一 sheet flow 在途时，Home switch 均不可操作；Home 渲染不能以 NSSwitch 的瞬时乐观状态代替权威 readback。
- App 进入 Home 或重新 active 时执行固定只读 registration observation。已注册且 legacy eligible 才启动 background observation；状态未知时不自动启动 legacy，避免不确定条件下形成第二个 Host owner。
- registration/unregistration completion 先核对 matching flow，再接受 terminal registration；invalid completion 将状态降为 serviceUnavailable 并停止 observation。activation health 后续观测到 notRegistered 也会停止 reconnect owner。
- Home 基础状态文案明确区分 notRegistered、requiresApproval、enabled 与 serviceUnavailable；enabled 只显示“已注册，正在检查可连接状态”，不冒充 Agent ready。
- `HostHomeSnapshot.isControlEnabled` 独立控制 NSSwitch interaction；连接在途和产品 policy 必须同时允许才可操作。

## TDD evidence

只新增测试时按预期因 Home flow/control/launch types 与 policy 不存在而编译失败；pure 6-path matrix 实现后，App/Home source boundary 仍有 10 条 RED，证明旧 callback、legacy setter、launch/control composition 与 begin call sites 尚未接线。完成产品接线后新 focused 7 tests 全绿，相关 terminal routing、legacy evidence、两类 presentation 与 registration driver 回归均通过。

## Verification

- `swift test --filter HostAgentBackgroundHomeRoutingPolicyTests`：7 tests，0 failures。
- `swift test --filter HostAgentBackgroundProductRoutingPolicyTests`：7 tests，0 failures。
- `swift test --filter HostAgentLegacyHostProductEvidencePolicyTests`：7 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationPresentationPolicyTests`：8 tests，0 failures。
- `swift test --filter HostAgentBackgroundUnregistrationPresentationPolicyTests`：6 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationSheetDriverTests`：3 tests，0 failures。
- `swift test`：604 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --cached --check`：提交前执行。
- scoped added-line secret scan：提交前执行。

## Remaining boundary

Home switch 已切换到 background 产品流，但 Home 的 `isRunning`、local ID、密码、pending approval、active session 与媒体状态仍来自 legacy in-process snapshot；background activation 目前只把 registration 真值反馈到 Home。下一步应建立严格的 background readiness/authoritative snapshot presentation：只有 H4.2a 四证据 ready 才显示“可被连接”，并从 H4.3 snapshot projection 显示后台 Agent 的公开状态；不得混用 legacy snapshot 或让 registered 冒充 ready。之后才生成签名 App 做真实 registration/requiresApproval/退出后连接验收。
