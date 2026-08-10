# H6.2j5 Viewer rich-text pasteboard owner and explicit enablement

## Outcome

Viewer 产品侧 rich-text pasteboard owner 已显式启用。设备连接、自动恢复和
environment live mode 三条真实配置路径都开启 ABI v7 rich receive/send；Core
默认仍关闭，Host 产品 rich directions 也仍关闭。本步不改变 Host 默认能力。

## Contract

- small-text 与 rich-text 共用唯一 `ViewerPasteboardOwner`、session epoch、timer、
  `changeCount` watermark 和 teardown 顺序，不产生第二个 AppKit owner。
- owner 只在 authenticated/streaming 后 active；创建时只记录当前 `changeCount`，
  不上传会话前 clipboard。
- fallback poller 先比较 `changeCount`，未变化时不读取任何 representation，并继续
  125/250/500/1,000/2,000/4,000 ms 有界退避。
- 本机存在 RTF/HTML 时必须 exactly one pasteboard item；plain fallback 最大 64 KiB，
  RTF/HTML 各最大 1 MiB，全部要求非空 UTF-8、无 NUL。
- 合法 rich bundle 只发送一次 `sendClipboardRichText`；不再重复发送 plain。rich type
  存在但任一 representation 畸形时整项拒绝，不降级绕过 rich policy。
- 远端 rich callback 在 core generation、product attempt 和 clipboard session epoch
  三重一致后才进入 owner；所有 representation 先写入同一个 `NSPasteboardItem`，再用
  一次 `writeObjects` 提交。
- 远端 small/rich write 都把最终 `changeCount` 记录为 owned write，抑制立即回环并把
  poll delay 重置为 125 ms。
- terminal/recovery gap/Home/App teardown 继续先 suspend/stop owner，再 disconnect Core；
  clipboard 内容不进入日志或 evidence。
- Host Agent bootstrap/Home 仍未传入 `clipboardRichTextReadEnabled` 或
  `clipboardRichTextWriteEnabled`；图片和文件 promise 继续关闭。

## Verification

- focused `ViewerClipboardPollingStateTests`：8 passed，0 failed
- focused `ViewerPasteboardProductCompositionContractTests`：3 passed，0 failed
- isolated named AppKit pasteboard smoke：
  - exactly one `NSPasteboardItem`
  - plain/RTF/HTML 三种 representation 写入与 UTF-8 读回通过
  - 未访问 `.general`
- Swift full tests loaded against fresh ABI v14 Core：919 passed，0 failed
- ScriptTests：129 passed，0 failed
- `swift build -c release`：成功
- `python3 Scripts/audit-viewer-rich-text-pasteboard-owner-explicit-enablement.py`
  - status `viewer-rich-text-pasteboard-owner-explicitly-enabled`
  - 14/14 evidence、13/13 source lines
- Python compile、`git diff --check`：通过

Rust/Core/wire 在 H6.2j4 已完成且本步未修改；本轮 Swift full tests 实际加载
`Build/CoreBridge/arm64/liblibrustdesk.dylib` 的 ABI v14，不以无动态库的 skip 代替验证。

## Remaining boundary

- Host bootstrap/Home 还需增加与小文本独立的 rich read/write opt-in；在此之前，
  Viewer rich owner 已就绪但 FarPane Host 产品不会协商/收发 rich payload。
- 安装态双机 RTF/HTML round trip、第三方 App 互操作、ownership/teardown、延迟与
  idle CPU 仍需后续真机验收。
- 图片和文件 promise 不在本步范围，继续 fail closed。

下一自动边界：`host-rich-text-bootstrap-home-opt-in-contract`。
