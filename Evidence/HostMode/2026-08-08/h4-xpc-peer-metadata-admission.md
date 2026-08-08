# H4.2j XPC peer metadata admission

## Outcome

CoreBridge 现在有一个 package-scoped XPC peer metadata admission gate。产品入口只接受 listener delegate 交付的真实 `NSXPCConnection`，先验证内核提供的 PID/euid/audit-session 属性，再按 PID 查询实际 executable path；任一证据缺失或不一致都会在 exported interface 存在前 fail closed。

## Key evidence

- 产品入口不接受 PID、uid、ASID、path 或 environment override，只读取 `NSXPCConnection.processIdentifier`、`effectiveUserIdentifier` 和 `auditSessionIdentifier`。
- PID 必须大于 1 且不能等于 Agent 自身 PID；无效 PID 与 self-connection 在任何 path lookup 前拒绝。
- peer euid 必须精确等于 Agent 的 `geteuid()`；peer/local ASID 都必须有效且相等。Agent 自身 ASID 由公开 `getaudit_addr` 获取，不使用 shell/session 环境猜测。
- 本机只读 probe 中，当前 Aqua launchd domain handle 与 `getaudit_addr` 的 ASID 一致；该策略用于拒绝同 euid 但来自 SSH/其他 login domain 的 peer。SMAppService 真 Agent 的同-ASID 仍需后续运行态验收，未据此激活 listener。
- executable 只由 `proc_pidpath` 按已验证 PID 查询，使用固定 4 KiB 上限并要求绝对、有效 UTF-8 路径；reported path 与 symlink-resolved path 必须同时精确等于 `/Applications/FarPane.app/Contents/MacOS/RustDeskNative`。
- admission 顺序固定为 PID → euid → audit session → executable，前序失败不会执行后续路径解析；返回值只有稳定脱敏状态，不携带 peer path、PID 或底层 errno。
- H4.2i 的 listener-level code-signing requirement 仍是 delegate 前的独立第一道门，本步不能单独替代签名校验。当前也没有 listener delegate/runtime、interface、selector、handshake、snapshot 或 command。
- 未创建/打包 plist，未调用 ServiceManagement mutation，未启用 HostAgent 入口，未修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：7 个 admission tests 先因 gate/status/executable identity 不存在而按预期编译失败。
- 定向 admission：7 tests，0 failures；覆盖成功顺序、无效/self PID、不同 euid、无效/不同 ASID、path lookup 失败、迁移路径、symlink drift、近似 executable 名，以及真实 `getaudit_addr`/`proc_pidpath` resolver。
- `swift test`：327 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一安全小步是受控 listener delegate shell：必须由 H4.2i 配置过 signing requirement 的 listener 持有，在 metadata admission 通过后才允许未来 typed interface configurator 运行；在 wire interface 尚未定义前仍应拒绝连接并保持 listener 未激活。设计要求的 raw audit-token 绑定、PID reuse/peer lifetime 以及真实 SMAppService Agent/App session 关系仍需在 delegate/runtime 与真机构建中继续证明。
