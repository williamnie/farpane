# H6.3k Viewer upload wire-job lifecycle

## Outcome

Viewer ABI v14 的 path-free semantic upload job 已接入 pinned RustDesk wire lifecycle。Rust 负责 create/receive/digest/confirm/block/done/cancel、调度、超时与 terminal；Swift 继续只持有 source descriptor 并同步提供 exact bytes。App/ViewerUI 的“发送文件”入口仍默认不存在，因此本步不宣称产品上传或双机验收完成。

## Key evidence

- `NativeViewerUploadStage` 覆盖空目录 create、逐文件 digest confirmation、bounded sending 与 final Done；最多 8 个 jobs 由 transfer ID 排序后轮转，每 tick 最多发送一个 128 KiB block。
- 只接受 `OffsetBlk(0)` 与 `Skip(true)`；nonzero offset、`Skip(false)`、错序响应、短读、remote error 和 30 秒 stage timeout 均形成稳定 fail-closed terminal，必要时发送 Cancel。
- empty-directory leaf 会投影为去重的全部祖先并 parent-first 创建；file batch 的空 base path 只表示 Native Host 已 admission 的 receive-root。
- Native Host 在 exact zero-length digest 后立即创建、fsync、设置 mtime、移除 resume metadata 并 no-replace commit，因此无需虚构空 block 也能推进文件序号。
- `h6-viewer-file-upload-wire.patch` 已纳入 bootstrap 的 apply/reverse-check；canonical Rust bridge/Host bridge 仍由仓库拥有并覆盖生成 checkout。
- 产品上传 action、existing-target replace、multi-file resume 与双机现场检查保持未实现/未验证，不被本步夸大。

## Verification

- `Scripts/bootstrap-rustdesk-core.sh`：通过，pinned commit 为 `6c578292e8ebbbec708b76986ba8c4bc7c509747`。
- Rust focused Viewer upload wire sequence：通过，覆盖 `Receive → Digest → OffsetBlk(0) → Block → Done`。
- Rust focused Native Host receive-root/zero-byte test：通过。
- Rust Viewer bridge tests：42/42；Native Host bridge tests：64/64。
- fresh Rust core：release arm64 dylib 构建成功。
- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`：991/991。
- ScriptTests：177/177；41 份 H6.3 required audits 均通过。
- signed arm64 App build：成功，`BUILD_NUMBER=202608111307`。
- 双机发送、远端文件落盘与跨机性能：未验证；当前仅有 Mac mini，不阻塞开发完成口径。

## Next step

`host-file-transfer-viewer-upload-product-action-lifecycle`：让现有 upload picker/source owner 进入独立 file-session product composition，并增加默认关闭、exact epoch、cancel/teardown 与 UI action 回归；仍不依赖双机验收。
