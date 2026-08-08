# H4.2i XPC listener code-signing gate

## Outcome

CoreBridge 现在可以为未来 HostAgent 构造唯一固定 Mach service 的未激活 `NSXPCListener`，并在任何 delegate、interface 或消息处理器存在前安装产品 code-signing requirement。这个步骤只建立 listener-level 第一层 peer identity gate，不启动 XPC runtime，也不定义 wire schema。

## Key evidence

- 本机 macOS 13+ Foundation SDK 的 `NSXPCListener.setConnectionCodeSigningRequirement` 合同明确：不满足 requirement 的新 peer 会在询问 delegate 前自动被拒绝。
- factory 的 Mach service 名称复用已冻结的 LaunchAgent label `io.rustdesknative.viewer.host-agent`，不接受 service name、listener type、environment 或 path override。
- listener requirement 直接复用 H4.2f 已验证的产品 requirement：Apple generic anchor、identifier `io.rustdesknative.viewer` 和固定 Team ID；registration 与 IPC 不再各自维护可能漂移的签名字符串。
- 定向动态测试证明固定 requirement 可以编译、真实 `/Applications/FarPane.app` 满足它，而系统 Calculator 的有效 Apple 签名不满足它。
- factory 返回的 listener 没有 delegate，源码中没有 anonymous/service listener fallback、`activate`、`resume`、interface、selector 或 exported object；构造本身不声明服务 ready，也不开始接收连接。
- 本步没有实现 §8.6/§14.1 剩余的 euid、PID、audit session/token 和安装路径 admission，没有 XPC handshake、snapshot、event、command、dedupe 或 rate limit，因此不能称为 authenticated IPC 完成。
- 未创建/打包 plist，未调用 ServiceManagement mutation，未启用 HostAgent 入口，未修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：listener tests 先因 `HostAgentXPCListenerFactory` 与共享 `productRequirement` 不存在而按预期编译失败。
- 定向 listener factory：4 tests，0 failures；覆盖固定 authority、requirement 编译、真实产品 accept、其他 Apple authority reject，以及未激活边界。
- `swift test`：320 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一安全小步是 listener delegate 的 connection metadata admission：只从 `NSXPCConnection` 的内核提供属性验证同 euid、有效 PID 与同 audit session，并在建立任何 exported interface 前 fail closed。动态 code identity 与精确 `/Applications/FarPane.app/Contents/MacOS/RustDeskNative` 路径仍需与该 admission 组合；完成这些之前 listener 不得 activate。
