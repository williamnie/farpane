# H3.4aa Viewer key payload-field canonicality

日期：2026-08-08

## Outcome

Viewer key ABI 已拒绝 Unicode scalar 与 hardware keycode 混用的歧义 payload，并在 session lookup 与 wire event 生成前 fail closed。

## Key evidence

- `RDNKeyEvent` 为 ABI 稳定性同时携带 `unicode_scalar` 与 `hardware_keycode`，但三类 semantic key 的字段合同互斥：
  - Character 只消费有效且非 NUL 的 `unicode_scalar`，要求 `hardware_keycode == 0`；
  - Physical 只消费 7-bit macOS virtual key position，要求 `unicode_scalar == 0`；
  - Escape/Return 等 special key 不消费两者，要求它们都为零。
- 非 canonical payload 返回 `-4`，不会进入 physical/name projection、session lookup 或 wire send。
- Swift `CoreBridge.sendKey` 已为每类 key 显式清零未使用字段，正常字符、special key 和 exclusive physical-key producer 行为不变。
- 改动仅位于 repository-owned Viewer bridge 两份严格镜像；没有改变 C ABI struct/enum 布局、protobuf、Host ABI/snapshot、Hermes 或密钥。

## Verification

- bridge `rustfmt` 与 byte-for-byte mirror comparison：通过。
- Viewer producer 定向 Rust test：1 passed，0 failed。
- 完整 Rust 首轮：122 passed，`platform::tests::test_cursor_data` 因测试期间本机 cursor changed 失败；该无关测试独立复跑通过。
- 完整 Rust fresh rerun：123 passed，0 failed。
- arm64 release core：`Mach-O 64-bit dynamically linked shared library arm64`，必需 Viewer/Host symbols 检查通过。
- built-core `HostBridgeContractTests`：3 passed，0 failed。
- built-core ABI smoke：1 passed，0 failed。
- Swift 全量：109 tests，4 skipped，0 failed。
- release `RustDeskNative`：构建成功。
- canonical patch reverse-check 与 clean replay：16 tracked files + 2 repository-owned bridge files 一致。

## Remaining boundary

- 本步是 producer canonicality 门禁，不替代 Mini 上真实布局、dead key、IME、修饰键断线 cleanup 或 exclusive keyboard 验收。
- H3.1 shared secret ABI、H3.2 pending approval broker/UI、H3.3 session snapshot/revoke，以及 H3.4 Secure Input、TCC/session UI、多显示器仍需共享 contract 决策或真机验收。
