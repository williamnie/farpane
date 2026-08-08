# H4.1d HostAgent atomic bootstrap publication

## Outcome

HostAgent bootstrap projection 现在具备固定产品布局与 crash-safe 原子发布合同。用户可编辑 server authority 仍只有既有 Viewer catalog；App 写入的 Agent projection 是不含秘密、带 monotonic revision 的只读派生输入。Rust Host identity/policy/config 保持独立 `FarPaneHost` namespace。

产品布局冻结为：

- canonical catalog：`~/Library/Application Support/RustDesk Native Viewer/catalog-v1.json`；
- Agent projection：`~/Library/Application Support/RustDesk Native Viewer/HostAgent/bootstrap-v1.json`；
- Host Rust namespace：`FarPaneHost` / `io.rustdesknative`。

本步没有创建或读取用户真实文件，也没有把 Publisher 接入 App/Agent runtime。现有 `--host-agent` 继续以 69 fail closed。

## Key evidence

- 候选 Data 在获取 publication lock 和落盘前先经 H4.1b exact schema/size/credential firewall 验证。
- fixed `.bootstrap-publication.lock` 必须是当前 euid、`0600`、regular、单硬链接；symlink/不安全 lock 拒绝。
- `flock(LOCK_EX | LOCK_NB)` 让并发 publisher 稳定返回 `publicationBusy`，不等待或并发比较 revision。
- lock 获取后，existing projection 的验证/读取、revision compare、临时文件创建和 rename 全部复用同一个已验证 directory descriptor，不通过 pathname 重新选择目录 inode。
- 完全相同的 revision 与 bytes 是幂等 retry；lower revision 或相同 revision 的不同 bytes 返回 `nonMonotonicRevision`，旧文件字节不变。
- 新文档使用同目录随机 O_EXCL/O_NOFOLLOW 临时文件，强制 `0600`，循环处理 partial write/EINTR，file `fsync` 后 `renameat`，最后 directory `fsync`。
- 替换测试确认 inode 改变、Reader 读到新 revision，并且目录只保留 fixed lock 与正式 projection，无临时文件残留。
- Publisher/Reader 对外 factory 只解析固定 product layout；任意 directory initializer 保持 module-internal，仅供同模块实现和测试。

## Verification

- TDD RED：Publisher/Layout 测试先因生产类型不存在而编译失败。
- 定向 atomic/idempotent、rollback/same-revision mutation、invalid/lock symlink、concurrent lock、product layout：5 tests，0 failures。
- 完整 `swift test`：150 tests，4 conditional skips，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，0 failures。
- `swift build -c release --arch arm64`：完成 arm64 production build。
- `git diff --check`：0 whitespace errors。

## Next boundary

H4.1e 建立产品目录的安全创建与 canonical catalog → bootstrap document projection builder：目录创建必须拒绝 symlink/错误 owner 并固定 `0700`；App 只从已加载的 catalog server 字段生成 next revision，不允许 Agent 反写 catalog。完成后仍需 HostAgent runtime single-writer lease（boot ID/build ID/config revision），才能把 Reader 接到 config-root/HostCore 启动顺序。
