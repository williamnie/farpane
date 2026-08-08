# H4.1h HostAgent immutable launch preflight

## Outcome

HostAgent 现在有独立的只读 launch preflight，可在任何 single-writer lease、Rust config lazy initialization 或 HostCore create 之前取得并校验 immutable bootstrap configuration。

产品入口只从 `Bundle.main` 读取 packaged `CFBundleVersion`，并只从 user Application Support 下 H4.1e 固定布局读取 H4.1c 文档；不开放路径、build ID 或 config namespace 的命令行/环境变量入口。测试所需注入保持 `ConnectionCatalog` module-internal。

## Key evidence

- 已发布 revision 7/build `build-7` 时，preflight 返回同一 strict configuration、server 与固定 `FarPaneHost`/`io.rustdesknative` namespace。
- expected build 不同返回 typed `buildIdentifierMismatch`，projection exact bytes 保持。
- 空、空白污染、含 `/` 或超过 128 UTF-8 bytes 的 expected build 在不存在的 Application Support fixture 上仍先返回 `buildIdentifierUnavailable`，证明无效 build 不触发磁盘读取。
- `{}` corrupt projection 传播 H4.1b `invalidDocument`，不被误判为首次启动，原字节保持。
- Reader 已有的 symlink、owner、mode、hard-link、size 与 fixed-name 安全门禁未被 preflight 绕过或降级。
- 测试只使用 UUID 临时目录、`.invalid` server 与 synthetic public key，不读取真实 catalog、projection 或密钥。

## Verification

- TDD RED：preflight/error 类型不存在，定向测试先编译失败。
- 定向 valid/mismatch、invalid-build-before-I/O、corrupt preservation：3 tests，0 failures。
- 共享 build-ID authority 既有 product integration 回归：3 tests，0 failures。
- `swift test`：165 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Remaining boundary

本步没有让 `--host-agent` 调用 preflight，因此仍固定 exit 69；也没有读取或初始化 Rust Host config。下一小步 H4.1i 是专用 single-writer lease：锁记录绑定 boot ID、build ID 与 config revision，第二进程/旧 build/旧 revision fail closed，lease 必须覆盖 config-root switch、HostCore 生命周期及有序停止。该 lease 通过后，才能把 preflight + lease + config-root-first 串成实际 Agent bootstrap 顺序。
