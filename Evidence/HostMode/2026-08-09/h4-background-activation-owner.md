# H4.3e4g explicit App-side background activation owner

## Outcome

新增独立 App-side background activation owner：只有显式 typed Host/lifecycle intent 才能创建并启动 e4f product composition；disable、App termination、失败与并发取消均撤下当前 runtime，迟到工作不能复活。

## Key evidence

- product factory 自身完全 inert，不读取 registration、不创建 e4f composition、不启动 XPC；首次 `hostEnabled` 才创建 fresh composition，安装其初始 readiness view 后调用唯一 reconnect owner `start()`。
- `hostEnabled` 在 starting/monitoring 幂等；factory throw、runtime start=false、health authority reject 与同 generation mutation 分别映射稳定脱敏 failure，不保留底层 Error、transport、identity 或 payload。非 terminal failure 只能由新的显式 enable 创建新 epoch 重试。
- e4e reconnect owner 是 one-shot，因此每次 disable→enable 都创建全新 health/projection/reconnect composition；旧 runtime callback 绑定旧 activation epoch，即使旧对象仍被测试持有也无法改变新状态。
- disable 和 `applicationWillTerminate` 都先原子撤下 runtime/旋转 epoch，再调用 cancel，最后发布状态；cancel 同步 callback 会被 epoch/state gate 忽略。App termination 为 terminal，后续 enable 固定拒绝。
- App termination 只表示 App 停止本地 XPC observation，不等价于 `disableHost`，也不修改 durable Host intent、Agent registration、identity 或配置。
- blocking factory、blocking start、factory completion after disable 与 monitoring observer reentrant disable 均有 deterministic concurrency tests；被取消 runtime 不会在 observer 返回后启动，stale factory runtime 只 cancel 不 start。
- registration refresh 只转发给当前 monitoring composition；idle/disabled/starting/failed/terminated 均不触发 observer 或创建 runtime。
- activation/health view 使用独立 non-wrapping generation 与 activation epoch；接近上限时 fail closed 为 `generationExhausted`，不复用旧 token。
- 本步不读取或写入 UserDefaults，不接旧进程内 `HostControlClient`、AppKit、SwiftUI 或产品 lifecycle，不定义 Host command，也不启用顶层 Agent entry。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService registration、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 activation runtime/intent/view/owner 不存在而编译失败；实现后转绿。
- activation owner focused：13 tests，0 failures、0 warnings；覆盖 single enable、typed health、disable-before-publication、fresh re-enable/old epoch、terminal App exit、factory retry、start reject、health reject、blocking factory/start、observer reentry、registration refresh 与 inert/source boundary。
- 完整 Swift 回归：476 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：22 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/新增行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步回到 H4.1 顶层 Agent 产品入口：重新审计 `--host-agent` fail-closed dispatch 与已完成的 process runner/XPC listener composition，拆出一个可自动验证的 enablement preflight 小步；在 SMAppService plist/registration、真实签名安装与产品 lifecycle 尚未落地前，不直接启用或部署后台 Agent。
