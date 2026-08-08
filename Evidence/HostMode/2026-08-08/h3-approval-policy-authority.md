# H3.2a approval policy authority and compatibility boundary

- 日期：2026-08-08
- 范围：Host Mode §9.4 五种产品审批模式、无人值守约束、pinned RustDesk 1.4.9 approval authority
- 网络：未连接或修改 Hermes
- 密钥：未读取、未输出、未写入
- ABI/schema：未修改 Host C ABI、HostSnapshot、event schema 或 wire protocol

## Outcome

新增 `HostApprovalMode`、`HostLocalApprovalPath` 与 validated `HostApprovalPolicy`，把五种产品模式、本机审批发生阶段和独立无人值守开关固化为 canonical code contract：

| FarPane mode | password | local approval | unattended allowed | pinned upstream projection |
|---|---:|---:|---:|---|
| `manualOnly` | no | yes | no | `click` + `use-both-passwords` |
| `temporaryPassword` | yes | no | yes | `password` + `use-temporary-password` |
| `permanentPassword` | yes | no | yes | `password` + `use-permanent-password` |
| `passwordAndLocalApproval` | yes | mandatory after password | no | **not representable; fail closed** |
| `passwordOrLocalApproval` | yes | alternative | yes | `both` + `use-both-passwords` |

`HostApprovalPolicy` 不允许 `manualOnly` 或 `passwordAndLocalApproval` 与 unattended=true 形成有效值。unattended 仍是独立显式开关；模式本身不会暗中启用无人值守。

## Pinned authority evidence

`hbb_common::password_security` 的真实配置面只有：

- `ApproveMode::{Click, Password, Both}`，来自 `approve-mode=click/password/both`；
- `VerificationMethod::{OnlyUseTemporaryPassword, OnlyUsePermanentPassword, UseBothPasswords}`，来自 `verification-method`。

`Connection::handle_login_request` 的实际语义证明：

- `Click` 在认证前转交本机 Connection Manager；
- `Password` 的有效密码可直接进入 `send_logon_response_and_keep_alive`；一般 upstream CM 架构中空密码仍会尝试 `try_start_cm`，所以 config 本身不能证明 password-only；
- `Both` 在有有效密码时允许密码，也在空密码时转交本机审批，因此是 OR，不是 password 后再 click；
- `passwordAndLocalApproval` 不能通过组合现有 config 获得，必须在密码校验成功与 `self.authorized = true` 之间新增 native 两阶段 gate。

## Native Host gap

FarPane H1 为避免启动旧 Connection Manager，已让 `connection_manager_required_for_native_host(true)` 返回 false。此时 `try_start_cm(...)` 是 no-op。因此当前：

- 密码成功路径仍能进入 authenticated session；空密码的 legacy CM fallback 因 receiver 不存在而不会授权；
- `manualOnly`、`passwordOrLocalApproval` 的 local alternative，以及未来 `passwordAndLocalApproval` 都没有 native pending-request receiver；
- 仅写入 `approve-mode=click/both` 会使连接停在无接收者的本机批准路径，不能算功能实现。

该发现解释了 H3.2 后续必须同时改 Rust connection authorization hook 与 Host event/command/snapshot contract，而不能先做一个只改 Swift UI 的假审批弹窗。

## H3.2a safety foundation

- 五个 wire value 固定为设计文档中的 canonical 名称；
- 精确 upstream config projection 是 package-only compatibility description，不在 Swift 直接写 Rust config，也不把 config projection 冒充完整 authorization behavior；
- `HostLocalApprovalPath` 将 local decision 固定为 prohibited / primary / required-after-password / alternative-to-password，后续 native broker 必须按此路由；
- `passwordAndLocalApproval` projection 抛出稳定 `nativeTwoStageGateRequired`，不会降级成 OR 或纯 password；
- 本机用户不在场时必需本机点击的模式拒绝 unattended；
- error 不包含密码、远端 metadata 或 server material。

## Verification

定向 `HostApprovalPolicyTests` 覆盖：

- 五种模式的 password/local/AND 语义；
- 所有模式的 unattended allow/reject 矩阵；
- 四种可表达模式的精确 upstream option projection；
- `passwordAndLocalApproval` fail closed；
- 五种 canonical wire value JSON round-trip。

最终 fresh verification：

- `swift test --filter HostApprovalPolicyTests`：4 项执行，0 failure；
- `swift test`：109 项执行，0 failure，4 项因未设置 `RDN_CORE_LIBRARY` 按条件跳过；
- `swift build -c release --product RustDeskNative`：production build 与链接通过；
- diff/空白、文档路径、vendored patch consistency 与秘密扫描随本步骤收口检查。

## Next shared checkpoint

H3.2b 需要共享 Rust/Host event-command-snapshot 合同：

1. 在 Rust connection login lifecycle 建立 native approval broker，而不是恢复旧 CM process；
2. pending request 使用 canonical connectionId、单调 deadline、requested capabilities、auth method 与脱敏/untrusted display metadata；
3. 同 connectionId 只接受一次最终 approve/reject，过期 approve fail closed；
4. 同时只允许一个 pending/active control session，其余明确 busy/reject；
5. `passwordAndLocalApproval` 只有 password 验证成功后才生成 pending request，最终本机 approve 后才设置 authorized；
6. pending/active 状态进入 HostSnapshot，App 重建后 snapshot-first 恢复；
7. decision command/result 与事件全部有大小、频率、epoch 和去重边界；认证失败通知聚合限流。

H3.2 尚未完成；本步骤只关闭产品模式语义与 upstream 兼容边界。
