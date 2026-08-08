# H3.4ae Native Host platform-authority recovery state

- 日期：2026-08-08
- 范围：pinned RustDesk `server/connection.rs`、`server/input_service.rs` 与 canonical patch
- 结论：运行中的 Native Host Remote 会话已把 active Aqua 暂时不可用和 Accessibility TCC 撤权拆成两类状态；只有前者可在同一会话安全恢复，后者会锁存拒绝并禁止自动升权

## Root cause

H3.4ad 将 Accessibility 与 active Aqua 合成一个布尔值，并在任一条件失败时单向撤销控制。这保证了 fail closed，但无法满足两条同时存在的产品边界：锁屏或 Fast User Switching 后回到同一 Aqua 会话应能恢复；Accessibility 被用户撤销后，即使系统开关重新变为 trusted，也不能在旧远端会话内自动恢复高权限。

最终 adapter 的逐事件 gate 已经能立即拒绝两类失效；缺口位于 connection lifecycle：它需要记住撤销原因和是否曾经具备有效控制，同时继续复用既有 permission epoch、ordered cleanup、Viewer permission 与 active capability authority。

## Implementation

1. 平台查询现以独立 `(accessibilityTrusted, activeAquaSession)` observation 暴露给 crate 内部；原合并 gate 保持等价，非 Native Host 仍返回 permissive observation。
2. connection-local `NativeHostPlatformInputState` 记录 local configured intent、当前 effective control、TCC latch 和 Aqua restore arm，不修改 Host ABI、snapshot 或 wire。
3. 已有效会话遇到 Aqua unavailable 时切为 false 并 arm restore；同一 observation 后续恢复 active 时才切回 true。初始就在锁屏/off-console 状态的连接不会凭 unlock 自动新增控制能力。
4. 任意时刻观察到 Accessibility untrusted 都会清除 restore arm 并锁存拒绝；后续 trusted + active observation 不会恢复。只有新的显式本机 keyboard permission enable 且实时 TCC trusted 才能清除 latch。
5. false/true transition 都沿现有 connection authority 收敛：false 旋转 permission epoch 并排入 ordered `Release`；true 生成新 permission generation。两者同步 Rust active capabilities、Viewer permission 与 clipboard/cursor subscription；最终 adapter 继续逐事件复查平台 authority。

## Red-green evidence

- RED：先加入 Aqua recovery、TCC latch、显式重新启用、初始 locked 和显式关闭矩阵；定向 Rust target 因缺少 `NativeHostPlatformInputState` 以 2 个 `E0433` 失败。
- GREEN：同一定向 target 1/1 通过；完整 Rust lib 131/131 通过。
- 测试明确覆盖 `effective -> Aqua unavailable -> same Aqua active` 的 false/true transition，以及 active/locked 两种 TCC revoke 后重新 trusted 仍保持 false。

## Verification

- `cargo test --features rdn-native-core,rdn-native-host --lib`：131 passed，0 failed。
- `Scripts/build-rust-core.sh`：release arm64 dylib 重建成功；产物为 arm64 Mach-O，embedded ad-hoc signature 通过 `codesign --verify`。
- 将同一稳定 dylib 复制到全新 inode 后执行 built-core `swift test --quiet`：133 passed，0 failed；真实 Viewer ABI、Host ABI v6 与 Host lifecycle 均执行。
- `python3 -m unittest discover -s Tests/ScriptTests`：20 passed，0 failed。
- `swift build -c release --arch arm64`：success。
- canonical patch 在 clean pinned `6c578292e8ebbbec708b76986ba8c4bc7c509747` checkout 回放，16 个 patch 文件逐一与当前 Vendor 一致；`git diff --check` 通过。

验证期间发现一个独立构建工具问题：`build-rust-core.sh` 用 `cp` 原地覆盖既有 dylib inode 时，macOS kernel 可能仍持有旧 linker-signature cache，导致紧接着的 `dlopen` 被 `SIGKILL (Code Signature Invalid)`；同一文件 `codesign --verify` 通过，复制到新 inode 后全部 133 项通过。该脚本应在下一独立步骤改为原子发布，不能把这次竞态误判为 ABI 回归。

## Scope and remaining boundary

- 未修改 Host ABI/snapshot/event/media schema、protobuf、Hermes、CI、根依赖、数据库或 TCC 数据库；未请求权限、未安装、未 push。
- snapshot 仍只能通过 `controlKeyboardMouse` capability 表达 effective 状态，尚无 `limited/sessionUnavailable` 原因；锁屏、LoginWindow、off-console 和 TCC UI 无法在产品界面中区分。
- 锁屏/解锁、Fast User Switching、TCC revoke/regrant、transition cleanup 与 Secure Input 仍需 Mini 真机证据。系统 session identity 变化目前只由 `is_active_aqua_session()` 的 current-process Aqua authority 约束。
