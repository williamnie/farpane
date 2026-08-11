# H6.3j Viewer upload semantic-read ABI contract

## Outcome

Viewer ABI 已从 v13 升至 v14，并建立默认未接 wire 的 path-free 上传来源契约。Swift 继续独占 source descriptor 与 lifetime；Rust 只接收 opaque source token 和 bounded normalized manifest，注册最多 8 个 semantic upload jobs，并以同步 callback 请求 exact file number/offset/range。

本步没有发送 `FileAction::Receive`、`FileAction::Create`、digest、block 或 done，也没有在 App/ViewerUI 增加上传动作。Viewer 产品上传仍未开放。

## Key evidence

- `RDNFileTransferUploadStart` 只携带 ABI version、exact session epoch、positive transfer ID、opaque source token、borrowed manifest entries 和 checked total bytes；path 与 descriptor 不跨 ABI。
- `RDNFileTransferUploadReadRequest` 由 Rust 创建 caller-owned、最大 128 KiB 的 mutable buffer；Swift 必须同步填满并返回 exact `bytes_written`，双方不得保留 request/buffer。
- Rust 在 start 与 callback 前后复核 active/authenticated/file-mode/exact epoch、remote permission、ready sender 和 unchanged semantic job；duplicate/cross-direction transfer ID、越界、短读与 stale state fail closed，拒绝后的 owned buffer 清零。
- Swift adapter 在 Core start 前绑定 exact request/source owner，Core 拒绝会回滚；读取只经 pinned descriptor `pread`，owner borrow 前后继续重验 inode、owner、mode、link、size、mtime、ctime。
- cancel、terminal、disconnect 与 worker exit 会清除匹配的 Rust job 和 Swift route；semantic cancel 不向 peer 发送尚未建立的 foreign wire job。
- shim 把 `rdn_client_file_transfer_upload_start` 作为 ABI v14 required symbol；fresh Rust core 导出检查与 Swift 动态加载均通过。

## Verification

- `rustfmt --edition 2021 CoreBridge/RustDeskPatch/rdn_bridge.rs`
- `Scripts/bootstrap-rustdesk-core.sh`：canonical patch replay 成功，pinned commit `6c578292e8ebbbec708b76986ba8c4bc7c509747`。
- `VCPKG_ROOT=Build/vcpkg MACOSX_DEPLOYMENT_TARGET=13.0 CARGO_BUILD_JOBS=1 cargo test --features rdn-native-core,rdn-native-host --lib rdn_bridge::tests`：40 passed，0 failed。
- `Scripts/build-rust-core.sh`：fresh arm64 dylib 构建成功，并验证新增 upload start symbol。
- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`：991 passed，0 failed；包含 ABI v14 动态加载、7 个 upload source/adapter tests 与 Host lifecycle。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：176 passed，0 failed。
- `python3 Scripts/audit-host-file-transfer-product-development-completion.py`：40 个 required audits 全部通过；状态仍为 `product-development-incomplete-viewer-upload`。
- `swift build -c release --arch arm64`：fresh release build 成功。
- `git diff --check`：通过。

RustDesk upstream 仍有既有 deprecated/unused/check-cfg warnings；本步没有新增编译失败或测试失败。未启动 GUI、读取真实用户文件、安装、修改 Hermes、CI、根依赖、数据库或 push。Mac mini 单机 GUI smoke 与双机上传继续按当前完成口径记为未验证，不阻塞开发。

## Next step

`host-file-transfer-viewer-upload-wire-job-lifecycle`：在 Rust 内把已注册 semantic job 投影为 canonical `FileAction::Receive/Create` lifecycle，保持 Swift 只提供同步 descriptor-backed bytes，并继续让 App/ViewerUI 上传动作默认关闭。
