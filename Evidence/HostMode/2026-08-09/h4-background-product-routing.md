# H4.2x background product terminal routing

## Outcome

AppDelegate 现有独立 MainActor registration/unregistration begin seam，并通过纯 typed policy 把两个 flow 的完整终态路由到 background activation owner。Home Host switch 尚未切换到这些入口，因此本步不会显示 sheet、停止 legacy Host 或修改系统注册。

## Key evidence

- registration 只有 `registered + enabled`、`navigationRequested + requiresApproval`、`approvalNoLongerRequired + enabled`，以及用户保留 requires-approval 注册意图时，才 enable 并立即 refresh background observation。
- approval 重查得到 `notRegistered` 时停止 observation；首次取消、迁移 blocker 与精确匹配的预期 mutation/navigation failure 保持当前 activation，不猜测系统状态。
- unregistration 只有 `unregistered + notRegistered` 精确终态会停止 observation；取消和精确匹配的 service/not-effective failure 保持当前 activation。
- driver 异常回调出的中间 phase、错误 intent/failure 或 phase/status 矛盾统一 `invalidCompletion`，App 以停止本地 observation fail closed；该动作不会调用 register/unregister 或恢复 legacy preference。
- registration 与 unregistration driver 各只有一个 AppDelegate `begin` 调用点，均要求主窗口存在并在 MainActor 上完成 terminal routing；Home 没有引用这些入口。
- App termination 现在向同一个 lazy activation owner 发送 terminal intent，确保未来已启动的 background observation 在进程退出前取消。

## TDD evidence

只新增 routing matrix 与 App composition 测试时，focused build 按预期因 `HostAgentBackgroundProductRoutingPolicy` 不存在而失败。实现 pure policy 和 AppDelegate seam 后，新矩阵 7 tests 全部通过；既有 registration presentation、registration driver、unregistration presentation 与 legacy migration product adapter 回归也全部通过。

## Verification

- `swift test --filter HostAgentBackgroundProductRoutingPolicyTests`：7 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationPresentationPolicyTests`：8 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationSheetDriverTests`：3 tests，0 failures。
- `swift test --filter HostAgentBackgroundUnregistrationPresentationPolicyTests`：6 tests，0 failures。
- `swift test --filter HostAgentLegacyHostProductEvidencePolicyTests`：7 tests，0 failures。
- `swift test`：597 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --cached --check`：提交前执行。
- scoped added-line secret scan：提交前执行。

## Remaining boundary

Home Host switch 仍直接控制 legacy in-process Host，两个 background begin seam 目前没有产品调用方。下一步应建立显式 Home enable/disable intent 与 authoritative switch reconciliation：enable 调 registration flow，disable 调 unregistration flow，取消/失败恢复权威展示；必须先保证 legacy 自动启动和 preference 不会与 Agent 同时成为 Host owner。真实 SMAppService、退出后连接与 requiresApproval 行为仍需后续签名 App 真机验收。
