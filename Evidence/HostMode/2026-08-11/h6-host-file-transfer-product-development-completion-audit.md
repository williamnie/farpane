# H6.3g file-transfer product development completion audit

## Outcome

H6.3 的开发尚未完成，当前只剩一个已定位的产品代码缺口：FarPane Viewer 已有“接收文件”动作，可从 Host 的 descriptor-owned 只读服务下载到本机安全目录；Host 也已有默认关闭的显式接收授权与 descriptor-owned 写入服务。但 Viewer 仍没有“发送文件”入口、文件选择/本地 manifest authority 或 upload request，因此仅用 FarPane 还不能发文件到远端 Host。

这不是双机验收缺失造成的结论。审计直接核对当前产品源码，并重跑全部 37 份 H6.3 机器审计；permission/bootstrap/Home、Host receive/send、Viewer download、bounded payload、untrusted path/metadata、safe root/staging/write/commit 均保持通过。

## Requirement matrix

- 独立权限与默认关闭：已实现。Host 只有用户选择私有 `FarPane Receive` 后才发布 enabled policy。
- Host 接收：已实现。new write、single-file resume、existing-target no-replace/skip 与 teardown 已进入 descriptor owner。
- Host 发送：已实现。root list、recursive snapshot、digest/confirm 与 bounded read job 已进入 descriptor owner。
- Viewer 接收：已实现。独立 file session、manifest、目录 picker、bounded block、staging/write/durable no-replace commit、progress/cancel/terminal 已接产品。
- Viewer 发送：**未实现**。当前方向 enum 只有 `download`，Viewer UI 只有“接收文件”，picker 只允许目录且没有 `canChooseFiles = true` 的文件选择。
- overwrite/resume：当前产品策略明确 fail closed；Viewer 提示不覆盖已有文件，Host 仅支持受约束的单文件 staging resume，replace 和 multi-file resume 不开放。完整文件管理器本来就是 V1 非目标。

## Verification

- RED：completion audit 回归先因审计脚本不存在而失败。
- focused completion audit：1/1 通过；状态为 `product-development-incomplete-viewer-upload`，remaining gap 精确为 `viewerUploadProductAction`。
- 完整 fresh Swift：984/984 通过，4 skipped，0 failures。
- 完整 fresh ScriptTests：173/173 通过。
- `swift build -c release --arch arm64`、Python compile 与 `git diff --check` 通过。

本步只做当前状态审计，不启动 GUI、不访问真实用户文件、不安装 App/Agent、不修改 Hermes、CI、根依赖、数据库或远端，也不 push。Mac mini 安装版单机 smoke、双机双向传输、性能与互操作仍为非阻塞未验证项。

## Next step

`host-file-transfer-viewer-upload-selection-manifest-contract`：先建立本地文件/目录显式选择、descriptor-owned snapshot、untrusted local-name normalization、大小/条目上限与 path-free upload request；保持默认不接产品与不改 Viewer ABI，之后再独立评审 wire/ABI dispatch。
