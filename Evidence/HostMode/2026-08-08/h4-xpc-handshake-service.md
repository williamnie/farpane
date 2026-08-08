# H4.3b Clang-backed XPC handshake interface and handler

## Outcome

CoreBridge 现在具有可由 `NSXPCInterface` 安全构造的最小 handshake service interface，以及只处理 H4.3a 严格 Data contract 的 immutable handler。该 service 仍未绑定到 connection/listener；H4.2k 继续拒绝所有连接，当前没有新增可达 IPC surface。

## Key evidence

- 本机 macOS SDK/运行探针证明纯 Swift `@objc protocol` 缺少 Clang extended method signature，传给 `NSXPCInterface` 会抛 `NSInvalidArgumentException`；产品 contract 因此由 `CoreBridgeShim` 的 Objective-C header 提供真实协议 metadata。
- `RDNHostAgentXPCHandshakeService` 只有一个 required selector：`performHandshakeWithRequestData:reply:`；参数固定为 nonnull `NSData`，reply 固定为 nullable `NSData`。没有 collection、任意 object、URL、Error、proxy 或第二个 selector。
- interface factory 只从上述固定 Clang protocol 构造 `NSXPCInterface`，没有 name/protocol/selector 注入；动态测试真实构造 interface 并核对 protocol 与 selector。
- handler 只持有经 H4.3a token/UUID/build-ID 规则验证的 immutable Agent identity 和 sendable clock；不持有 listener、connection、HostCore、文件或配置。
- 每次调用只执行 H4.3a bounded decode→固定本地版本协商→bounded encode，并同步调用 reply 恰好一次。合法 offer 返回 correlated compatible response；无共同版本返回 typed incompatible response。
- 空、畸形、超 8 KiB request，future/错误 schema，非法 identity、无效 clock 或编码失败全部只返回 nil；不跨 wire 发送 Foundation/JSON/路径/身份底层错误。
- 本步没有把 interface/exported object 安装到 connection，不 accept/activate/resume listener，不定义 snapshot/event/Host command，不改变 H4.2k 的全拒绝计数或后台 readiness。
- 未修改 Host Control/Media C ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：service tests 先因 interface factory/handler/Agent identity 不存在而按预期编译失败。
- 定向 service：6 tests，0 failures；覆盖真实 interface construction、唯一 selector/类型边界、compatible/incompatible、single reply、malformed/oversize/invalid identity/clock 和源码无 connection/activation surface。
- 新增 umbrella header 后清理可再生 SwiftPM `.build` module cache；随后 clean compile 证明 Clang protocol 可被 CoreBridge 导入。第一次 focused GREEN 仅因测试字符串与头文件的 `*)` 拼写不一致失败，修正断言后 6/6 通过；产品实现未因该断言调整。
- 完整 `swift test`：346 tests，4 skipped，0 failures。
- ScriptTests：22 tests，0 failures。
- `swift build -c release --arch arm64`：成功；production compile 重新构建 `rdn_shim.c` 并导入新增 Clang protocol header。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3c 才能改造 H4.2k admission owner：为 identity-eligible connection 安装固定 handshake interface/handler、设置 interruption/invalidation 清理并 resume 单条 connection，同时仍禁止 handshake 前 snapshot/event/Host command。该步必须从真实 process runtime 提供 build ID、current Host instance ID 与 process-lifetime agentBootId；在这些 authority 未绑定前 listener 继续全拒绝。
