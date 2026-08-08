# H4.1c HostAgent secure bootstrap reader

## Outcome

HostAgent bootstrap configuration 现在具备独立的安全读取门禁。上层产品 authority 只提供目录，Reader 固定读取 `bootstrap-v1.json`；目录 URL 不来自 wire，也不能由文档字段或环境变量覆盖。

本步只实现读取，不选择最终产品存储根、不发布真实配置，也不启动 HostAgent。现有 `--host-agent` 分支继续以 `EX_UNAVAILABLE`（69）fail closed。

## Key evidence

- 目录先以 `open(... O_DIRECTORY | O_NOFOLLOW)` 打开，再以 `openat(... O_NOFOLLOW)` 打开固定文件名；验证与读取发生在同一文件描述符上，避免 pathname check/read TOCTOU。
- 目录必须是当前 euid 所有、权限精确为 `0700` 的 directory。
- 配置必须是当前 euid 所有、权限精确为 `0600`、link count 为 1 的 regular file。
- file/directory symlink、目录伪装、硬链接、0644 文件、0755 目录、缺失文件和非 regular file 均 fail closed。
- 文件大小在 `fstat` 后先检查，descriptor read 仍以 64 KiB + 1 的硬上限防止读取期间增长；成功读取后继续执行 H4.1b exact schema decoder。
- 错误只暴露稳定分类，不包含路径、owner、errno、server、公钥或 credential。

## Verification

- TDD RED：Reader 测试先因生产类型不存在而编译失败。
- GREEN：固定私有 regular file、缺失/symlink/non-regular、权限/硬链接/目录安全三组测试通过。
- macOS 回归：目录 symlink 在 `O_DIRECTORY | O_NOFOLLOW` 下返回 `ENOTDIR`；实现将其与 `ELOOP` 一并稳定归类为 `insecureDirectory`，定向测试重新通过。
- 完整 `swift test`：145 tests，4 conditional skips，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，0 failures。
- `swift build -c release --arch arm64`：完成 arm64 production build。
- `git diff --check`：0 whitespace errors。

## Next boundary

H4.1d 选择并记录 canonical bootstrap projection 的产品目录，然后实现同目录私有临时文件、完整写入、`fsync`、atomic replace、目录 `fsync` 与 monotonic revision compare。该发布边界完成并获得单写者 lease 前，不能把 Reader 接到 HostCore 启动链。
