# H3.4h Native Host active Aqua session fail-closed

- 日期：2026-08-08
- 范围：pinned RustDesk `platform/macos.rs`、`server/connection.rs`、`server/input_service.rs` 与 canonical patch
- 结论：macOS Native Host 只在当前进程属于已登录、on-console、未锁定的 Aqua session 时开放或执行远程输入

## Root cause

V1 设计明确不支持锁屏、LoginWindow、无用户登录或 Fast User Switching 的非 active session。pinned macOS `is_prelogin()` 通过 `ls /dev/console` 取 uid，命令失败或输出异常会得到空字符串并返回 false；`is_locked()` 通过 `ioreg`，命令失败同样返回 false。它们既在错误时 fail open，也不适合放进高频 input adapter。

此前 Native Host 的 connection keyboard capability 和最终 macOS adapter 都不检查 active Aqua session；已认证连接在锁屏或切换用户后仍会把事件送往 Enigo/rdev，依赖系统是否拒绝。

## Red-green evidence

1. 先写 on-console/login-done/locked policy matrix；缺 helper 的初始编译 RED 后，以旧 allow-all 行为确认 behavioral RED：`locked=true` 仍被接受，0 passed / 1 failed。
2. 新查询直接使用已经由 CoreGraphics 链接的 `CGSessionCopyCurrentDictionary`，不启动外部进程、不增加依赖。`kCGSSessionOnConsoleKey=true`、`kCGSessionLoginDoneKey=true` 且 `CGSSessionScreenIsLocked=false` 才视为 active。
3. on-console/login-done 缺字段、非 CFBoolean 或 dictionary 获取失败全部 fail closed。Apple 的 unlocked dictionary 会省略 `CGSSessionScreenIsLocked`，仅该字段缺省按 false 处理；字段存在但类型异常仍 fail closed。
4. 当前开发机会话 readback 确认 on-console/login-done 是 CFBoolean true，unlocked 时 lock key 缺省，符合上述 projection。
5. Native Host connection 创建、本机 keyboard permission switch，以及 macOS main queue 的 simulated mouse/pointer/key 最终执行共用 active-session + H3.4g Accessibility gate。cursor-only non-injecting 和非 Native pinned upstream 行为保持。
6. 未修改旧 upstream `is_locked()`/`is_prelogin()` 的其他调用、protobuf、Host ABI/HostSnapshot、Hermes、CI、根依赖、数据库或凭据。

## Verification

- RED `native_host_active_aqua_session_fails_closed_on_unknown_or_unavailable_states`：allow-all 旧行为为 0 passed, 1 failed；失败点是 locked session 仍为 true。
- GREEN 同一测试：1 passed, 0 failed；覆盖 active、locked、off-console、login incomplete 和三个 unknown 状态。
- Accessibility TCC policy：1 passed, 0 failed。
- effective input permission：1 passed, 0 failed。
- input permission epoch：2 passed, 0 failed。
- input adapter epoch gate：1 passed, 0 failed。
- input mapping epoch：2 passed, 0 failed。
- mouse/key semantic normalization：2 passed, 0 failed。
- connection-scoped mouse release：2 passed, 0 failed。
- native Host remote slot：2 passed, 0 failed。
- authenticated session scope：4 passed, 0 failed。
- 相关 Rust 合计：18 passed, 0 failed；debug test build 只有 pinned/upstream warnings。
- `Scripts/build-rust-core.sh`：release core 成功，生成 arm64 Mach-O dylib；130 个 pinned/upstream warnings，无编译错误。
- built-core Host lifecycle/ABI：3 passed, 0 failed。
- built-core loader ABI smoke：1 passed, 0 failed。
- `swift test`：109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`：success。
- 三个 touched Rust 文件以 Rust 2021 rustfmt；canonical patch reverse-check 通过。
- clean pinned clone apply 后 14 个 canonical 文件逐一一致。

## Remaining boundary

- 自动 policy/readback/编译证据不能代替 Mini 锁屏、解锁和 Fast User Switching 的真实 CGEvent 验收。
- 最终 adapter 会在 lock/off-console 时立即丢弃事件，但运行中的 connection permission/HostSnapshot/UI 尚不会主动切换为 `limited/sessionUnavailable`；这需要 platform session monitor 与共享 event contract。
- lock transition 恰好发生在 key-down/key-up 之间时，内部 pressed-state 清理和系统实际状态仍需共享 revoke lifecycle 或真机证据。
- `CGSessionCopyCurrentDictionary` 与 Accessibility 查询位于最终输入路径；真实高频 mouse/key 性能影响留待 H2/H3 真机指标验证，不虚构为零开销。

## Next step

H3.4 剩余自动空间已经接近 shared contract 边界。下一次优先审计 Secure Input 能否用现有 CGSession dictionary 只做内部 fail-closed；若无法无歧义区分或需要 UI 状态，停止实现并记录架构检查点，再转向其他不依赖用户的 H3 小步。
