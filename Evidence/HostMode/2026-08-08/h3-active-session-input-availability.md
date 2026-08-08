# H3.4af active-session input availability authority

- 日期：2026-08-08
- 范围：运行中 Native Host Remote 会话的键鼠可用性原因、Host snapshot/event、Swift strict decoder 与产品呈现
- 结论：现有 connection-level Accessibility/Aqua/local/remote authority 已能通过同一 Rust session broker 如实投影到 snapshot 和 UI；这不是完整 H5.2 后台 `hostAvailability`，也没有决定 Secure Input 策略

## Contract

1. Host Control ABI 从 v6 升至 v7，HostSnapshot schema 从 v4 升至 v5；Host event schema 与 Host Media ABI 继续保持 v1。
2. active session 新增必需字段 `inputAvailability` 与 `inputUnavailableReason`。唯一合法组合为：
   - `available + null`，且 active capabilities 必须包含 `controlKeyboardMouse`；
   - `disabled + localPolicyDisabled|remoteDisabled`，且 active capabilities 不得包含控制能力；
   - `limited + accessibilityDenied|sessionUnavailable`，且 active capabilities 不得包含控制能力。
3. Rust broker 同时比较 capability 与 availability；即使 capability 已经为 false，原因从 Aqua unavailable 变成 Accessibility denied 仍会生成新的 authoritative snapshot/event。
4. connection 继续是原因 authority：本机明确关闭映射为 `localPolicyDisabled`，控制端关闭映射为 `remoteDisabled`，TCC latch 映射为 `accessibilityDenied`，当前 Aqua/LoginWindow/off-console 不可用映射为 `sessionUnavailable`。
5. Swift decoder 要求精确字段、固定枚举和能力/原因一致性；未知 status/reason、旧 schema、available 但没有控制能力、disabled/limited 原因类别交叉均拒绝整个 snapshot。

## Product presentation

- `limited/sessionUnavailable` 显示“远程会话受限：当前 Mac 会话不可用”，Home 会话卡明确提示锁屏、登录窗口或其他用户会话，菜单栏标题改为“FarPane 远程会话受限”。
- `limited/accessibilityDenied` 明确提示辅助功能权限不可用；不会把媒体仍在运行冒充为键鼠可用。
- local/remote policy disable 继续显示会话进行中，同时在会话卡解释键鼠由哪一侧停用。
- UI 只消费成功解码的 snapshot presentation policy，不从缺失 capability 猜测原因。

## Red-green evidence

- Swift RED：schema-v5 active-session 文档被旧 schema-v4 decoder 以 `snapshot contract is missing or invalid` 拒绝。
- Rust RED：lifecycle snapshot test 在实际 schema 4、期望 schema 5 处失败。
- presentation RED：新 availability presentation API 尚不存在，测试按预期编译失败。
- GREEN：定向 snapshot decoder 1/1、presentation/lifecycle policy 4/4、Rust session lifecycle 1/1 通过；随后完成完整验证。

## Verification

- `cargo test --manifest-path Vendor/rustdesk/Cargo.toml --features rdn-native-core,rdn-native-host --lib`：131 passed，0 failed。
- `Scripts/build-rust-core.sh`：arm64 release core 重建成功，Mach-O/symbol/publication checks 通过。
- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test --quiet`：134 passed，0 skipped，0 failed；Host ABI v7、snapshot schema v5 与完整 lifecycle 3/3 实际加载新 core 执行。
- `python3 -m unittest discover -s Tests/ScriptTests`：21 passed，0 failed。
- `swift build -c release --arch arm64`：success。
- canonical patch reverse-check、tracked Host bridge mirror、`git diff --check` 与 clean pinned replay 通过；16 个 patched files（忽略既有空行行尾空白）及 2 个 bridge source 一致。
- 历史退出复核：12:18 crash report 来自 build `20260808120005`，堆栈对应已在 12:30 提交修复的 H.265 frame-context 重复释放；当前安装包为 13:10 build，12:18 后无新 FarPane crash report。本轮 fresh 2,000-frame HEVC pressure test 1/1 通过，但仍需以后新包真机会话确认无复现。

## Security and remaining boundary

- snapshot/event 不含服务器、公钥、密码、认证 payload、输入内容、坐标、画面、剪贴板内容或原始 TCC 数据。
- 未修改 protobuf、Hermes、CI、根依赖、数据库、TCC 数据库或密钥；新 core/App 未安装、未部署、未 push。
- 本步只完成运行中 in-process active-session 的键鼠原因链。锁屏时媒体采集 pause/bounded recovery、后台 Agent 顶层 `hostAvailability`、launchd/LoginWindow readiness 仍属于 H4/H5.2。
- Secure Input 的“仅暂停按键、暂停全部控制或系统决定”仍未冻结；没有借本次 reason enum 擅自选择策略。
- 锁屏/解锁、Fast User Switching、TCC revoke/regrant 与 UI 仍需 Mini 真机验证。

## Next step

在不需要控制端的前提下，继续审计并实现 H3/H5 中可自动完成的 active-session media pause/recovery 边界；若需要决定 Secure Input 粒度则停在架构检查点等待用户选择。
