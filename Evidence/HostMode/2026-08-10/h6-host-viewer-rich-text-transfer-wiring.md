# H6.2j4 Host↔Viewer rich-text transfer wiring

## Outcome

H6.2j4 自动实现完成。Host Control ABI v14 在既有小文本 read/write
之外增加独立、默认关闭的 rich read/write；Host 与 Viewer 现在能在 pinned
clipboard wire 上交换同一套有界 Text/RTF/HTML semantic bundle。产品配置与
AppKit pasteboard owner 没有启用 rich，因此本步不改变默认产品行为。

## Contract

- `RdnHostCreateOptions` 的四个方向互相独立；Swift 四项默认均为 `false`。
- `NativeClipboardTransferPolicy` 分开持有 small-text 与 rich-text policy；只有
  任一方向显式开启时，才把 pinned upstream 单一 `enable-clipboard` 写成 `Y`。
- small-text opt-in 不会授权 RTF/HTML；active-session read/write revoke 在格式
  分类和解压前生效，并覆盖两类格式。
- rich bundle 只接受 1–3 项 Text/RTF/HTML，每种至多一项且至少包含 RTF 或
  HTML；plain fallback 上限 64 KiB，RTF/HTML 各自 wire 与解压后上限 1 MiB。
- 所有 entry 必须为合法 UTF-8、无 NUL、空 special metadata、零图像尺寸；图片、
  `Special`、未知 format、重复 representation 和有界解压失败全部拒绝。
- 入站在调用 pinned `update_clipboard` 前、出站在进入 connection writer 前，均
  重建 canonical uncompressed Text/RTF/HTML，远端压缩数据不会到达上游无界 helper。
- 编译了 `rdn-native-host` 但没有 native Host binding 时，保留 pinned upstream
  行为；Host binding 存在时必须通过上述权限和 payload 门禁。
- canonical Host bridge 继续由 bootstrap 复制；connection 增量保存在独立的
  `h6-rich-text-transfer.patch`，bootstrap 使用 `--unidiff-zero` 可重放并反向校验。

## Verification

- `Scripts/bootstrap-rustdesk-core.sh`
  - pinned commit `6c578292e8ebbbec708b76986ba8c4bc7c509747`
  - extension patch clean replay/reverse check 通过
- Rust focused tests
  - rich envelope/bundle：2 passed
  - rich transport direction/format policy：1 passed
  - per-session directional revoke：1 passed
- Rust full release library tests
  - `rdn-native-core,rdn-native-host`：171 passed，0 failed
- Viewer-only Release feature check
  - `rdn-native-core`：通过
- fresh arm64 Rust Core
  - `Build/CoreBridge/arm64/liblibrustdesk.dylib`
  - Mach-O arm64，构建成功
- Swift tests loaded against the fresh Core
  - 917 passed，0 failed
- ScriptTests
  - 128 passed，0 failed
- `swift build -c release`
  - 成功
- `python3 Scripts/audit-host-viewer-rich-text-transfer-wiring-contract.py`
  - status `host-viewer-rich-text-transfer-wired-default-off`
  - 15/15 evidence、12/12 source lines
- canonical/vendor bridge byte equality、tracked extension reverse check、Python compile、
  `git diff --check`：通过

Rust 构建仍输出 pinned dependencies 已存在的 deprecated/`unexpected cfg`/unused
warning；本步没有新增 warning-as-error 门禁，也没有为清理这些历史 warning 扩大范围。

## Remaining boundary

- Viewer 的单一 AppKit pasteboard owner 尚未读取、写入或显式开启 rich directions。
- Host Agent bootstrap/Home 只投影小文本方向，产品 Host rich directions 仍为默认关闭。
- 图片和文件 promise 未启用。
- 安装态双机 ownership、teardown、端到端 RTF/HTML、延迟与 idle CPU 仍需后续真机验收。

下一自动边界：`viewer-rich-text-pasteboard-owner-explicit-enablement-contract`。
