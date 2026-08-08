# H3.4ad Native Host platform-authority transition revoke

- 日期：2026-08-08
- 范围：pinned RustDesk `server/connection.rs` 与 canonical patch
- 结论：活动 Native Host Remote 会话现在会在 connection timer 上复查既有 Accessibility + active Aqua authority；authority 丢失后单向撤销 keyboard/mouse capability，并复用 permission epoch 与 ordered cleanup 收敛会话状态

## Root cause

H3.4g/h 已让 connection 创建、本机 permission switch 和最终 macOS adapter 查询 Accessibility 与 active Aqua session。最终 adapter 能立即拒绝撤权/锁屏后的新输入，但运行中的 connection 仍保留 `keyboard=true`：permission epoch 不旋转、已按下状态不主动 cleanup、Viewer 与 HostSnapshot 也继续显示 `controlKeyboardMouse`。

因此 adapter 的真实拒绝状态与 connection/broker/UI authority 会漂移。仅靠下一次输入 fail closed 也不能触发 release marker，无法满足 transition cleanup 边界。

## Implementation

1. 复用 connection 现有一秒 timer；只对 `authorized && Remote && keyboard` 的 Native Host 路径查询 `native_host_platform_input_permission_allows(true)`。非 Native Host、移动端、未认证/非 Remote 或已撤权会话不新增平台查询。
2. policy 只有 `enabled + platform denied -> Some(false)` 一条 transition。平台恢复时不会在同一会话自动升权，符合权限变化后不自动恢复高权限会话的安全要求。
3. transition 先将 `keyboard=false`，再调用既有 `sync_effective_input_permission()`：旋转 connection epoch、拒绝排队旧 generation，并把 `Release` marker 排入同一 input queue。
4. 同步 native active capabilities 后，现有 HostSnapshot 会移除 `controlKeyboardMouse`；同时向 Viewer 发送 keyboard permission=false，并按新状态更新 clipboard/cursor subscription。
5. 最终 adapter 的逐事件 gate 保持，因此 timer tick 前的新输入仍会立即 fail closed；本步没有把周期同步当作第一道安全门。

## Red-green evidence

- RED：先加入 revoke-only 四象限测试，Rust test target 以四个 `E0425` 失败，证明 policy 尚不存在。
- GREEN：`native_host_platform_input_transition_is_revoke_only` 1/1，通过 enabled/allowed、enabled/denied、disabled/denied 与 disabled/recovered；最后一项明确禁止自动恢复。
- 完整 Rust lib 131/131 通过，覆盖 permission epoch、ordered release、single-active lease、active-session broker、approval、媒体与 Viewer bridge 回归。

## Verification

- 定向 Rust policy：1 passed，0 failed。
- 完整 Rust lib：131 passed，0 failed。
- `Scripts/build-rust-core.sh`：release arm64 dylib 构建成功。
- 加载新 ABI v6 core 的 `swift test --quiet`：133 passed，0 failed；built-core Host lifecycle/ABI 与 loader smoke 均通过。
- `python3 -m unittest discover -s Tests/ScriptTests`：20 passed，0 failed。
- `swift build -c release --arch arm64`：success。
- canonical patch reverse-check 与 bootstrap：通过；clean pinned replay 16 个 tracked 文件逐一一致。
- `git diff --check`：通过；secret-shaped diff scan：0 matches。

## Scope and remaining boundary

- 未修改 Host ABI/snapshot/event/media schema、protobuf/wire、Hermes、CI、根依赖、数据库或 TCC 数据库；未请求权限、未安装、未 push。
- 本步只通过现有 active capability 表达“控制已撤销”，没有新增 `limited/sessionUnavailable` 原因字段。Home 与 Viewer 会看到控制能力消失，但无法区分 Accessibility、锁屏、off-console 或未知平台查询。
- Accessibility 已撤销后系统是否接受 cleanup 的真实 key/button release、锁屏/Fast User Switching transition、timer 查询成本仍需 Mini 真机验证。
- revoke-only 意味着同一会话不会因平台 authority 恢复而自动重新获得控制；active Aqua 解锁恢复与 TCC 明确再授权必须先拆分 authority/latch 语义，作为下一独立状态机步骤。
