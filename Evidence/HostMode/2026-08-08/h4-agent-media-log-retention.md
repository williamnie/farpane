# H4.1y Agent media log retention

## Outcome

Host media live-log 默认创建路径现在执行固定 retention：单写者进程最多保留 24 个 FarPane route JSONL，并在每次新建前淘汰修改时间超过 7 天的旧文件。删除计划无法完成时，新日志 fail closed 不创建，避免长期 route churn 继续无界增加诊断文件。

## Key evidence

- 产品默认值固定为 24 files / 7 days；新 route 创建前先把符合条件的既有文件收敛到最多 23 个，再创建第 24 个。
- 候选文件必须同时满足 `host-media-live-...-<UUID>.jsonl` 命名、当前 effective user 所有、普通文件且 link count 为 1；其他 JSONL、目录、symbolic link、hard link 和不同命名文件均不删除。
- retention 按 modification date 排序，先删除超过 7 天的 stale 文件，再删除超出数量上限的最旧 recent 文件；同时间戳使用文件名提供 deterministic tie-break。
- 淘汰使用只删除单个目录项的 POSIX `unlink`；即使 metadata 校验后路径被替换成目录，也只会失败，不会进入 `FileManager.removeItem` 的递归目录删除语义。
- 无效数量/期限在创建目录或文件前拒绝；目录枚举、metadata 读取或任一删除失败统一收敛为 `retentionFailed`，不保留或输出底层路径/Error。
- 显式 `HostMediaTelemetryLiveLogWriter(outputURL:)` 不执行自动清理，只有产品 `makeDefault()` 路径采用 retention，避免测试、导出或调用方指定文件时产生意外删除。
- 测试在 UUID 临时目录中真实创建并淘汰旧产品日志，同时验证 unrelated file、symbolic link、hard link 和 matching directory 保持；注入删除失败后确认没有创建新文件。没有读取、改写或删除用户真实 `~/Library/Logs/FarPane/HostMedia` 内容。
- H4 single-writer lease 是并发 authority；retention 不新增第二个跨进程锁，也不修改 config、ABI、XPC、Hermes 或密钥边界。

## Verification

- TDD RED：package-scoped product-directory factory、retention errors 和 policy 尚不存在时，3 个新增测试按预期编译失败。
- 定向 retention/live-log tests：5 tests，0 failures。
- `swift test`：270 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一小步继续 H4.1 产品入口收敛：在保持 `--host-agent` fail closed 的前提下，先对实际入口所需的 event/snapshot/media owner 组合与 terminal result 做完整 preflight audit，确认不存在 XPC/注册前必须解决的生命周期缺口，再决定启用无 AppKit run loop 的最小边界。H4.2 SMAppService、H4.3 authenticated XPC、真机后台日志和 GUI 自退根因仍未验收。
