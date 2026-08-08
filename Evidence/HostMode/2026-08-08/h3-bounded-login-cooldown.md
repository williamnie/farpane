# H3.1c bounded cumulative login cooldown

- 日期：2026-08-08
- 范围：pinned RustDesk `server/connection.rs` 与 canonical patch
- 结论：默认密码登录的累计 hard block 已收敛为可自动解除的 30 分钟 cooldown；H3.1 永久密码共享 ABI 仍未完成

## Outcome

原 pinned 策略在 direct IP 累计超过 30 次错误后持续拒绝登录，但没有时间解除条件；被拒绝的请求又无法通过成功登录清除计数，因此除非重启进程，该 IP 会一直被锁定。

现在 direct IP 与 IPv6 /64、/56、/48 prefix 使用同一有界策略：累计超过各自既有阈值后，从最后一次已记录的失败分钟起 cooldown 30 分钟。blocked attempt 不写入失败表，所以不会无限延长 cooldown；到期在同一 map lock 内删除 bucket，下一次失败从 1 开始。

## Key evidence

1. 保留原阈值语义：direct IP 为 `> 30`，IPv6 /64、/56、/48 分别为 `> 60`、`> 80`、`> 100`；恰好等于阈值不进入累计 cooldown。
2. 错误回应给出剩余 1–30 分钟；系统时钟回退时展示值上限仍为 30，不输出无界时间。
3. 到期规范化、map 删除和下次 bump 有定向回归；计数使用 `saturating_add`，在 `i32::MAX` 保持稳定而不溢出。
4. 既有一分钟 burst gate、临时密码轮换、alarm audit type 与 OS credential 独立 backoff 保持不变。
5. 成功登录无条件清除 direct IP 与对应 prefix bucket，不会在 direct bucket 过期后留下低于阈值的 prefix 陈旧计数。
6. 未修改 protobuf、C ABI、HostSnapshot、password verifier/storage、Hermes、CI、根依赖、数据库或凭据。

## Verification

- `cumulative_login_failure_cooldown`: 2 passed, 0 failed。
- `os_credential_policy`: 3 passed, 0 failed，确认独立 OS credential backoff 无回归。
- `Scripts/build-rust-core.sh`: release core 成功，生成 arm64 Mach-O dylib；pinned/upstream 编译警告 131 个，无编译错误。
- built-core Host lifecycle/ABI: 3 passed, 0 failed。
- built-core loader ABI smoke: 1 passed, 0 failed。
- `swift test`: 109 tests, 4 conditional skips, 0 failures。
- `swift build -c release --product RustDeskNative`: success。
- canonical patch 与 13-file generated diff 一致；reverse-check 成功，clean pinned clone apply 后 13 个受控文件逐一一致，`connection.rs` rustfmt check 成功。
- 根与 Vendor `git diff --check`: clean；无 staged changes。

## Remaining boundary

- failure table 仍是进程内状态，精度为分钟；进程重启会清空它，与原行为一致。
- 本步验证边界转移与并发 map 操作，没有在真实网络上连续输入 31 次错误密码并等待 30 分钟。
- H3.1b 的 dedicated mutable-byte password ABI、双端 wipe、Rust 强度 policy、异步结果与 snapshot 状态字段仍是共享架构检查点。

## Next step

继续审计 H3 剩余退出条件，选择不需要猜测 HostSnapshot/event/command schema 的小步骤；永久密码产品合同只能在 dedicated secret ABI 边界明确后继续。
