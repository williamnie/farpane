# H4.3e4f read-only background component health composition

## Outcome

新增 App-owned background health authority 与 product runtime composition，把固定 SMAppService registration observation 和 reconnect/projection 的 typed runtime evidence 合成为唯一、可观察、fail-closed 的 readiness view；composition 构造后 XPC reconnect owner 保持 idle。

## Key evidence

- readiness view 以独立 monotonic generation 原子携带 registration、projection generation、handshake、authoritative snapshot、Rendezvous 与稳定 failure；`ready` 仍复用 H4.2a policy，要求 registration enabled、compatible handshake、available snapshot 与 registered Rendezvous 同时成立。
- product composition 强持有唯一 health authority、projection authority 与 reconnect owner；projection observer 只映射 e4d 已验证的四项 component evidence，不复制 snapshot payload、identity、event、request、connection 或 transport error。
- 构造只调用固定 `HostAgentBackgroundServiceObserver.observeRegistrationStatus` 一次，并创建 inert reconnect owner；不调用 `start()`。后续 `refreshRegistration()` 每次只读一次 registration，不注册、取消注册、打开设置或启动 Agent/XPC。
- registration 撤销/approval/service unavailable 与 runtime regression 都经同一 recursive delivery gate 串行发布，立即撤回 ready；并发测试阻塞 ready observer 时，registration read/publication 必须等待，最终顺序稳定为 ready → notRegistered。
- 相同 projection generation 的完全相同 evidence 幂等忽略，较旧 generation 静默忽略；同 generation mutation、disconnected+available/registered 等不可能 tuple 永久进入 sanitized `invalidRuntimeEvidence`，后续 projection/registration 不能复活 ready。
- health generation 接近上限时以最终 generation 发布 `generationExhausted` 并撤回 runtime evidence，不使用 wrapping arithmetic 复活旧 generation。
- 本步不接 AppKit/SwiftUI/UI model，不定义 activation policy/Host command，不调用 reconnect owner start，不启用顶层 Agent entry。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService registration、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 health authority/runtime evidence/readiness view/product composition 不存在而编译失败；实现后转绿。
- background health focused：11 tests，0 failures；覆盖 conservative initial state、all-evidence ready、registration revoke/restore、runtime regression、serialized concurrent publication、duplicate/stale generation、same-generation mutation、不可能 tuple、projection mapping、inert product composition 与 source boundary。
- 完整 Swift 回归：463 tests，4 skipped，0 failures；`Test Suite 'All tests' passed`。
- 脚本回归：22 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/新增行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.3e4g 建立显式 App-side background activation owner：只能由明确的产品 Host enable/lifecycle intent 启动 e4f composition 的 reconnect owner，取消后停止观察且不可被迟到 callback 复活；仍不执行 SMAppService register/unregister，不接旧 in-process `HostControlClient`，也不启用顶层 Agent entry。
