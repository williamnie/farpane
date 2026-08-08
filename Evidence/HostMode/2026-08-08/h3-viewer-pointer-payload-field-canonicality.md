# H3.4z Viewer pointer payload-field canonicality

日期：2026-08-08

## Outcome

Viewer pointer ABI 已拒绝同时混用 position 与 scroll 字段的歧义 payload，并在任何 wire event 生成前 fail closed。

## Key evidence

- `RDNPointerEvent` 为 ABI 稳定性同时携带 `x/y` 与 `scroll_x/scroll_y`，但 semantic kind 的消费边界互斥：
  - Move/Down/Up 只消费 `x/y`，要求两个 scroll 字段为零；
  - Scroll/PreciseScroll 只消费 `scroll_x/scroll_y`，要求两个 position 字段为零。
- 非 canonical payload 返回 `-4`，不会进入 `pointer_mask`、session lookup 或 wire send。
- 现有 Swift `ViewerInputController` producer 已对未使用字段写零，因此正常移动、held-button drag、button 与非零滚动语义不变。
- 改动只位于 repository-owned Viewer bridge 的两份严格镜像；没有改变 C ABI struct/enum 布局、protobuf、Host ABI/snapshot、Hermes 或任何密钥。

## Verification

- bridge mirror `rustfmt` 与 byte-for-byte comparison：通过。
- Viewer producer 定向 Rust test：1 passed，0 failed。
- 完整 Rust lib：123 passed，0 failed。
- arm64 release core：`Mach-O 64-bit dynamically linked shared library arm64`，必需 Viewer/Host symbols 检查通过。
- built-core `HostBridgeContractTests`：3 passed，0 failed。
- built-core ABI smoke：1 passed，0 failed。
- Swift 全量：109 tests，4 skipped，0 failed。
- release `RustDeskNative`：构建成功。
- canonical patch reverse-check 与 clean replay：16 tracked files + 2 repository-owned bridge files 一致。

## Remaining boundary

- 本步是 producer canonicality 门禁，不替代真实 Mini 上的拖拽、滚动、断线 modifier cleanup 验收。
- H3.1 shared secret ABI、H3.2 pending approval broker/UI、H3.3 session snapshot/revoke，以及 H3.4 Secure Input、TCC/session UI、布局/IME、多显示器仍需共享 contract 决策或真机验收。
