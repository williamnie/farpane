# H4.2d LaunchAgent plist identity preflight

## Outcome

CoreBridge 现在有一个 package-scoped、纯数据的 LaunchAgent plist preflight。它在任何 `SMAppService.register()` 之前固定并验证产品 service identity、同一 App executable 的 bundle-relative 路径、完整 `argv` 中唯一的 `--host-agent` mode，以及唯一启用的 Mach service；无效输入 fail closed。

## Key evidence

- 本机 macOS 26.2 SDK 的 `SMAppService.agent(plistName:)` 合同要求 plist 位于调用 App 的 `Contents/Library/LaunchAgents`，并允许 `BundleProgram` 使用 App bundle-relative executable path。
- 本机 `launchd.plist` 手册确认 `BundleProgram` 映射 executable，`ProgramArguments` 映射完整 argument vector；产品预检因此固定 `Contents/MacOS/RustDeskNative` 与 `["RustDeskNative", "--host-agent"]`，拒绝缺少 argv[0]、附加参数、相似 flag 或绝对路径替代。
- `Label` 和唯一 `MachServices` key 都固定为 `io.rustdesknative.viewer.host-agent`；Mach service 必须是 plist boolean `true`，额外 service 或 numeric/false 值均不能通过。
- `Program` 被禁止，避免用外部绝对 executable 绕过同 bundle 约束；`UserName`/`GroupName` 被禁止，因为它们只适用于 privileged system domain，而 H4 V1 明确只使用登录用户 LaunchAgent。
- 输入在解析前限制为 64 KiB；语法错误与非 dictionary plist 均按固定 typed error 拒绝，不保留底层解析错误或输入内容。
- 本步只验证不可变的产品身份边界；`RunAtLoad`、`KeepAlive` 等 lifecycle/restart policy 尚未冻结，也没有创建或打包真实 plist。
- validator 不读取路径、Bundle、环境变量或系统 service，不调用 register/unregister，不修改系统状态，不定义 XPC wire/schema。
- 不修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：新增 tests 先因 `HostAgentLaunchAgentPlistPreflight` 与 error type 不存在而按预期编译失败。
- 定向 preflight tests：6 tests，0 failures；覆盖 valid identity、malformed/oversized、label/program/argv/Mach service 与 privileged-key rejection。
- `swift test`：293 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一小步应单独冻结 LaunchAgent 的 lifecycle/restart keys 及其停止语义，再创建随 App 签名的 plist packaging contract；在真实 asset、build packaging、签名检查与 registration command 都完成前，仍不允许注册或把 service 显示为 ready。
