# H4.2z background readiness Home presentation

## Outcome

Home 已能从 background activation/readiness 的 typed 证据展示 Agent running 与 ready，不再用状态文案或单一 `isRunning` 同时代表进程存活、可被连接和本地命令可用。本步只接 readiness 与呈现，没有投影 XPC snapshot payload 内容，也没有启用后台命令。

## Key evidence

- pure presentation policy 只接受 `HostAgentBackgroundActivationPhase?` 和权威 registration，不读 AppKit、legacy Host snapshot 或字符串状态。
- `isRunning` 要求 registration enabled、handshake compatible 与 authoritative snapshot available；Rendezvous offline 可以 running 但绝不 ready。
- `isReady` 只对 H4.2a 的 `.ready` 成立，即 registration、handshake、snapshot 与 Rendezvous 四证据同时健康。registration 非 enabled 会先于任何 runtime signal 撤销 running/ready。
- 版本不兼容、runtime evidence 矛盾和 activation failure 只生成固定脱敏文案，不保留底层 error、PID、path 或身份信息。
- AppDelegate 保留最新 activation view，所有本地 `hostDisabled` 路径都先撤销该缓存，避免 observation 停止后 Home 继续显示旧 ready。
- `HostHomeSnapshot` 分离 `isRunning`、`isReady` 和 `allowsHostCommands`。绿色状态点只由 typed ready/streaming 决定，不再比较“可被连接”文案。
- 显示/更新临时密码与设置/清除永久密码四个 Home 控件只看 `allowsHostCommands`。background ready 不会误启用 legacy callback，因为 XPC command surface 尚未接通。

## TDD evidence

只新增测试时，focused build 按预期因 presentation type/policy 不存在而编译失败。pure policy 实现后状态矩阵通过，但 Home/App source integration 仍有 9 条 RED；完成 typed 字段、activation view 缓存、状态颜色与 command 权限接线后，新 focused 7 tests 全绿。测试 helper 一度构造了 H4.2a authority 会拒绝的不可能 runtime tuple，随后改为与生产 authority 约束一致的 coherent evidence，未放宽产品实现。

## Verification

- `swift test --filter HostAgentBackgroundHomeReadinessPresentationPolicyTests`：7 tests，0 failures。
- `swift test --filter 'HostAgentBackground(HomeRoutingPolicy|ProductRoutingPolicy|ActivationOwner|ReadinessPolicy|HealthAuthority)Tests'`：43 tests，0 failures。
- `swift test`：611 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --cached --check`：提交前执行。
- scoped added-line secret scan：提交前执行。

## Remaining boundary

readiness 已经是 Home running/ready 的唯一 background authority，但 local ID、password policy、pending approval、active session 和 media diagnostic 仍只有 legacy 字段。下一步应从 H4.3 已验证的 authoritative snapshot projection 建立独立 Home payload，并在 XPC command selector 定义前继续保持 background commands disabled。
