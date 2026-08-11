# H6.3f2b2r Viewer product composition lifecycle

## Outcome

Viewer 文件传输现在有独立于桌面画面连接的 product composition。它在构造时完全惰性；只有未来产品入口显式调用 `start(baseConfiguration:)` 才会创建第二个 Core，并投影为 clipboard 六方向关闭、`fileTransferEnabled=true`、exact positive epoch 的 dedicated `FILE_TRANSFER` 配置。

App 为每个 live Viewer attempt 创建并强持有该惰性 composition，在回 Home、启动失败和 App 退出时先 teardown 文件会话，再断开 desktop Core。当前 App 不调用 `start`、`beginDownload`，也没有 `NSOpenPanel`，因此本步不会产生第二条网络连接、目录选择器或真实文件写入，产品入口仍关闭。

## Key evidence

- composition 固定单个 positive session epoch；Core factory 只在显式 start 时求值，base configuration 与 password 不被保存。
- ready 之前拒绝下载；ready 后 request/transfer ID 与 opaque destination token 单调且不复用，目标目录继续要求 current-euid、`0700` 的 descriptor owner admission。
- manifest 与 progress 只交给 exact session owner；authentication、disconnect 与非法 control state 稳定 fail closed。
- Core 在 `connect` 中同步回调时先缓冲事件，待 start 操作退出临界区后再投递，覆盖 callback reentrant teardown，不自锁。
- teardown 顺序固定为 session owner cancel/discard/关闭 destination，随后 dedicated Core disconnect。
- Viewer ABI 保持 v13；Hermes、CI、根依赖、数据库和远端分支均未修改。

## Verification

- RED：首次运行 `swift test --filter ViewerFileTransferProductCompositionTests` 因 product composition 类型尚不存在而编译失败；实现后 GREEN 6/6。
- `swift test --filter ViewerFileTransfer`：47/47。
- 全量 `python3 -m unittest discover -s Tests/ScriptTests`：169/169。
- fresh arm64 Rust Core build：通过，产物为 `Build/CoreBridge/arm64/liblibrustdesk.dylib`。
- 以上述 fresh Core 运行全量 `swift test`：971/971。
- pinned RustDesk `cargo test --lib --features rdn-native-core,rdn-native-host`：230/230。
- `swift build -c release --arch arm64`（加载 fresh Core）：通过。
- 新旧两份 H6.3 lifecycle audit：通过；新审计状态为 `viewer-product-composition-implemented-entry-off`，下一边界为 `host-file-transfer-viewer-download-picker-action-lifecycle`。
- canonical/vendor 三份 bridge byte identity、Viewer receive/digest patch reverse-apply、Rust 2021 `rustfmt --check`、Python `py_compile`、root `git diff --check`：通过。

没有启动 App 做单机 smoke：composition 当前是惰性的且产品入口关闭，启动 GUI 无法覆盖新增链路，并可能干扰正在使用的 Mac mini。双机画面、远程输入、剪贴板、文件传输及跨机性能仍未验证，按当前完成口径不阻塞开发。

## Next step

`host-file-transfer-viewer-download-picker-action-lifecycle`：在明确用户动作下接入目录选择、显式 dedicated Core start 与单次 download action；继续保持默认关闭、取消/teardown 有界，并不改动 desktop Core。
