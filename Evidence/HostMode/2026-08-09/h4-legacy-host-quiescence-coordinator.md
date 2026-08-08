# H4.2r legacy Host quiescence coordinator

## Outcome

建立了显式、同步、一次性的旧 Host 静止协调边界。它把 H4.2q 的 initial assessment、允许范围内的一次 quiescence request，以及请求后的 fresh assessment 串为不可跳过的顺序，但尚未连接产品运行态。

## Key evidence

- 构造保持 inert；只有 typed `prepareForBackgroundRegistration` intent 才采集 evidence。
- initial evidence 已静止时直接 ready，不调用 quiescence；unknown/inconsistent 时原样 fail closed。
- blocker 含 pending approval 或 active session 时不调用 quiescence，避免后台迁移静默打断用户或远端会话。
- 只有不含交互工作 blocker 的完整状态才调用一次注入的 quiescence request，并严格按 `capture → request → fresh capture` 执行。
- request failed 固定失败，不能被之后看似静止的 tuple 掩盖；request completed 后仍以 fresh H4.2q assessment 为唯一 eligibility 证据。
- operation-in-flight 门禁拒绝并发及依赖重入请求，保证单次 intent 最多一次 quiescence。
- source 审计证明 coordinator 没有产品 UI、服务注册、偏好、旧 Host client 或直接 start/stop authority。

## TDD evidence

首次只加入 focused tests 时，编译按预期失败：coordinator 与 typed quiescence result 尚不存在。实现后同一命令执行 10 tests、0 failures。

## Verification

- `swift test --filter HostAgentLegacyHostMigrationCoordinatorTests`：10 tests，0 failures。
- `swift test`：555 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：成功。
- scoped added-line secret scan：无匹配。

## Remaining boundary

当前 coordinator 只有 dependency seams，并未读取 `AppDelegate` 的七项真实状态，也没有调用旧 Host stop。下一步的 MainActor product adapter 必须把 stop 抛错保留为 `.failed`，并在失败时把无法证明已释放的 runtime/client 证据标为 unavailable；不得复用当前“catch 后仍将 runtime 标为 false”的宽松路径。只有 coordinator 返回 `readyForRegistration`，产品层才可进入 H4.2o/p 用户确认；真机后台注册和持续连接仍留待设备恢复后验收。
