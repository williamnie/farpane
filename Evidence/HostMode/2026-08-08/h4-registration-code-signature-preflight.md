# H4.2f registration code-signature preflight

## Outcome

CoreBridge 现在有一个 package-scoped、只读的注册前 code-signature preflight。它先执行 H4.2e 的固定 bundle identity gate，再使用 Security.framework 对整个 App、全部架构和标准嵌套代码执行严格静态签名验证；只有固定 signing identifier、Team ID 与 Apple Development/Developer ID Application channel 能产出脱敏 evidence。

## Key evidence

- 产品 signing identifier 固定为 `io.rustdesknative.viewer`，Team ID 固定为 `3J43F8H829`；两者进入编译后的 code requirement，不从 Info.plist、环境变量、证书显示名或调用方输入获取。
- base requirement 同时要求 `anchor apple generic`、固定 identifier 与 leaf certificate OU 中的固定 Team ID；因此仅名称相似、ad-hoc、自签名、其他 Team 或其他 bundle identifier 均不能通过。
- Developer ID Application channel 按 Apple TN3127 的 Developer ID issuing CA OID `1.2.840.113635.100.6.2.6` 与 leaf OID `1.2.840.113635.100.6.1.13` 验证；development channel 使用 Apple Development issuing CA OID `1.2.840.113635.100.6.2.1`。不依赖个人 certificate CN。
- `SecStaticCodeCheckValidity` 使用 check-all-architectures、check-nested-code 与 strict-validation flags；随后才读取 signing information，并再次要求 identifier/Team ID 精确一致。
- 产品 `inspectMainBundle()` 无参数，不能绕过 H4.2e `/Applications/FarPane.app` 与 metadata gate；package-scoped URL API 仅供已经完成 bundle preflight 的同 module composition 与动态测试。
- 成功 evidence 只包含固定 signing identifier、Team ID 和 channel；失败只返回稳定枚举，不保留 certificate chain、subject、requirement text、路径或底层 Security error。
- 当前 `/Applications/FarPane.app` 动态 smoke 通过并被分类为 development；签名有效的系统 Calculator 因产品 authority 不匹配而 fail closed。该证据不把当前开发构建称为可分发版本。
- notarization/stapling/Gatekeeper/quarantine 仍是 H4.5 独立证据；本步不以 Developer ID requirement 或 ticket presence 推断公证成功。
- 不读取证书私钥，不修改 Keychain、App 或系统 service；不调用 register/unregister/open settings，不创建/打包 plist，不修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：4 个 tests 先因 code-signature preflight/evidence/error types 不存在而按预期编译失败。
- 定向 code-signature tests：4 tests，0 failures；包含当前安装产品的真实 Security.framework validation 与其他 Apple authority rejection。
- `swift test`：302 tests，4 skipped，0 failures；安装产品的签名动态测试实际执行、未 skip。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一安全小步是把 H4.2d plist identity、H4.2e bundle identity 与本步 signing evidence 合成单一 registration-readiness policy；development channel 只能用于明确的本地开发路径，Developer ID 仍必须等待 H4.5 notarization evidence。该 policy 仍不得调用 `SMAppService.register()`，直到用户触发、lifecycle 语义和真实 packaged plist 都完成。
