# H3.4i macOS Secure Input authority audit

- 日期：2026-08-08
- 范围：macOS SDK authority、pinned RustDesk key adapter、Native Host capability/status contract
- 结论：Secure Input 有可调用的系统 authority，但当前产品策略与状态合同不足以无歧义实现；本步只固化检查点，不擅自改变密码框输入行为

## Authority evidence

本机 Xcode 26.3 SDK 的 `CarbonEventsCore.h` 声明 `IsSecureEventInputEnabled()` 自 macOS 10.3 可用，并明确：

- 返回是否由任意进程启用了 Secure Event Input，而不只当前进程；
- Secure Input 使键盘输入只到达当前 focus application，避免被其他 event monitor 监听；
- API 标注为 not thread safe。

FarPane 当前依赖的 pinned Enigo 已链接 `Carbon.framework`，因此不需要新增依赖或构建配置即可调用该 authority。本机只读 Swift probe 成功调用并返回 false，证明当前 SDK/运行时符号可用。

H3.4h 使用的 CGSession dictionary 在当前 unlocked 会话不包含 `kCGSSessionSecureInputPID`；该 key 也未在本机公开 SDK header 中形成可依赖合同，不能用缺失/非零 PID 猜测产品状态。

## Input-chain audit

- macOS key 的最终执行发生在 `input_service.rs` 的串行 main `QUEUE`，满足 not-thread-safe authority 的唯一安全接入位置。
- connection 创建和 permission switch 运行在 async connection context，不应直接调用该 Carbon API。
- Secure Input 是瞬时、keyboard-specific 状态；把它并入现有 `keyboard` connection capability 会同时关闭 mouse，并可能要求重新连接才能恢复，不符合当前能力模型。
- 只在最终 key adapter 静默拒绝虽然 fail closed，但 Viewer/UI 仍显示可输入，违反“如实降级”；且会让所有启用 Secure Input 的普通应用密码框无法通过 FarPane 输入。

## Required decision

继续实现前必须明确三者之一：

1. Secure Input active 时拒绝全部 remote key，允许 mouse，并在 Viewer/Host UI 显示 temporary limited；
2. 允许系统继续决定 synthetic key 是否可达，只记录诊断，不把 Secure Input 当 hard gate；
3. 会话暂停全部 controlKeyboardMouse，等待 Secure Input 结束后恢复。

方案 1/3 都需要 keyboard-specific runtime status、HostSnapshot/event 更新与 transition cleanup；方案 2 需要真机密码框和恶意 event-monitor 安全验收。当前 shared Host contract 禁止由 heartbeat 擅改，设计也没有选定策略。

## Verification

- SDK header readback：`IsSecureEventInputEnabled` 的 summary、any-process semantics、not-thread-safe 与 macOS 10.3+ availability 均已核对。
- runtime probe：`swift -e 'import Carbon; print(IsSecureEventInputEnabled())'` 成功，当前返回 false。
- CGSession readback：当前 dictionary 的 secure-input PID key 缺失，不能作为 authoritative false/true contract。
- pinned Enigo link audit：已有 `#[link(name = "Carbon", kind = "framework")]`。
- key adapter audit：Native Host key 最终 task 位于 macOS main queue；connection capability 路径不在该线程边界。
- 本步未修改 Rust/Swift runtime、canonical patch、依赖、protobuf、Host ABI/snapshot、Hermes、CI、数据库或凭据，因此不重复把上一阶段 build 冒充本步功能验证。

## Next step

Secure Input 标记为用户/架构检查点。后续 heartbeat 转向其他不依赖该决定的 H3 审计；用户回来后需要选择策略，并在 Mini/MBP 上用真实密码框、Secure Input on/off、撤权 cleanup 和 Viewer limited 状态验收。
