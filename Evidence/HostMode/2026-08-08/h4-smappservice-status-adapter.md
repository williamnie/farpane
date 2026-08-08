# H4.2b SMAppService status adapter

## Outcome

CoreBridge 现在有一个 package-scoped、只读的 macOS 13 `SMAppService.Status` 适配器，把系统 registration observation 精确输入 H4.2a readiness policy。它不构造或改变服务，不会因读取状态而发起注册、取消注册或打开 System Settings。

## Key evidence

- 本机 Xcode 26.3 / macOS 26.2 SDK 的 `SMAppService.h` 确认 macOS 13 status 合同为 `notRegistered`、`enabled`、`requiresApproval`、`notFound`；header 明确用户拒绝或撤销 consent 也返回 `requiresApproval`。
- 映射固定为：notRegistered → notRegistered，enabled → enabled，requiresApproval → requiresApproval，notFound → serviceUnavailable。
- `@unknown default` 一律映射 serviceUnavailable；未来 SDK 新增状态不会被旧 build 猜成 enabled/ready。
- adapter 只接受一个已经取得的 `SMAppService.Status`，没有 service/plist/path 参数，也不调用 `SMAppService.agent`、`register`、`unregister` 或 `openSystemSettingsLoginItems`。
- 返回值仍只是 registration 这一份证据；H4.2a 会继续要求 authenticated handshake、snapshot 与 Rendezvous 全部健康，enabled 不等于 ready。
- 所有新增类型保持 package scope；不定义 XPC message/schema，不新增 command、selector、payload 或公共 ABI。
- 本步没有创建 LaunchAgent plist、修改 App bundle、读取真实 service 状态或改变系统登录项；未启动 HostCore。
- 不修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：adapter test 先因 `HostAgentSMAppServiceStatusAdapter` 不存在而按预期编译失败。
- 定向 adapter tests：2 tests，0 failures；覆盖四个已知状态、未知值 source guard 与只读边界。
- `swift test`：284 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

本步不读取真实服务。下一小步应冻结 App bundle 内 LaunchAgent plist 的不可注入名称与只读 observer：只构造 `SMAppService.agent(plistName:)` 并读取 status，不注册服务；在 packaged plist/signing/build-ID preflight 完成前，register/unregister 继续不可调用。
