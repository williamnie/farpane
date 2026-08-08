# H4.3d3 App-side snapshot-first XPC session client

## Outcome

新增独立、尚未接入 UI 的 App 侧 XPC snapshot session client。它只连接固定 HostAgent Mach service，先完成严格 wire handshake，再取得同一 Host/boot 下的权威 snapshot；不兼容、畸形、身份不一致、超时与连接结束均 fail closed，迟到 reply 不能恢复已终止会话。

## Key evidence

- 产品 factory 从 `HostAgentRegistrationBundlePreflight.inspectMainBundle()` 取得实际 App build identity，并只使用 `HostAgentXPCListenerFactory.machServiceName` 与 `HostAgentXPCSnapshotInterfaceFactory.makeInterface()`；不存在环境变量、UserDefaults、任意 service name/path 或 fallback interface。
- 每个 client 只允许一次 `start`，状态严格经过 `idle → handshaking → fetchingSnapshot → deliveringSnapshot → ready`。snapshot request 只有在 handshake response 与 request 完整相关且协商为 compatible 后才发送。
- snapshot response 必须与 request 的 request ID、wire version、Host instance 和 agent boot ID 完整相关；malformed/nil/uncorrelated response 结束为 `invalidResponse` 并失效连接，不发布部分数据。
- client 保存上一份 Agent build/Host/boot identity。首次连接标记 first observation；完全相同 identity 标记 unchanged；任一字段变化均标记 replacement，并在 ready completion 前同步调用旧 UI intent reset callback。
- handshake 与 snapshot request 分别受 5 秒 timeout 保护。cancel、interruption、invalidation、重复 start 都只产生一次 terminal result；每个 request 的迟到 reply 由 request/state correlation 丢弃，不能把 failed/disconnected/cancelled session 重新推进到 ready。
- ready 后连接结束只触发一次独立 lifecycle callback，供未来 owner 建立新 client 并重新执行 snapshot-first，而不是沿用旧 cursor 或旧 pending intent。
- `NSXPCConnection` transport 用一次性 reply relay 合并 remote error 与正常 reply，避免双 completion；测试通过真实 anonymous listener/connection 调用 H4.3d2 handler，验证生产 transport 的 handshake→snapshot 往返得到 `lastEventID=9` 的 ready snapshot。
- 本步不接 App UI/readiness/controller，不定义 event subscription 或 Host command，不启用 `--host-agent` 顶层入口；未修改 Host Control/Media ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused client tests 首次因 App client/transport/result/state 类型尚不存在而编译失败。
- client focused：9 tests，0 failures，包含生产 transport 的真实 anonymous XPC round-trip。
- 完整 `swift test`：395 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步从 H4.3 snapshot-first 的 `lastEventID` 边界继续，建立有界、严格相关的增量 event wire/subscription 合同；在 event catch-up 与 gap 行为可验证前，不把本 client 接入 App UI/readiness，也不开放 Host command 或顶层 Agent entry。
