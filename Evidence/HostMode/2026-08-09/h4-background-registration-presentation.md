# H4.2u background registration presentation

## Outcome

AppDelegate 已惰性组合真实 migration closure、registration sheet driver 与 typed Home presentation，但没有任何 `begin` 调用点。当前产品运行不会因构造而弹窗、停止旧 Host、注册后台组件或打开系统设置。

## Key evidence

- CoreBridge presentation policy 对每个 UX phase 做穷尽 typed 映射，输出有界 `statusText`、`errorText`、tone、busy 与 retry 状态。
- persistence 确认与 Login Items 系统审批明确区分；preparing、registering、navigating 均只报告进行中。
- active session、pending approval 与其他残留 ownership 保留不同可操作文案；migration evidence unavailable、inconsistent 与 stop failure 也保持独立脱敏语义。
- registration 成功只报告“后台组件已注册”，不会宣称 Agent ready 或“可被连接”；服务、签名/构建和内部矛盾失败不透传底层 Error、路径或身份数据。
- AppDelegate 惰性 driver 使用真实 MainActor migration preparation；off-main/self 释放统一返回 evidence unavailable。
- Home 只接收可选 presentation 覆盖层；driver 尚未开始时该值为 nil，旧 Host 状态与错误合成保持原行为。
- AppDelegate 与 Home 均没有调用 `hostAgentBackgroundRegistrationSheetDriver.begin`，测试也未执行 product mutation 或 GUI 操作。

## TDD evidence

只新增测试时按预期编译失败：presentation 类型与 policy 尚不存在。实现后 presentation focused 8 tests、sheet-driver focused 3 tests、legacy product adapter focused 7 tests 均为 0 failures。

## Verification

- `swift test --filter HostAgentBackgroundRegistrationPresentationPolicyTests`：8 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationSheetDriverTests`：3 tests，0 failures。
- `swift test --filter HostAgentLegacyHostProductEvidencePolicyTests`：7 tests，0 failures。
- `swift test`：576 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --cached --check`：成功。
- scoped added-line secret scan：无匹配。

## Remaining boundary

后台注册 flow 仍没有显式产品入口，legacy Home Host switch 继续直接控制进程内 HostCore。下一步需定义并接入单一用户 intent，使启用路径调用 sheet driver、迁移并注册，同时避免旧 Host 自动启动与双 owner；真实 SMAppService 注册、Login Items 审批、Agent 启动和退出 App 后继续连接仍需 Mini 真机验收。
