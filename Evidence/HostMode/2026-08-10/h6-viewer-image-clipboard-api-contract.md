# H6.2k2 Viewer image clipboard API contract

Date: 2026-08-10

## Outcome

Viewer C ABI 升至 v8，新增默认关闭且彼此独立的图片 receive/send 方向，以及
callback-scoped `RDNClipboardImagePayload` 和专用发送 API。RGBA、PNG 与 SVG 在 Rust
和 Swift 两侧都经过有界语义校验；当前 Viewer 产品、AppKit pasteboard owner 与 Host
图片传输仍未接入，因此本步建立的是安全 API 边界，不是图片剪贴板产品启用。

## Contract

- RGBA wire/decoded payload 上限均为 128 MiB；宽高为正、单边不超过 8192、总像素
  不超过 7680x4320，并以 overflow-safe 乘法要求精确 4 bytes/pixel。
- PNG 使用 canonical 非 zstd wire 形状、ABI 宽高为零且不超过 128 MiB；检查
  signature、唯一首个 IHDR、合法 bit-depth/color header、有界内嵌尺寸、非空 IDAT、
  chunk framing 与 exact IEND。该结构检查不冒充 CRC 或完整图片解码。
- SVG wire/decoded UTF-8 都不超过 4 MiB；拒绝非法 UTF-8、NUL、DOCTYPE 与非
  canonical `<svg>` root。SVG 仍是不可信输入，不声明渲染 sanitizer。
- 入站只接受 exactly one、无 special metadata 的图片；Rust 在解析/解压前要求
  active、authenticated、本地 image receive 与远端 clipboard permission 全部成立，
  callback 前再次复核。
- 出站只构造 canonical uncompressed `Clipboard`，并要求 active、authenticated、
  本地 image send 与远端 clipboard permission 全部成立。
- Swift 同步复制 callback-scoped bytes，再次校验 format、metadata、大小、PNG
  structure 与 SVG root，最后才经现有 clipboard disconnect delivery gate 投递。

## Verification

- RED：新增 Rust contract tests 首次因 image constants、payload、parser、callbacks 与
  lifecycle gates 尚不存在而编译失败；实现后同一边界转绿。
- focused Rust Viewer image contract：6/6 passed，覆盖三种格式、owned payload、
  adversarial bounds、canonical outbound、pre-parse receive gate 与完整 send gate。
- 完整 pinned Rust `rdn-native-core,rdn-native-host` Release suite：178/178 passed。
- Viewer-only `rdn-native-core` Release check：通过。
- `Scripts/build-rust-core.sh` fresh arm64 Release Core 构建、ABI v8 required-symbol checks
  与原子发布：通过；产物为 arm64 Mach-O dylib。
- 加载 fresh `Build/CoreBridge/arm64/liblibrustdesk.dylib` 的 Swift tests：921/921
  passed。首轮准确发现两处仍固定为 Viewer ABI v7 的 Host bridge 合同断言；更新为
  v8 后完整重跑通过。
- ScriptTests：132/132 passed。旧 H6.2k1、小文本与富文本审计同步到 ABI v8/current
  remaining boundary 后继续通过。
- `swift build -c release`：通过。
- machine audit 状态 `viewer-image-clipboard-api-default-off`：14/14 evidence、13/13
  source anchors；明确记录 Viewer product image=false、Host transport=false、SVG
  sanitizer=false。
- canonical/vendor bridge byte equality、tracked patch reverse-check、bootstrap clean
  replay、Rust formatting、Python compile、nested/root diff checks：通过。

## Boundary

本步没有启用 Viewer 产品图片方向，没有修改 `ViewerPasteboardOwner`，没有接通 Host
incoming/outgoing image admission，也没有新增 Host ABI/schema/Home 开关。没有读取或
写入真实 pasteboard，没有安装/运行 App/Agent，没有修改 Hermes、CI、根依赖、数据库、
凭据，也没有 push。

## Next step

`host-viewer-image-transfer-wiring-contract`：把 Host 已有的 bounded image envelope 与
Viewer ABI v8 通过独立方向策略接通；仍保持 AppKit owner 和产品显式启用关闭。
