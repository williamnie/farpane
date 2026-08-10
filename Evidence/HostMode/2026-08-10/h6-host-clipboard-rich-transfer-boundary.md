# H6.2j1 Host rich clipboard transfer-boundary taxonomy

## Outcome

Host clipboard wire payload 在真实双向准入前具有明确的 inline、独立传输、拒绝三态分类。当前产品行为不变：只有有界小文本可通过，富类型仍未启用。

## Key evidence

- `Text` 必须 exactly one、至多 64 KiB、解压后仍有界、合法 UTF-8、无 NUL、无特殊名称或图像尺寸。
- RTF、HTML、RGBA、PNG、SVG 只得到 `IndependentTransferRequired`，现有 read/write 与 outgoing message 门禁仍拒绝它们。
- `Special` 的远端 format/UTI 名称和未知 enum 直接 `Reject`。
- Host embedded-NUL 文本现在与 Viewer 一致 fail closed。
- 上游 rich conversion 的无界解压路径仍不进入 Native Host admission；后续必须由独立 bounded envelope 取代。

## Verification

- Focused Rust native clipboard：4/4。
- Full pinned Rust `rdn-native-core,rdn-native-host` release suite：163/163。
- Viewer-only `rdn-native-core` release check（Host feature 未编译）：通过。
- `Scripts/build-rust-core.sh` fresh arm64 Core 与 required-symbol checks：通过。
- Full Swift with fresh arm64 Core：917/917，0 failure、0 skip。
- ScriptTests：125/125。
- arm64 Swift Release build：通过。
- Machine audit：`rich-payload-independent-transfer-boundary`，10/10 evidence、
  13/13 source lines。
- Rust formatting、Python compile、canonical/vendor bridge byte compare、RustDesk
  与 hbb_common reverse-patch checks、root/nested `git diff --check`：通过。

一次额外的 `--no-default-features` Viewer check 因 pinned RustDesk
`audio_service` 需要默认 `use_dasp` 而失败；该命令不是受支持 feature 组合。
改为真实 Viewer-only 组合 `default + rdn-native-core` 后通过，错误与本次仅在
`rdn-native-host` 编译的分类代码无关。

## Remaining boundary

- RTF/HTML 独立 bounded transfer envelope 尚未实现。
- 图片传输的尺寸、像素、解压与内存预算尚未冻结。
- Viewer rich ABI 与 AppKit pasteboard owner 尚未实现。
- 双机小文本和后续 rich clipboard 仍需安装构建验收。

## Next step

`bounded-rich-text-transfer-envelope-contract`。
