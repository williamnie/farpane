# H6.3i Viewer upload wire/ABI ownership audit

## Outcome

Viewer 发送文件不能直接调用 pinned RustDesk 的 `Data::SendFiles`。该入口要求 Rust 持有并重新打开本地路径，与 H6.3h 已建立的 Swift descriptor-owned source authority 冲突。审计冻结了最小的 path-free Viewer ABI v14 方向，但本步没有修改 ABI、Rust patch 或产品 UI。

可复用的是 RustDesk 的 wire protocol 与 Host receiver：Rust 负责 `FileAction::Receive`、逐文件 digest/confirm、bounded block、Done/Cancel；Swift 只按 Rust 的同步请求，从 exact source lease/file number/offset 读取 caller-owned buffer。路径和 descriptor 永不跨 ABI。

## Ownership decision

- Swift owns source lifetime：选择结果、pinned root descriptor、per-file identity、teardown 与每次读取前后的 identity revalidation。
- Rust owns transfer state：active job、file/offset sequence、manifest-to-protobuf projection、digest/confirm、compression、wire send、progress、cancel 和 terminal。
- v14 start seam：`RDNFileTransferUploadStart` 只包含 exact epoch、positive transfer ID、opaque source lease 和 bounded normalized manifest。
- v14 read seam：`RDNFileTransferUploadReadRequest` 只包含 exact epoch/transfer/source lease/file number/offset；synchronous read callback 直接填充 Rust caller-owned 128 KiB buffer，双方都不得保留该 buffer。
- Swift 回调不排队、不返回路径/descriptor、不自行推进 protocol。Rust 校验 written bytes 不超过 capacity/remaining size，expected EOF 之前的 zero/short read、metadata drift、stale lease 和 callback error 全部终止 job。

## Wire and conflict policy

- 文件 batch 使用 canonical `FileAction::Receive`，Host 现有 native write job 可直接消费同一 entries/size/mtime/total-size envelope。
- sender 先发本地 manifest 声明的 digest，只有 exact `OffsetBlk(0)` 才开始读取该文件；non-zero offset 与 multi-file resume 均拒绝。
- existing target 的 upload digest 只回复 `Skip(true)`，保持 no-replace；不会弹出 overwrite，也不会发送 replace offset。
- empty directories 不进入 Host 只接受 file entry 的 receive batch；Rust 按父路径优先顺序发送 canonical create action。create 失败归入同一 terminal，不能冒充 upload 成功。
- 每个 payload wire/decoded 上限继续是 128 KiB；Rust 维护 file number/offset 的唯一权威，重复/乱序/越界回调 fail closed。

## Key evidence

- Pinned upstream `Data::SendFiles` 在 client io-loop 中调用 `TransferJob::new_read(... DataSource::FilePath(PathBuf::from(&path)) ...)`，会重新取得路径 authority。
- `hbb_common::fs` 已提供 canonical `new_receive`、`new_block`、`new_done` 与 128 KiB block 上限；io-loop 已处理 remote `SendConfirm`。
- Native Host connection 已拦截 canonical Receive、Block、Digest、SendConfirm、Done/Cancel，并用 descriptor-backed write owner 落盘。
- 当前 Viewer header 仍为 ABI v13，没有 upload start/read callback；H6.3h source owner 的 path-free lease 和 `withPinnedFileDescriptor` 已满足 v14 Swift data source 前置条件。

## Verification

- `python3 Scripts/audit-host-file-transfer-viewer-upload-wire-abi-ownership.py`
- focused ScriptTest 覆盖 audit status、全部 evidence、ownership claims、128 KiB seam、no path/descriptor、no overwrite/resume 与下一边界。
- 完整 fresh Swift、ScriptTests、arm64 Release build 在本提交前执行并记录实际结果。

本步未启动 GUI、读取真实用户文件、安装、修改 Hermes、CI、根依赖、数据库或 push。Mac mini 单机 smoke 与双机上传仍为非阻塞未验证项。

## Next step

`host-file-transfer-viewer-upload-semantic-read-abi-contract`：实现并验证 Viewer ABI v14 的 bounded upload start + synchronous caller-owned-buffer read contract，先保持 wire dispatch 与产品 action 关闭。
