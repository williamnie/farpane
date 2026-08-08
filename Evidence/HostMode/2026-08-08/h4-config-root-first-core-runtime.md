# H4.1k config-root-first Host Core runtime gate

## Outcome

CoreBridge 现在提供独立 `HostAgentCoreRuntime` owner，把 HostCore 初始化收敛为严格 `setConfigRoot → start`。Runtime 只在两步都成功后构造，因此调用方不可能拿到“未隔离 config root 但看似可运行”的 owner。

最小 `HostAgentCoreControlSurface` 由现有 `HostControlClient` 直接实现。协议要求 concrete start 在抛错前清理 partial create；当前 client 在 `rdn_shim_host_start` 失败时先 destroy handle，stop 同样先清空/destroy 再传播结果。

## Key evidence

- 成功路径精确记录 `setConfigRoot(FarPaneHost, io.rustdesknative) → start(server) → stop(reason)`。
- config-root 失败只发生一次 root 调用，绝不触发 start 或 speculative stop。
- start 失败保留 `root → start` 顺序，不构造 runtime，也不额外 stop 已由 concrete client 清理的 partial handle。
- 显式 stop 幂等：首个 reason 生效，后续 stop 不重复进入控制面。
- 未显式 stop 的 runtime 析构时以 `appExit` 有序停止。
- stop 抛错后仍禁止第二次 teardown，符合现有 HostControlClient 已销毁 handle 后才抛错的生命周期。
- 测试使用 recording fake 和 synthetic `.invalid` server/public key，不加载 dylib、不联网、不读取密钥。

## Verification

- TDD RED：runtime/control-surface 类型不存在，定向测试先编译失败。
- 定向 order、root/start failure、explicit/deinit/throwing stop：5 tests，0 failures。
- `swift test`：179 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Remaining boundary

本步的 Core runtime 尚未由 H4.1j context 拥有，config namespace/server 仍是调用参数；它也没有被 `--host-agent` 执行。下一小步 H4.1l 在 executable orchestration 中先建立 context，再加载兼容 core client，并只从 context configuration 传入固定 namespace/server 构造 runtime；owner teardown 必须先释放 runtime、后释放 context lease。完成 built-core 顺序/失败测试后，才可考虑替换 exit 69 stub 并进入无 AppKit Agent run loop。
