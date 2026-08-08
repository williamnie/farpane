# H4.1f App-owned bootstrap publication coordinator

## Outcome

App-owned bootstrap pipeline 现在有一个固定布局 coordinator，将 H4.1e prepare/build 与 H4.1d publish 串成单一调用。现有 projection 本身是 durable monotonic revision authority，不新增 UserDefaults、数据库或第四份 revision metadata。

本步没有接入产品 App lifecycle；测试只使用 UUID 临时 Application Support。Coordinator 要求调用方传入已经成功加载/保存的 canonical catalog 与稳定 product build ID，不读取或反写 catalog，也不启动 HostCore。

## Key evidence

- projection 缺失时首次 revision 为 1；existing projection 必须先通过 H4.1c/H4.1b 安全读取与 strict decode。
- rendezvous/public key 或 Agent build ID 变化时 revision 精确 `+1`；达到 `2^53-1` 后返回 `revisionExhausted`，不溢出或覆盖。
- device、peer ID、display name 与 Viewer-only forceRelay 改变不会改变 Agent projection，也不推进 revision。
- semantic unchanged 仍构造当前 revision deterministic document 并进入 Publisher lock，由 exact bytes/revision 返回 unchanged；不在 lock 外报告成功。
- 损坏 projection 会传播 strict decoder error，旧字节保持；不把 corruption 当作“首次发布”。
- publication lock busy 会传播 `publicationBusy`，durable projection 仍保持旧 revision/server；下一次调用可从旧 authority 重试。
- Coordinator 不保存 catalog、不解析 Bundle、不写 Rust config；调用方必须先完成 canonical catalog save，再提供 stable build ID。

## Verification

- TDD RED：Coordinator/Outcome/Error 测试先因生产类型不存在而编译失败。
- 定向 first/idempotent/server+build progression、corrupt+revision exhaustion、publication busy preservation：3 tests，0 failures。
- viewer-only catalog fields/devices 变化保持 revision 1 unchanged 的补充回归通过。
- `swift test`：158 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Next boundary

H4.1g 接入产品 App：从 `CFBundleVersion`/正式 build metadata 得到有界 stable build ID，仅在 canonical catalog 已成功 load/save 且 server 完整时调用 Coordinator；启动时已有 server 需要补发布，server 设置更新则先保存 catalog、后发布 projection。publication 失败必须呈现 Host component unavailable/degraded，不能影响 Viewer catalog 成功或让 Agent 使用未对账新配置。完成后再实现 Agent runtime single-writer lease 与 config-root-first 启动顺序。
