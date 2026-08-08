# H4.1j owned HostAgent bootstrap context

## Outcome

HostAgent 启动前的三个 authority 已组合为单一 process-lifetime owner：H4.1h strict preflight 先取得 immutable configuration，随后生成本进程唯一 Agent boot UUID，最后以同一 configuration/boot ID 获取 H4.1i single-writer lease。

产品只暴露无参数 `HostAgentBootstrapContext.prepare()`；磁盘路径、expected build ID 和 deterministic UUID 注入均保持 `ConnectionCatalog` module-internal 测试边界。Context 同时持有 configuration、boot ID 与 lease record，未来 Host runtime 必须在整个生命周期强持有它。

## Key evidence

- revision 7/build `build-7` projection 产生与 deterministic boot UUID 精确匹配的 context 与 lease record。
- context 活跃时第二 context 返回 `alreadyHeld`，live record exact bytes 保持。
- 已释放的 stale lease record 存在时，将 projection 损坏为 `{}` 后 prepare 传播 strict `invalidDocument`；stale record 和 corrupt projection bytes 都不变，证明 preflight 发生在 lease write 前。
- Context 没有公开 early-release 方法；owner 离开作用域后 lease 随属性析构释放，下一 boot context 可立即获取并更新 record。
- configuration、boot ID 与 record 都来自同一次 prepare，不能由产品调用方分别传入。
- 测试只操作 UUID 临时目录、synthetic `.invalid` server/public key，不读取真实产品配置或密钥。

## Verification

- TDD RED：bootstrap context 类型不存在，定向测试先编译失败。
- 定向 binding/contention、preflight-before-lease、context deinit/reacquire：3 tests，0 failures。
- `swift test`：174 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Remaining boundary

本步没有从 `--host-agent` 建立 context，也没有 dlopen Core、切换 Rust config root 或创建 HostCore。下一小步 H4.1k 将建立 config-root-first Host runtime bootstrap：context 必须先存在，随后在任何 Rust `Config` lazy initialization/Host create 前设置固定 `FarPaneHost`/`io.rustdesknative` root；启动失败需在 context 析构前有序清理 client。该顺序通过 built-core contract 后，才可替换当前 exit 69 fail-closed stub。
