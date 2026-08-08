# H3.1b permanent-password secret-buffer implementation

日期：2026-08-08

## Outcome

H3.1b 的本地 Host Control 合同已实现。Host ABI 从 v2 升到 v3，并新增 `rdn_host_set_permanent_password` 专用入口；永久密码不经过 generic JSON、命令行、日志、UserDefaults 或 Viewer Keychain。`clearPermanentPassword` 是无秘密输入的独立 command。

当前完成的是 Core/Swift control surface 与 snapshot/result 合同；本机设置密码的产品 UI 尚未接入，H3 整体仍未完成。

## Secret lifetime

- Swift 只接受 caller-owned mutable `Data`，使用 `withUnsafeMutableBytes` 调用 ABI，并在 `defer` 中 `resetBytes`；success 与 throw 路径均有执行测试。
- Rust 对合法 pointer/length 建立 `SecretBuffer` guard；在 success、policy reject、无 Host、无 command ID、change-disabled 与 storage failure 的所有返回路径调用 hbb_common 暴露的 libsodium memzero helper。
- `Config::compute_permanent_password_storage_for_update` 的 32-byte H1 临时数组在完成 encrypted verifier storage 编码后立即 memzero；定向单测可观察数组归零。
- snapshot、command result 与事件只包含布尔状态和稳定脱敏 detail，不包含明文、H1、salt、encrypted verifier 或 raw storage。

## Versioned policy

Rust HostCore 固化 strength policy v1：

- 输入必须是 UTF-8；
- set 拒绝 empty，clear 必须使用独立 command；
- 6–128 个 Unicode scalar，最多 512 UTF-8 bytes；
- 拒绝 NUL/其他 control characters；
- 拒绝 leading/trailing Unicode whitespace，不进行隐式 trim。

ABI 为 invalid UTF-8、empty、too short、too long、forbidden character、outer whitespace、change-disabled 与 storage failure 分配独立稳定错误码。UI 可以提前显示相同规则，但 Rust 会再次权威校验。

## Snapshot and result

HostSnapshot schema 升到 v2，新增：

- `localPasswordSet`；
- `effectivePasswordSet`；
- `usingPresetPassword`；
- `changeAllowed`；
- versioned strength-policy presentation。

clear 后会重新读取 effective authority；若 preset 仍有效，result 明确返回 local cleared / preset still effective，不把它显示成“没有永久密码”。

## Verification

- `cargo test -p hbb_common permanent_password --lib`：31 passed，0 failed，58 filtered out；新增 H1 wipe test 通过。
- `./Scripts/build-rust-core.sh`：release arm64 core 构建及新 symbol gate 通过；上游已有 warnings 保留，无新 build failure。
- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test --filter HostBridgeContractTests`：3 passed，0 failed；覆盖 ABI v3/symbol、policy rejection、Rust buffer wipe、真实 set/clear、snapshot truth 与 canary 不泄漏。
- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`：111 tests，0 failures，0 skips；Swift success/throw 双路径 wipe、built-core load 与完整 Host lifecycle 均通过。
- `swift build -c release`：Release `RustDeskNative` 编译链接通过。

## Boundaries

- 未修改 Hermes、wire/protobuf、数据库、CI、根依赖、真实凭据或服务端。
- 未保存或输出用户提供的 server public key。
- change-disabled/preset truth 使用 pinned `Config` authority；本步没有伪造 preset build 做额外真机 UI 验收。
- 本机密码 UI、approval broker、active session/revoke snapshot 与 H3 其余项仍待后续步骤。
