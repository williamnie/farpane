# H6.3h Viewer upload selection/manifest contract

## Outcome

Viewer 上传现在有默认未接产品的显式本地选择与 descriptor-owned manifest authority。新的 AppKit picker 可选择一个或多个文件/目录、关闭 alias 解析；选择结果必须立即交给 CoreBridge owner，owner 此后只发布 exact-session opaque lease、规范化 manifest 和 path-free upload request，不把 URL、路径或 descriptor 放进未来 ABI/wire 输入。

owner 对每个显式 top-level selection 立即 `open(O_NOFOLLOW)`；目录递归只经 pinned descriptor 的 `fdopendir/fstatat/openat`，拒绝 symlink、跨 mount、特殊文件、group/world writable 或非 root/current-euid owner 的目录/文件。名称按 NFC 规范化，拒绝控制字符、private staging suffix 与完整 case-fold collision；目录内隐藏项默认忽略。top-level selection 限制 64 个，以便连同 64 层递归 descriptor 保持有界；manifest 继续限制 1,024 entries、1 MiB UTF-8 metadata 与 checked total bytes。

文件 borrow 只接受 matching epoch/token/file number，selected file 用 CLOEXEC descriptor duplicate，selected directory 用 pinned root descriptor-relative reopen；回调前后都复核 device/inode/owner/mode/link/size/mtime/ctime identity。teardown 只接受 exact epoch 并确定性关闭全部 root descriptors。

## Key evidence

- 真实文件系统回归覆盖混合文件/目录、empty directory、隐藏项、NFC、控制字符、symlink、unsafe directory、重复 top-level、private staging 与 selection overflow。
- selected directory 原路径被移动并替换成指向外部的 symlink 后，borrow 仍读取原 pinned inode；原文件内容/size 漂移后立即拒绝。
- `ViewerFileTransferUploadRequest` 只含 session epoch、transfer ID、opaque source lease 和 manifest；由 owner 的 `makeUploadRequest` 绑定 exact snapshot。
- Viewer ABI 保持 v13，App/ViewerUI 没有上传 action 或 wire dispatch，选择器尚未被产品构造。

## Verification

- RED：5 项 owner/picker contract tests 先因缺少 upload owner/request/picker 而编译失败；机器审计回归先因脚本不存在而失败。
- focused upload owner/picker tests：5/5 通过。
- 完整 fresh Swift：989/989 通过，4 skipped，0 failures。
- 完整 fresh ScriptTests：174/174 通过。
- `swift build -c release --arch arm64`、Python compile 与 `git diff --check` 通过。

所有 filesystem regression 仅操作 UUID 临时目录。本步未启动 GUI、访问真实用户目录、安装 App/Agent、修改 Viewer ABI、Hermes、CI、根依赖、数据库或远端，也不 push；双机上传仍未验证。

## Next step

`host-file-transfer-viewer-upload-wire-abi-ownership-audit`：核对 pinned upstream upload message flow、source descriptor read lifetime、digest/skip/resume、progress/terminal 与 cancel ownership，冻结最小 Viewer ABI/patch 边界后再实现 dispatch。
