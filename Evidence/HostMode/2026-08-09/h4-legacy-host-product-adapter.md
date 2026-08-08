# H4.2s MainActor legacy Host product adapter

## Outcome

H4.2r coordinator 已惰性接到 AppDelegate 的真实旧 Host 状态；Core stop 的失败不再被本地清理动作伪装为已静止。本步提供产品 capability，但没有 UI/registration 调用点，因此不会在当前构建中主动迁移。

## Root-cause evidence

- `HostControlClient.stop` 在调用 Core stop 前取走本地 handle，并在返回后无条件 destroy；只有随后检查非 OK 返回码时才抛错。
- 旧 `stopHostMode` catch 该错误后仍执行 `hostRuntimeActive = false`，并可按参数释放 client；调用 Viewer 和服务器配置重启的路径也不检查 stop 结果。
- 因而旧布尔值只能证明 App 清理了引用，不能证明 Core stop 成功；直接据此注册 HostAgent 会产生单所有者证据缺口。

## Key evidence

- 新 observation policy 动态覆盖 idle、running、snapshot unavailable、stop unconfirmed 和 off-main unavailable；它不读取产品全局状态。
- AppDelegate 的 lazy coordinator 只在 main thread 通过 MainActor isolated methods 读取 preference/runtime/client/snapshot/media/poller/stop-confirmation；off-main fail closed。
- runtime 运行但 snapshot 缺失时 pending/active 为 unavailable；stop 未确认时 runtime/pending/active 均 unavailable。
- quiescence request 在 stop 前再次检查 pending approval 与 active session，防止 initial assessment 后的会话竞态。
- `stopHostMode` 现在返回 Bool；Core stop 错误或 active-without-client 会保留 unconfirmed 状态及 client，不允许 release、restart 或迁移。
- outbound Viewer 切换和 server-change Host 重启只有在 stop 成功时继续；失败显示稳定、脱敏、可恢复指引。
- `prepareLegacyHostForBackgroundRegistration` 当前仅有定义，没有 Home、App lifecycle 或 sheet 调用点；构造 coordinator 也不产生动作。

## TDD evidence

首次只加入 focused tests 时，编译按预期失败：product observation、session observation 与 evidence policy 尚不存在。实现和产品接线后，同一命令执行 7 tests、0 failures。

## Verification

- `swift test --filter HostAgentLegacyHostProductEvidencePolicyTests`：7 tests，0 failures。
- `swift test`：562 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：成功。
- scoped added-line secret scan：无匹配。

## Remaining boundary

H4.2o 当前肯定确认会直接调用 H4.2m registration owner；H4.2p product factory 也固定创建该默认组合。下一步必须建立 post-confirmation composition：先调用本步 product prepare，只有 `readyForRegistration` 才调用 register；pending/active blocker、evidence failure 与 stop failure 不能伪装成 registration failure，也不能触发 SMAppService。完成该组合前继续不把 sheet 接到 Home 开关。真机 stop-failure 注入、后台审批和 App 退出后持续连接留待设备恢复后验收。
