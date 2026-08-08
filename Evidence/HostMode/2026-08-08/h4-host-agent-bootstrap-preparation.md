# H4.1e HostAgent product directory and catalog projection preparation

## Outcome

HostAgent bootstrap pipeline 现在能够安全创建固定产品目录，并把已加载的 canonical Viewer catalog 转换成 deterministic、server-only、无秘密的 Agent projection 文档。该文档可交给 H4.1d Publisher，但本步没有接入 App 生命周期或写入用户真实目录。

## Key evidence

- Preparer 从系统 user Application Support directory descriptor 开始，product/HostAgent 两层只使用 fixed component 的 `mkdirat/openat`，并带 `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`。
- Application Support 和兼容 `RustDesk Native Viewer` parent 必须是当前 euid directory，且 group/world 均不可写；既有 catalog parent 允许正常 `0755`，不会改动 catalog。
- 新建 product/HostAgent directory 强制 `0700`，创建后 `fsync` parent；重复 prepare 幂等。
- 既有 HostAgent directory 必须精确 `0700`；symlink、错误 type/owner、group/world writable 或 0755 均 fail closed，不自动修复可疑目录。
- projection builder 要求当前 catalog schema 与非空 server authority，只投影 rendezvous/public key、正整数 revision、build ID 和 schema。
- devices、peer ID、display name、forceRelay、password、token、private key 不进入 JSON；sorted JSON 对同一输入字节稳定。
- builder 输出再次由 H4.1b exact decoder 验证，unsafe whitespace、零 revision、控制字符 build ID 和未来 catalog schema 均 fail closed。

## Verification

- TDD RED：Preparer/ProjectionBuilder 测试先因生产类型不存在而编译失败。
- 定向 existing-catalog/idempotent prepare、product/agent symlink、loose permission、deterministic server-only projection、missing/future/unsafe input：5 tests，0 failures。
- 参数重命名后定向编译先捕获一处旧 label，修正后同一 5 tests 重新通过。
- 完整 `swift test`：155 tests，4 conditional skips，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，0 failures。
- `swift build -c release --arch arm64`：完成 arm64 production build。
- `git diff --check`：0 whitespace errors。

## Next boundary

H4.1f 建立 App-owned publication coordinator：从已加载 catalog、稳定 product build ID 与持久 monotonic revision 生成 projection，按“prepare → build → publish”调用，并确保 catalog 保存失败不推进 revision、publication 失败不让 Agent 使用未对账配置。该 coordinator 仍不启动 HostCore；之后再实现 Agent runtime single-writer lease 与 config-root-first 启动顺序。
