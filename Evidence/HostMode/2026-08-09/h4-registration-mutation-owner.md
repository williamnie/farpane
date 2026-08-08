# H4.2m explicit registration mutation owner

## Outcome

建立唯一、显式用户 intent 驱动的 `SMAppService` registration mutation owner；本步没有把 owner 接到 App/UI，也没有修改本机 Login Items。

## Key evidence

- owner 构造态固定为 inert `idle`，不评估 identity、不构造或读取 service，也不执行 mutation；只有 typed `registerBackgroundAgent` / `unregisterBackgroundAgent` intent 能进入操作链。
- register 顺序固定为 explicit intent → H4.2d–h/l signed identity/lifecycle gate → 固定 plist service register → 权威 status observation；identity 失败时不会构造或调用 ServiceManagement mutation。
- local Apple Development eligibility 当前允许本地开发注册；Developer ID 在 H4.5 notarization evidence 前保持 `distributionNotarizationRequired`，不能伪装 production eligible。
- unregister 不依赖当前 registration eligibility。这是故意保留的恢复边界：即使当前 App identity/signature/preflight 已失效，用户仍可明确取消旧注册。
- register/unregister 的返回或 NSError 不作为最终状态；mutation 后统一映射 `service.status`。enabled → registered，requiresApproval → 独立非 ready 状态，notRegistered → unregistered 或 registrationNotEffective，notFound/future status → serviceUnavailable。
- 已调用 register、registered/enabled 和 requiresApproval 均没有接入 H4.2a readiness；后台 ready 仍需 authenticated handshake、authoritative snapshot 与 Rendezvous registration 三份额外证据。
- operation 期间第二个 intent 和 observer reentrant intent 都稳定拒绝，避免注册/取消注册被隐式串联；publication 使用单调 generation，不保留 raw Error、plist bytes、路径、签名 evidence 或 build identifier。
- product closure 只使用 `HostAgentBackgroundServiceObserver.plistName`，不接受路径、plist、service、环境变量或 bundle override；不具备打开 System Settings、写 UserDefaults、启动旧 HostCore 或连接 SwiftUI/AppKit 的能力。
- 本步测试只使用注入的 fake mutation；`makeProduct()` 只验证惰性构造和 source boundary，未调用 `apply`，因此没有注册/取消注册真实服务，没有启动 Agent 或打开 Login Items 设置。
- 未修改 Host ABI、XPC wire、Rust、Hermes、CI、根依赖、根配置或数据库，未读取真实配置/密钥，未安装、部署或 push。

## Verification

- TDD RED：focused test 首次因 mutation owner/types 尚不存在而编译失败；实现后转绿。
- mutation owner focused：11 tests，0 failures、0 warnings；覆盖 inert construction、四类 identity rejection、enabled/requiresApproval/notRegistered/serviceUnavailable、unregister recovery、call-error/status authority、并发 intent 和 observer reentry。
- 完整 Swift 回归：516 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：23 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/修改行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.2n 建立显式 `requiresApproval` 用户确认后的 System Settings 导航边界，并保持导航、registration mutation、Agent activation/readiness 三者独立；仍不在自动测试或默认启动路径触发真实系统变更。
