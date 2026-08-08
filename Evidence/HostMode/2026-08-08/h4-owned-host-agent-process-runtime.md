# H4.1l owned HostAgent process runtime composition

## Outcome

HostAgent 现在有一个未启用的产品装配边界，把 H4.1j 的 bootstrap context/单写者 lease 与 H4.1k 的已启动 Core runtime 组合为同一 owner。所有退出路径都先停止 Core，再释放 bootstrap context，因此不会在 HostCore 尚存活时让第二个 Agent 抢到 lease。

## Key evidence

- `HostAgentOwnedCoreRuntime` 在同步 factory 调用期间保留 bootstrap owner；只有 factory 返回已启动的 `HostAgentCoreRuntime` 才构造组合 owner。
- 显式 stop 在锁内一次性 claim 并清空 runtime/context，锁外 teardown；重复 stop 不再进入 Core。
- 正常 stop 与 stop 抛错都显式按 `runtime = nil → bootstrap owner = nil` 释放，析构路径使用同一逻辑并以 `appExit` 停止。
- `HostAgentProcessRuntime.start` 先执行无参数产品 `HostAgentBootstrapContext.prepare()`，再在 owner factory 内创建 `HostControlClient`。
- config root、organization、rendezvous server 与 server public key 全部来自 `context.configuration`；装配 API 不接受第二套 namespace/server 值。
- source contract 同时确认 `RustDeskNativeApp.swift` 尚未调用该装配层且仍保留 `HostAgentBootstrap.failClosed()`，所以本步不会意外启动后台 Core。
- 测试只使用 recording fake 与 `.invalid` server/占位 public key；不加载 dylib、不联网、不读取用户配置或密钥。

## Verification

- TDD RED：组合 owner 不存在时，4 个生命周期测试编译失败；装配源不存在时 source-contract 测试按预期失败。
- 定向生命周期测试：4 tests，0 failures。
- 定向 executable source contract：1 test，0 failures。
- `swift test`：184 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Remaining boundary

`HostAgentProcessRuntime` 仍未选择 packaged Core dylib，也没有无 AppKit Agent run loop、结构化启动错误或 authenticated XPC 控制面；`--host-agent` 继续固定 exit 69。这些边界就绪前不得把“可构造”冒充“后台 ready”。下一小步应冻结产品 Core dylib 的不可注入定位与兼容预检，再考虑接入 Agent 入口和生命周期。
