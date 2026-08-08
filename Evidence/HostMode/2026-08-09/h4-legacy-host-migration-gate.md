# H4.2q legacy Host single-owner migration gate

## Outcome

建立了旧进程内 Host 到后台 HostAgent 之间的只读、fail-closed 单所有者迁移门禁。本步不执行迁移，也不改变任何真实 Host、会话、后台注册或系统设置状态。

## Key evidence

- `HostAgentLegacyHostMigrationEvidence` 独立携带七项 evidence：持久偏好、runtime、retained client、待审批、活跃会话、媒体管线、轮询器；每项只能是 `absent`、`present` 或 `unavailable`。
- 只有七项全部为 `absent` 才返回 `eligible`；任一未知值先于其他判断返回 `failed(.evidenceUnavailable)`。
- runtime 已停止但仍存在待审批、活跃会话、媒体管线或轮询器，以及 client 已释放但仍存在 runtime-owned 责任，均返回 `failed(.inconsistentEvidence)`。
- 完整且一致的非静止状态返回 exact blocker set，调用方不能只依赖旧 Host preference 或单一布尔值。
- source boundary 自动审计禁止产品 UI/服务框架、旧 Host client、偏好存储及 start/stop/register mutation authority。

## TDD evidence

首次只加入 focused tests 时，编译按预期失败：`HostAgentLegacyHostMigrationEvidence` 与 `HostAgentLegacyHostMigrationGate` 尚不存在。加入纯门禁实现后，同一命令执行 8 tests、0 failures。

## Verification

- `swift test --filter HostAgentLegacyHostMigrationGateTests`：8 tests，0 failures。
- `swift test`：545 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：成功。
- scoped added-line secret scan：无匹配。

## Remaining boundary

本门禁没有连接 `AppDelegate`，不会主动停止旧 Host。后续 App-side coordinator 必须先安全收敛旧 Host preference/runtime/client/session/media/poller，再以 fresh evidence 重跑本 gate；只有 `eligible` 才能进入 H4.2o/p 注册确认流程。真机安装、后台审批、双端连接与退出 App 后仍可连接继续留待用户设备恢复后验收。
