# H3.1a permanent-password authority and secret-transport audit

- 日期：2026-08-08
- 范围：pinned RustDesk 1.4.9 永久密码 verifier、持久化、认证、失败策略与 FarPane Host command 边界
- 网络：本步骤未连接 Hermes，未修改服务端
- 密钥：未读取、未输出、未写入
- ABI/schema：本步骤未修改 Host C ABI、HostSnapshot 或 wire schema

## Outcome

pinned core 已具备 verifier-first 的永久密码存储和真实认证链，FarPane 不应另建 Viewer Keychain 明文旁路：

1. `compute_permanent_password_h1` 计算 32-byte `SHA256(password || salt)`；新本地密码使用 32 字符 salt。
2. H1 先编码为版本化 hash storage，再以当前机器材料派生的 secretbox key 和随机 nonce 封装为 `01...` storage；普通配置只持久化 verifier storage 与 salt，不持久化可恢复密码明文。
3. 服务端收到 challenge response 后，从 storage 解出 H1，计算 `SHA256(H1 || challenge)`，并用 sodium constant-time comparison 校验。
4. 更新/清除永久密码会清除 trusted devices，避免旧信任绕过新密码状态。
5. 默认登录失败表同时按 IP 和 IPv6 `/64`、`/56`、`/48` 聚合；同一分钟超过 6 次会拒绝一分钟，累计超过 30 次会拒绝并审计。临时密码另在连续 10 次错误后轮换。

上述链证明 verifier-first 可复用，但还不能直接从 FarPane App 设置永久密码：当前 `rdn_host_command` 使用 JSON bytes，Swift `JSONSerialization` 与 Rust `serde_json::Value` 都会产生不可可靠清零的复制；把永久密码作为 JSON payload 会违反 §8.1/§9.3。

## H3.1a safety foundation

新增 `HostCommandEnvelopePolicy` 并接入 `HostControlClient.command`：

- generic JSON channel 明确拒绝 `setPermanentPassword`，要求未来使用 dedicated secret-buffer ABI；
- 递归拒绝 key 名含 password/passcode/credential/secret/token/private-key/recovery-key 的 payload；
- 拒绝 `Data`/`NSData` opaque binary material；
- 拒绝顶层 payload 覆盖 `name` 或 `commandId`；嵌套 capability 的普通 `name` 保持允许；
- 错误只返回稳定分类，不回显 command payload 或秘密。

`clearPermanentPassword` 不携带秘密，因此空 payload 仍可经过 generic channel；本步骤没有新增 Rust command，避免在 snapshot/result contract 未确定时制造半条链。

## Fresh automated verification

定向 CoreBridge test 验证：

- `setApprovalMode` 的嵌套 capability payload 可序列化，顶层 canonical name/commandId 由 policy 写入；
- 空 payload `clearPermanentPassword` 保持允许；
- 顶层/嵌套敏感 key、opaque Data、保留字段覆盖全部 fail closed；
- `setPermanentPassword` 即使 payload 为空也必须得到 dedicated-ABI error，错误文本不包含测试 secret。

第一次定向运行发现嵌套 capability `name` 被误判为顶层保留字段；实现收敛为只在顶层拒绝覆盖后，定向测试通过。该失败没有被隐藏或通过放宽敏感字段规则规避。

最终 fresh verification：

- `swift test --filter CoreBridgeContractTests/testHostJSONCommandEnvelopeRejectsSensitiveAndReservedPayloads`：1 项通过，0 failure；
- `swift test`：105 项执行，0 failure，4 项因未设置 `RDN_CORE_LIBRARY` 按条件跳过；
- `swift build -c release --product RustDeskNative`：production build 与链接通过；
- `git diff --check`、vendored Rust diff check、patch reverse-check 与 bridge mirror comparison：全部通过；
- 本步骤涉及文件的 PEM/长认证赋值扫描：无命中。

## Shared architecture checkpoint

H3.1 下一步需要显式修改共享 Host ABI/schema，不能在本 bounded step 擅自实施：

1. 新增 dedicated mutable-byte secret entrypoint，而不是 JSON command；调用者和 Rust 在返回前都清零 buffer，Rust 只借用 UTF-8 slice 计算 verifier，不把明文写入日志/event/snapshot。
2. Rust HostCore 在入口权威执行最大长度、最小强度、禁用修改策略；函数返回只表示 accepted，最终 set/clear 结果仍由 command-result event 给出。
3. HostSnapshot 增加只读 `permanentPasswordSet` 与更新时间，不包含 storage、salt 或明文，并进行 schema/version 演进。
4. 明确累计 `>30` 登录失败的恢复语义；当前 default failure table 有一分钟限流和 hard block，但 hard block 没有独立的有界 cooldown 合同。
5. built-core test 必须证明设置后真实 challenge auth 成功、旧密码失败、清除后失败、storage 无明文、trusted devices 清除、失败限流/冷却有效，并检查 caller/Rust buffer wipe。

## Boundary

- 本步骤没有设置、读取或保存任何真实永久密码。
- 没有复用 Viewer 的 `KeychainDeviceCredentialStore`；它保存的是 outbound device credential，不是 Host verifier authority。
- H3.1 尚未完成；当前只证明权威链选择并封住不安全 JSON transport。
