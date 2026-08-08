# H4.2v background unregistration UX

## Outcome

后台注册与取消注册现在可共享 App 唯一的 ServiceManagement mutation authority；新增显式关闭后台连接的 typed UX，满足说明、确认、权威 readback 与 fail-closed 要求。该流程尚未接 AppKit 或 Home 开关，构造和测试均无真实系统副作用。

## Key evidence

- registration product factory 不再内部创建 mutation owner；AppDelegate 惰性持有唯一 product owner，并显式注入 registration sheet driver。
- unregistration prompt 明确“停止后台组件、不再接受新的远程连接”，同时说明设备身份和服务器配置会保留。
- 未先 request 的 confirm、取消、错序、并发和 observer 重入均不会触发 unregistration operation。
- 确认后先发布 `unregistering`；只有 operation accepted、mutation phase 为 `unregistered` 且 registration readback 精确为 `notRegistered` 才发布成功。
- service unavailable 与 unregistration-not-effective 保留 typed failure；accepted/phase/intent/status 任一矛盾统一 `invalidMutationResult`。
- 共享 mutation authority 的并发测试让 registration 阻塞在途，再确认 unregistration；opposing intent 被 owner 拒绝且 unregister 调用计数保持 0。
- CoreBridge owner 不引用 AppKit、UserDefaults、HostControlClient 或 SMAppService；产品 mutation 仍只存在于既有固定 owner。

## TDD evidence

只新增测试时按预期编译失败：unregistration intent/prompt/phase/view/owner 尚不存在，registration product factory 也不接受 caller-owned mutation authority。实现后 unregistration focused 8 tests、registration UX focused 17 tests、sheet focused 3 tests、presentation focused 8 tests 均为 0 failures。

## Verification

- `swift test --filter HostAgentBackgroundUnregistrationUXOwnerTests`：8 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationUXOwnerTests`：17 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationSheetDriverTests`：3 tests，0 failures。
- `swift test --filter HostAgentBackgroundRegistrationPresentationPolicyTests`：8 tests，0 failures。
- `swift test`：584 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --cached --check`：成功。
- scoped added-line secret scan：无匹配。

## Remaining boundary

关闭流程还没有 AppKit sheet driver 或产品 presentation，Home Host switch 仍控制 legacy in-process Host。下一步建立 retry-safe unregistration sheet/presentation，并保持没有默认自动调用；之后才能把同一显式产品开关安全路由到 registration/unregistration 与 App-side background activation，真实 Mini 验收留待可用设备。
