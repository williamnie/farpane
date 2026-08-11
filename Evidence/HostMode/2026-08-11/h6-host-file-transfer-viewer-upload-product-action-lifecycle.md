# H6.3l Viewer upload product action lifecycle

## Outcome

- FarPane live Viewer 已接通显式“发送文件”产品动作，并继续保留独立“接收文件”动作。
- 用户选择在 dedicated file-only Core 启动前进入 descriptor-owned source；App、wire 与 ABI 不持有本地路径或 descriptor。
- exact epoch/transfer progress、取消、terminal、协议漂移与 teardown 均 fail closed。
- H6.3 文件传输产品开发代码无剩余缺口；安装版单机 smoke 与双机验收仍分别记为未执行/未验证。

## Key evidence

- `Sources/CoreBridge/ViewerFileTransferUploadSessionOwner.swift`
- `Sources/CoreBridge/ViewerFileTransferProductComposition.swift`
- `Sources/RustDeskNative/ViewerFileTransferDialogs.swift`
- `Sources/RustDeskNative/ViewerUI.swift`
- `Sources/RustDeskNative/RustDeskNativeApp.swift`
- `Tests/CoreBridgeTests/ViewerFileTransferProductCompositionTests.swift`
- `Scripts/audit-host-file-transfer-viewer-upload-product-action-lifecycle.py`

## Verification

- 定向 Viewer product composition regression：13/13 通过；覆盖 ready 前 pin、terminal、queued/active cancel、unsafe source 与 protocol drift。
- H6.3l machine-readable audit：通过，状态为 `viewer-upload-product-action-implemented`。
- H6.3 product development completion audit：42 份 required audits 全部通过，状态为 `product-development-complete`、remaining development gaps 为空。
- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`：995/995 通过，并实际加载 ABI v14 Core。
- ScriptTests：178/178 通过。
- signed arm64 App fresh build：通过，`BUILD_NUMBER=202608111329`、`SIGNING_MODE=stable-identity`，且打包脚本会拒绝缺少 upload-start ABI symbol 的 Core；产物为 `Build/FarPane.app`。

## Acceptance boundary

- 未启动或安装 GUI，避免干扰当前 Mac mini 会话。
- 未执行双机发送/接收、Direct/Relay、性能或互操作验收；这些不阻塞当前开发完成口径。
