# H3.1b permanent-password secret-buffer readiness

日期：2026-08-08

## Outcome

在不修改共享 Host ABI/schema 的前提下，已从 pinned core 的真实实现确定 permanent-password dedicated secret-buffer 入口所需的 authority、内存清零、clear/preset 状态和结果合同。H3.1b 尚未实现，等待用户明确允许本地 Host Control ABI/snapshot 扩展。

## Pinned authority

`Config::set_permanent_password(&str)` 是应复用的唯一本机更新 authority：

- change-disabled option 为 true 时拒绝；
- 非空输入使用现有或新生成的 32-character salt 计算 SHA-256 H1；
- H1 先编码为 current verifier storage，再由带随机 nonce 的 secretbox 保护；
- 只有 encrypted verifier 和 salt 写入配置，永久密码明文不落盘；
- storage 实际变化后清除 trusted devices；相同 storage 作为 idempotent success；
- 空输入清除 local storage；如果 hard/preset password 仍可用，effective permanent password 仍为 set。

认证链会严格解码 local/preset H1，使用 challenge 生成 H2 并 constant-time compare。FarPane 不需要可恢复明文，因此无需在 Keychain 保存永久密码副本；设计中“verifier 优先”路径可直接满足互操作。

## Missing Rust policy

现有 Rust setter 不检查密码长度、字符集或强度。pinned legacy UI 会 `trim()` 并要求至少 6 个字符，但该检查可被其他调用方绕过，不是 §9.3 要求的 HostCore authority。

正式实现前必须冻结 versioned strength policy，包括：

- UTF-8 / NUL / control-character 规则；
- 最小强度和最大 byte length；
- 是否保留 leading/trailing whitespace；
- stable rejection codes，不能把 validation、change-disabled 与 storage failure 合并成一个 bool。

UI 可以提前显示相同规则，但 Rust 必须再次权威验证。secret set 入口应拒绝 empty；clear 使用无 secret 的独立 command，避免空 buffer 意外清除凭据。

## Secret-buffer contract

推荐的本地 C ABI 形态（尚未写入 header）：

```c
int32_t rdn_host_set_permanent_password(
    RdnHost *host,
    const char *command_id,
    uint8_t *password_utf8,
    size_t password_length);
```

约束：

1. pointer 为 mutable，Rust 对合法 pointer/length 构造 mutable slice；
2. Rust 只借用该 slice 为 UTF-8 `&str`，直接调用 in-process Config authority，不经过 JSON、IPC 或命令行；
3. Rust 在 success、validation reject、change-disabled、storage failure 等所有返回路径用 `sodiumoxide::utils::memzero` 清零整段 caller buffer；
4. Swift 用 mutable `Data` 提供 bytes，并在 `defer` 中调用 `resetBytes` 做第二次清零；
5. Swift 立即清空 `NSSecureTextField`；AppKit/Swift String 的系统内部副本无法由应用证明完全擦除，因此不得额外缓存、记录或写入 UserDefaults；
6. `compute_permanent_password_storage_for_update` 当前的 H1 local array 尚未清零，正式实现需在 storage encoding 后 memzero；
7. C 函数返回值只表示 ingress/执行调用状态，最终 product result 仍用带 `commandId` 的脱敏 event，并触发 authoritative snapshot refresh。

当前依赖图已包含 `sodiumoxide`，其 `utils::memzero` 调用 libsodium `sodium_memzero`，不需要新增根依赖。

## Snapshot and result contract

`passwordPolicy` 至少需要区分：

- `localPasswordSet`；
- `effectivePasswordSet`；
- `usingPresetPassword`；
- `changeAllowed`；
- versioned strength-policy presentation；
- 非敏感 `updatedAt`（若要跨重启准确显示，需新增持久化 authority，不能由 App 猜测）。

Clear result 必须如实区分 `localCleared` 与 `effectivePasswordSet`。若 preset 仍有效，UI 应显示“本地密码已清除，预设密码仍生效”，不能显示“未设置”。snapshot/result 永不包含明文、H1、encrypted verifier、salt 或 raw storage。

## Required implementation tests

- Rust buffer 在 success 和每个 reject/error path 后全零；Swift `Data` 在 thrown/success path 后全零；
- invalid UTF-8、NUL、policy too weak/too long、empty set、change-disabled 分别返回稳定结果；
- same password idempotent、real update clears trusted devices、clear local password、preset remains effective；
- H1 temporary array wipe 有可测试 helper boundary；
- snapshot local/effective/preset/changeAllowed truth table，不含任何 secret material；
- command result 只含 command ID、stable status 和脱敏 detail；
- built-core ABI lifecycle、Swift decoder/UI state 与 release App build；
- canary secret 不出现在日志、snapshot、diagnostics、UserDefaults 或 generic JSON command。

## Verification

- 读取 `Config::set_permanent_password`、storage encode/encrypt、config store、effective local/preset readback、trusted-device invalidation与 server authentication chain。
- 读取现有 UI/IPC setter，确认 legacy strength gate 只在 UI，IPC 使用 owned String；dedicated in-process ABI 可避免该复制链。
- 确认 pinned `sodiumoxide::utils::memzero` 与 Swift `Data.resetBytes` 可用。
- `cargo test -p hbb_common permanent_password --lib`：30 passed，0 failed，58 filtered out。
- 本步未修改 C ABI、snapshot schema、protobuf、Hermes、CI、根依赖、配置文件或密钥。
