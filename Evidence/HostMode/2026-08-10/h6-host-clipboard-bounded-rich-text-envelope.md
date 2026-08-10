# H6.2j2 Host bounded rich-text transfer envelope

## Outcome

H6.2j2 建立了 RTF/HTML 的 Rust-owned semantic envelope。它同时约束 wire 与解码后
UTF-8 大小、只使用有界解压、复制为自有 `String`，并在任何未来传输路径前拒绝畸形
metadata、非法 UTF-8 与 NUL。当前真实 clipboard admission 仍只允许 64 KiB 小文本，
所以本步是安全前置契约，不是富文本产品启用。

## Key evidence

- `MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES` 与
  `MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES` 分别冻结为 1 MiB。
- `NativeRichTextTransferEnvelope::from_clipboard` 只接受 `Rtf`/`Html`、空
  `special_name`、零 `width/height` 与非空 payload。
- 压缩内容经 `decompress_with_limit` 解码；无论是否压缩，解码后仍复核 1 MiB
  上限、UTF-8 和 NUL。
- envelope 持有独立 `String`；回归会在构造后清空原 `Clipboard.content`，证明结果
  不借用 wire buffer。
- classifier 只有在 envelope 构造成功时才返回
  `IndependentTransferRequired`；现有两向 admission 仍只接受 `InlineSmallText`。
- 机器审计状态：`bounded-rich-text-envelope-contract`，12/12 evidence、13/13
  source anchors。

## Verification

- focused Rust clipboard gates: 4/4 passed。
- focused Rust rich-text envelope: 1/1 passed。
- 完整 pinned Rust `rdn-native-core,rdn-native-host` release suite：164/164 passed。
- `Scripts/build-rust-core.sh` fresh arm64 Release Core 与 required-symbol checks：通过。
- 加载 fresh arm64 Release Core 的 Swift tests：917/917 passed，0 failure、0 skip。
- ScriptTests：126/126 passed。
- arm64 Swift Release build：通过。
- Viewer-only `rdn-native-core` release feature check（不编译 Host feature）：通过。
- Rust formatting、Python compile、canonical/vendor bridge byte compare、RustDesk 与
  hbb_common reverse-patch checks、root/nested `git diff --check`：通过。

## Remaining boundary

- 尚无 rich Viewer ABI 或 Host/Viewer transfer wiring。
- 尚无 RTF/HTML 的 AppKit pasteboard owner 与产品开关。
- 图片与文件 promise 不属于本 envelope，保持关闭。
- installed 双机 ownership、teardown、延迟与 idle CPU 验收仍待真实设备。

## Next step

`viewer-rich-text-clipboard-api-contract`：在默认关闭、严格有界的前提下单独定义
Viewer rich-text ABI，仍不让 Swift/Rust 绕过单一 pasteboard owner。
