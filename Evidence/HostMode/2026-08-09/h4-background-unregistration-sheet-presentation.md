# H4.2w background unregistration sheet and presentation

## Outcome

显式关闭后台连接现具备 retry-safe AppKit single-sheet driver 与 typed Home presentation；registration sheet 的永久 one-shot 限制也已修正为顺序重试。AppDelegate 只做惰性组合，尚无 `begin` 调用点，未产生真实 GUI 或系统注册副作用。

## Key evidence

- pure response policy 只按显式肯定/取消结果产生 matching unregistration intent，不由文案或按钮序号驱动业务状态。
- warning sheet 原样使用 typed title/message/confirm/cancel；每次 callback 对账 private token、UX generation 和完整 prompt。
- registration/unregistration driver 同时只允许一个在途 attempt，终态后可顺序 retry；迟到 callback 不能进入新 attempt。
- finish 在开放下一次 begin 前先捕获并清除旧 completion；`onUpdate` 或 completion 重入不会误清新 completion。
- presentation 明确区分等待确认、正在关闭、已关闭、已取消、service unavailable、仍注册与内部矛盾；错误文案均有界且不透传底层 Error。
- AppDelegate 惰性强持有 unregistration driver，并注入 H4.2v 的同一个 mutation owner；registration/unregistration presentation 更新会清除 opposite stale overlay。
- AppDelegate/Home 均没有 registration 或 unregistration driver 的 `begin` 调用；测试未运行 AppKit sheet 或 product mutation。

## TDD evidence

只新增测试时按预期编译失败：unregistration response/presentation 类型、AppKit driver、App composition 与 retry-safe registration lifecycle 尚不存在。实现后 unregistration presentation/driver focused 6 tests、registration sheet focused 3 tests、unregistration UX focused 8 tests、registration presentation focused 8 tests 均为 0 failures。

## Verification

- `swift test --filter HostAgentBackgroundUnregistrationPresentationPolicyTests`：6 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationSheetDriverTests`：3 tests，0 failures。
- `swift test --filter HostAgentBackgroundUnregistrationUXOwnerTests`：8 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationPresentationPolicyTests`：8 tests，0 failures。
- `swift test`：590 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --cached --check`：成功。
- scoped added-line secret scan：无匹配。

## Remaining boundary

Home Host switch 仍控制 legacy in-process Host；background registration/unregistration drivers 与 H4.3e4g activation owner 尚无产品 intent 调用点。下一步需建立一个 MainActor routing owner：enable 只开始 registration flow，权威注册终态后启动 background observation；disable 先确认 unregistration，成功后停止 observation；取消/失败需把 switch 恢复到权威状态，且不得恢复 legacy preference 或形成双 Host owner。
