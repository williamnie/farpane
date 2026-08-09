# H4.2aa authoritative background Home snapshot projection

## Outcome

Home 现在可以从 App 侧同一 background runtime 的权威 H4.3 projection 展示 local ID 和永久密码策略，不再在 background ownership 下混用 legacy `hostSnapshot`。暂时密码仍为 redacted；尚无 XPC command/presentation 边界的审批、会话和媒体字段明确清空，不显示无效的 legacy 动作。

## Key evidence

- `HostAgentBackgroundActivationRuntime` 新增只读 `projectionSnapshot()`；product composition 返回其已有 `projectionAuthority.snapshot()`，不建立第二份 snapshot authority。
- activation owner 在 initial monitoring 和每次 readiness publication 同时取得 projection，只保留 generation 与完整 runtime evidence 精确一致的 view。非空不一致触发 `.invalidHealthSequence`，cancel runtime 并撤销 projection。
- test seam 的 runtime 可以没有 projection，但 Home policy 对 nil 固定 fail closed；产品 factory 则始终使用同一 composition 的 health/projection authorities。
- pure Home projection policy 同时要求 monitoring、health 无 failure、registration enabled、matching generation/evidence 和 `.available` typed payload。任一不满足都返回全空 unavailable presentation。
- 可发布字段只有 local ID、password policy 四个布尔值和 last-error presence；不保留 raw JSON、temporary password、underlying error、peer/process identity 或 path。
- Rendezvous degraded/offline 不会丢弃已验证 snapshot，因而 Home 可继续显示 ID/密码策略；ready 仍由 H4.2z 的四证据独立决定。
- App 仅在 `usesLegacyHost` 时读取 legacy ID/password/approval/session/media/error。background ownership 下 pending approval、active session 和 media diagnostic 明确为 nil/empty，避免与 legacy callback 混用。
- background payload 的 `lastError` 只映射为固定用户文案，不展示 wire 文本。

## TDD evidence

只新增测试时，focused build 先因 Home snapshot presentation/policy 不存在而 RED；测试 fixture 中 `String?`/`NSNull` 的静态类型错误另行修正后，产品类型缺失仍保持 RED。完成 pure policy、activation projection 传递和 App 隔离后，状态矩阵通过；source boundary 曾因测试只接受“直接在参数中调用”的格式而剩余 1 条 RED，改为同时对账 initial/current 两次 runtime readback 与两个 coherent publication 后全绿，产品逻辑未放宽。

## Verification

- `swift test --filter HostAgentBackgroundHomeSnapshotProjectionPolicyTests`：4 tests，0 failures。
- `swift test --filter 'HostAgentBackground(HomeSnapshotProjectionPolicy|ActivationOwner)Tests'`：18 tests，0 failures。
- `swift test --filter 'HostAgentBackground(HomeSnapshotProjectionPolicy|HomeReadinessPresentationPolicy|ActivationOwner|ProjectionAuthority|HealthAuthority|HomeRoutingPolicy|ProductRoutingPolicy|ReadinessPolicy)Tests'`：65 tests，0 failures。
- `swift test`：616 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：23 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --cached --check`：提交前执行。
- scoped added-line secret scan：提交前执行。

## Remaining boundary

background pending approval 和 active session 已存在于权威 wire payload，但 Home 暂时不呈现，因为现有按钮只连接 legacy callbacks。下一步 H4.2ab 应建立 background 只读 approval/session presentation 和独立 command-availability 字段，在 typed XPC command surface 落地前显示状态但禁用所有动作。media diagnostics 不在当前 snapshot contract 中，仍需后续独立的权威来源；本步未增加 wire selector/schema/Host ABI。
