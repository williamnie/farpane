# H4.2g registration identity gate

## Outcome

CoreBridge 现在有一个 package-scoped registration identity gate，把 H4.2d LaunchAgent plist、H4.2e main bundle 和 H4.2f code signature 三类独立证据按固定顺序组合为稳定状态。该 gate 只说明 identity 是否可继续，不执行注册，也不把 identity eligibility 冒充后台 ready。

## Key evidence

- gate 固定执行 `plist identity → bundle identity → code signature`；任一步失败立即返回 `invalidLaunchAgent`、`invalidApplication` 或 `invalidCodeSignature`，不调用后续 inspector。
- plist 继续要求 exact label/Mach service/bundle-relative executable/完整 `--host-agent` argv；bundle 继续要求 `/Applications/FarPane.app` 与 packaged build ID；signature 继续要求固定 identifier/Team ID/Apple channel。
- 即使 injected inspector 返回伪造的 sanitized signature evidence，gate 仍再次核对固定 signing identifier 与 Team ID，不让测试/组合层误把不一致 evidence 提升为 eligible。
- Apple Development 只映射为 `localDevelopmentEligible(buildIdentifier:)`；Developer ID Application 在没有 H4.5 独立公证证据时固定映射为 `distributionNotarizationRequired(buildIdentifier:)`，没有 distribution-ready 分支。
- 所有 thrown errors 都被收敛为稳定状态；结果只携带经过 H4.2e 验证的非敏感 build ID，不保留 plist bytes、路径、certificate、requirement、Team 证书显示名或底层 Error。
- 产品 `assessMainBundle` 不接受 bundle/signature/path override；SwiftPM test bundle 因不在固定产品路径而真实 fail closed 为 `invalidApplication`。
- 本步仍接收已经取得的候选 plist bytes，仅证明 identity schema；它不证明该 data 已位于签名 App 的固定 asset path，也不验证尚未冻结的 lifecycle keys。因此不得据此调用 `SMAppService.register()`。
- 不导入/调用 ServiceManagement，不创建/打包 plist，不读取私钥、不修改 Keychain/App/service，不修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：7 个 tests 先因 `HostAgentRegistrationIdentityGate` 与 status type 不存在而按预期编译失败。
- 定向 identity-gate tests：7 tests，0 failures；覆盖成功顺序、三类失败短路、伪造 evidence rejection、channel 分流与真实 test-bundle fail-closed。
- `swift test`：309 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一安全小步是固定 signed LaunchAgent asset reader：只允许 `Bundle.main/Contents/Library/LaunchAgents/io.rustdesknative.viewer.host-agent.plist`，把真实 bundle resource 与本 gate 绑定，并继续在缺失 asset 时 fail closed。在 lifecycle keys、用户显式触发与 packaged/signature validation 都完成前，仍不能注册。
