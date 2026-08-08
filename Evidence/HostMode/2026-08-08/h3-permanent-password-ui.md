# H3.1b 本机永久密码 UI 自动证据

日期：2026-08-08

## Outcome

- Host 首页卡片从 HostSnapshot schema v2 投影本地永久密码、有效永久密码、preset 与 changeAllowed 状态。
- Host 运行且策略允许时，可通过两个 `NSSecureTextField` 设置或更换永久密码；确认值不一致时 fail closed。
- 仅存在本地永久密码时允许显式清除；若管理员 preset 仍可能生效，确认文案不把“本地已清除”表述成“已无有效密码”。
- set/clear 完成后重新读取权威 snapshot，不用 UI 乐观状态代替 HostCore truth。

## Secret lifecycle

- UI controller 不保存密码 `String` 属性；提交后立即清空两个 secure field。
- 显式传输使用 owner 管理的 mutable `Data`，owner 的显式路径与 deinit 都会清零。
- `HostControlClient` 在 ABI 调用返回后再次清零，Rust `SecretBuffer` 在所有返回路径清零 caller-owned bytes；hbb_common setter 的 H1 临时数组也已清零。
- 永久密码不进入 generic JSON、命令行、日志、UserDefaults、Viewer Keychain 或证据文件。
- AppKit secure field 的内部临时副本不受应用直接控制；本实现只对应用拥有的控件内容和显式 transfer buffers 给出可验证擦除保证。

## Fail-closed result boundary

- CoreBridge 将 ABI 的 empty、too-short、too-long、outer-whitespace、invalid-UTF8、forbidden-character、change-disabled 与 storage failure 分类成 typed Swift error；UI 只显示脱敏说明。
- `clearPermanentPassword` 现在同步传播 change-disabled/storage failure，同时保留脱敏 commandResult event，避免清除失败却被 UI 当作成功。
- Rust 定向测试覆盖 change-disabled set/clear、caller buffer wipe 与 event 不包含 canary secret。

## Fresh verification

- `cargo test --manifest-path Vendor/rustdesk/Cargo.toml --lib --features rdn-native-core,rdn-native-host permanent_password_change_disabled_wipes_secret_and_propagates_clear_error`：1 passed，0 failed（既有 warnings）。
- `./Scripts/build-rust-core.sh`：release arm64 `liblibrustdesk.dylib` 构建成功。
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`：112 tests，0 failures，0 skips；built-core Host lifecycle/ABI 3/3 通过。
- `swift build -c release`：通过。
- 两个 canonical patch reverse-check、Rust bridge mirror comparison、`git diff --check` 与 scoped secret scan：通过。

## Remaining manual acceptance

- 尚未对本轮 UI 产物进行视觉与真机设置/更换/清除验收。
- 需要在拥有 preset password 的受管构建上单独验证 local clear 后 preset 继续生效；当前自动测试只证明 snapshot/result 合同不会误报。
- 本步未修改 Hermes、CI、根依赖、数据库或真实凭据，也未提交或推送代码。
