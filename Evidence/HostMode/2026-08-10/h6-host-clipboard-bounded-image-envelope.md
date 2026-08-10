# H6.2k1 Host bounded image clipboard envelope

Date: 2026-08-10

## Outcome

H6.2k1 为 RGBA、PNG 与 SVG 建立了 Rust-owned semantic envelope。三类输入在被
标记为未来独立 transfer 之前，必须通过 wire/decoded 大小、维度、像素数、格式结构
和 metadata 的有界校验；构造结果拥有独立 bytes。当前 Host incoming/outgoing
admission 仍拒绝所有图片，因此本步是安全前置合同，不是图片剪贴板产品启用。

## Key evidence

- RGBA wire 与 bounded zstd decoded payload 均以 128 MiB 为硬上限；宽高必须为
  正、单边不超过 8192、总像素不超过 7680x4320，并用 checked multiplication
  要求解码后精确等于每像素 4 bytes。
- PNG 必须使用 canonical 非 zstd wire 形状且 protobuf 宽高为零；128 MiB 内检查
  signature、唯一首个 13-byte IHDR、合法 bit depth/color header、有界内嵌尺寸、
  非空 IDAT、chunk length 与 exact zero-length IEND。该结构检查不声明 CRC 或完整
  图片解码。
- SVG wire 与 decoded UTF-8 分别限制为 4 MiB；有界解压后拒绝非法 UTF-8、NUL、
  DOCTYPE 与非 canonical `<svg>` root。此检查不是渲染 sanitizer。
- `NativeImageTransferEnvelope` 持有独立 `Vec<u8>`；回归在构造后清空源
  `Clipboard.content`，验证结果不借用 wire buffer。
- classifier 只有在 envelope 构造成功时才返回
  `IndependentTransferRequired`；真实两向 clipboard admission 仍拒绝图片。
- 机器审计状态为 `bounded-image-envelope-contract`：11/11 evidence、13/13 source
  anchors，明确记录 network transport、pasteboard 与 product enablement 均为 false。

## Verification

- RED：新增 envelope 回归首次编译时因 `NativeImageTransferEnvelope`、
  `NativeImageFormat` 与边界常量尚不存在而失败；实现后同一回归转绿。
- 完整 pinned Rust `rdn-native-core,rdn-native-host` Release suite：172/172 passed。
- `Scripts/build-rust-core.sh` fresh arm64 Release Core 构建、required-symbol checks 与
  原子发布：通过；产物识别为 arm64 Mach-O dylib。
- 加载 fresh `Build/CoreBridge/arm64/liblibrustdesk.dylib` 的 Swift tests：921/921
  passed，0 failure。
- ScriptTests：131/131 passed。
- Viewer-only `rdn-native-core` Release feature check：通过。
- `swift build -c release`：通过。
- dedicated audit、Rust formatting、Python compile、canonical/vendor byte compare、
  RustDesk/hbb_common nested diff checks 与 root `git diff --check`：通过。

## Boundary

本步未新增 Viewer/Host ABI、schema、UI 或产品开关，未连接图片 network transfer，
未读取或写入系统 pasteboard，未启用图片或文件 promise；未安装或运行 App/Agent，
未修改 Hermes、CI、根依赖、数据库、凭据，也未 push。

Viewer 图片 ABI、Host/Viewer 图片 transfer wiring、单一 AppKit pasteboard owner、
Host 显式方向开关与 installed 双机验收仍待后续。

## Next step

`viewer-image-clipboard-api-contract`：先建立默认关闭、严格有界的 Viewer 图片 ABI，
仍不越过单一 pasteboard owner 或启用产品能力。
