# H4.2e registration bundle identity preflight

## Outcome

CoreBridge 现在有一个 package-scoped 注册前 bundle identity preflight。产品入口只从 `Bundle.main` 取得实际 bundle URL、symlink-resolved URL 与 Info.plist，在任何 `SMAppService` mutation 之前固定验证 `/Applications/FarPane.app`、Bundle ID、package type、同一 executable 与 build ID；任一证据缺失或漂移均 fail closed。

## Key evidence

- 原始 bundle URL 与 symlink-resolved URL 都必须是无 host/user/query/fragment 的本地 file URL，且精确落在 `/Applications/FarPane.app`；用户目录副本、网络 URL 和解析到其他位置的 alias 均被拒绝。
- `CFBundleIdentifier` 固定为 `io.rustdesknative.viewer`，`CFBundlePackageType` 固定为 `APPL`，`CFBundleExecutable` 固定为 `RustDeskNative`。
- `CFBundleVersion` 必须是 String，并与 H4.1 bootstrap 使用同一非空、最多 128 UTF-8 bytes、alphanumeric/`.-_+` token 合同；返回的 identity 只包含该脱敏 build ID。
- 产品 API 不接受路径、metadata、环境变量或调用方 build ID；package-scoped injected validator 仅供定向测试和后续同 module composition 使用。
- SwiftPM test bundle 不在固定产品路径，真实 `inspectMainBundle()` 动态 smoke 因而稳定返回 `invalidLocation`，没有创建文件或调用 ServiceManagement。
- 本步只完成 §13.1 application identity 的非签名部分；Team ID、designated requirement、channel-specific Developer ID/notarization 仍必须由独立 code-signing preflight 提供，不能因 bundle metadata 通过就注册或显示 ready。
- Apple 的 `SMAppService` 公共合同只提供 register/unregister/status；unregister 会终止服务并改变注册状态。故 launchd crash recovery 与 `stopHostAgent`“保持注册但停止”之间的生命周期冲突保持 open，本步没有冻结 `KeepAlive`/`RunAtLoad` 或伪造 stop API。
- 不创建/打包 plist，不调用 register/unregister/open settings，不修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：5 个 tests 先因 preflight/error/identity type 不存在而按预期编译失败；随后新增 `+` build token 合同测试先真实失败，证明并修复与 H4.1 bootstrap 的范围偏差。
- 定向 bundle preflight tests：5 tests，0 failures。
- `swift test`：298 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一安全小步是 code-signing evidence adapter：只读提取并验证 Team ID、designated requirement 与签名 channel，notarization 继续由 H4.5 公证/干净机验收给出。LaunchAgent lifecycle plist 必须先明确“保持注册但强制停止”的受支持产品语义，不能直接用 unconditional `KeepAlive` 覆盖设计。
