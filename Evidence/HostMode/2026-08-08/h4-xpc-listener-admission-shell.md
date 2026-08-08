# H4.2k fail-closed XPC listener admission shell

## Outcome

CoreBridge 现在有一个未激活的 HostAgent XPC listener admission shell，把 H4.2i 固定签名 listener 与 H4.2j peer metadata gate 绑定在同一 owner 中。由于 typed/versioned wire interface 尚未定义，即使 peer identity 合格，delegate 也固定返回 false；当前不存在提前开放的本地 IPC surface。

## Key evidence

- product shell 只能通过 `HostAgentXPCListenerFactory.makeListener()` 创建所持 listener，并把自己设置为 weak delegate；Mach service name 和 listener-level code-signing requirement 继续由 H4.2i 单一 authority 决定。
- delegate 只处理自己强持有的 listener；foreign listener invocation 在读取 connection metadata 前拒绝。
- owned-listener attempt 先调用 H4.2j 产品 admission。所有非 eligible 状态拒绝；eligible 也因 typed interface unavailable 拒绝，没有 fallback interface、selector 或 exported object。
- shell 不暴露 listener，也没有 `activate`、`resume`、interface configurator 或 accept callback；本步不可能开始接收 Mach-service 请求。
- component snapshot 只含 connection attempt、peer-identity rejection、interface-unavailable rejection 三个 `UInt64` saturating count；NSLock 保护并发读取/更新，不保存 PID、uid、ASID、path、签名信息或底层 Error。
- tests 使用 anonymous listener 和 synthetic connection 仅驱动注入的纯 admission result；product shell 仍只使用固定 Mach-service listener 与真实 connection gate，不存在 anonymous fallback。
- 本步没有定义 wire version/message/payload/request ID，没有 handshake/snapshot/command/dedupe/rate limit，也没有启用 HostAgent 入口或把 XPC 可构造冒充 ready。
- 未创建/打包 plist，未调用 ServiceManagement mutation，未修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：shell tests 先因 admission shell/snapshot 不存在而按预期编译失败。
- 定向 shell：5 tests，0 failures；覆盖 product zero snapshot、全部 identity rejection、eligible-interface-unavailable、foreign listener short-circuit 和源码无 activation/wire surface。
- 完整 `swift test`：332 tests，4 skipped，0 failures。
- ScriptTests：22 tests，0 failures。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步进入 H4.3 wire handshake 前必须先冻结最小 typed/versioned interface：只允许 component-version exchange 与初始 snapshot request，设置严格 payload/identifier 上限，并在 snapshot-first 完成前拒绝 Host command。该步骤会形成共享 App↔Agent contract，需独立边界、兼容矩阵与更高验证，不能在本 shell 中用任意 closure/selector 代替。
