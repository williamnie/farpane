# H4.2t post-confirmation migration to registration

## Outcome

用户肯定确认之后的产品无关顺序已冻结为 `migration preparation → exact ready proof → registration`。所有产品 factory 都必须显式注入 migration，旧 Host 未安全静止时不再存在直接 register 的默认组合。

## Key evidence

- persistence prompt 的取消和错序 intent 不调用 migration 或 registration。
- 肯定确认先发布 `preparingLegacyHost`；migration accepted 且 phase 为 `readyForRegistration` 才发布 `registering` 并调用 registration owner。
- exact blockers 进入 `migrationBlocked(Set)`，保留 pending/session/runtime 等语义；quiescence/assessment failure 进入独立 migration failure，不冒充 registration failure。
- accepted 与 phase 矛盾，或 coordinator 仍为 idle/assessing/quiescing，统一 invalidMigrationResult 且 registration 调用计数为零。
- blocker retry 必须重新请求 persistence prompt 并再次肯定确认；直接重复 confirm 被拒绝。
- blocking migration 期间并发 confirm/navigation 被拒绝，事件顺序固定为 prepare 完成后才 register。
- CoreBridge 无参数 product factory 已删除；AppKit driver factory 同样要求 migration closure，产品调用方不能漏接 H4.2q–s。
- AppDelegate preparation 返回 `(accepted, coordinator.snapshot())`，但目前没有 driver 构造或 begin 调用点。

## TDD evidence

只修改测试时编译按预期失败：migration UX phase/failure、required initializer seam 与 coordinator view initializer尚不可用。实现后 UX focused 17 tests、sheet-driver focused 3 tests 均为 0 failures。

## Verification

- `swift test --filter HostAgentBackgroundRegistrationUXOwnerTests`：17 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationSheetDriverTests`：3 tests，0 failures。
- `swift test`：568 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：成功。
- scoped added-line secret scan：无匹配。

## Remaining boundary

AppDelegate 尚未强持有使用真实 migration closure 的 sheet driver，也没有把 `migrationBlocked`、migration failure、registration failure 或 requiresApproval 映射为产品状态文案；当前 Home toggle 仍控制旧进程内 Host。下一步先建立惰性 App-owned driver composition 与 typed presentation policy，但不自动 begin；产品入口替换、真实注册、Login Items 审批、App 退出后连接继续留待后续步骤和真机验收。
