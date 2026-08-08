# H4.2c SMAppService read-only observer

## Outcome

CoreBridge 现在有一个 package-scoped 产品 observer，以唯一固定名称 `io.rustdesknative.viewer.host-agent.plist` 定位 App Bundle 的 `Contents/Library/LaunchAgents` 服务，并只读取 `SMAppService.status`。它把结果交给 H4.2b adapter，不具备注册、取消注册或打开系统设置的能力。

## Key evidence

- plist name 与 §4.3 冻结的 LaunchAgent label/Mach service 同源，不接受参数、环境变量、URL、当前目录或 Bundle path override。
- 本机 SDK 明确 `SMAppService.agent(plistName:)` 只对应调用 App 的 `Contents/Library/LaunchAgents/<plistName>`；真正可能 bootstrap/kill 服务的是独立 register/unregister API，本 observer 未调用这些 API。
- observer 的产品路径只有 `SMAppService.agent(plistName: plistName).status → HostAgentSMAppServiceStatusAdapter.map`；不存在 service object escape 或 mutation method。
- 动态测试确认 SwiftPM test bundle 中固定 plist 不存在时，真实 observer 返回 `serviceUnavailable`，不会把 missing service 猜成 notRegistered/enabled/ready，也未创建文件或注册项。
- 固定 plist 名只定位 bundle 内 signed asset；本步尚未创建该文件，也不定义其 launchd keys、build ID/signature preflight 或升级语义。
- 返回值仍只是一份 registration evidence；H4.2a 的 handshake/snapshot/Rendezvous 条件没有被旁路。
- 所有新增类型保持 package scope；不定义 XPC message/schema，不新增 command、selector、payload 或公共 ABI。
- 不修改 Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：3 个 observer tests 先因 `HostAgentBackgroundServiceObserver` 不存在而按预期编译失败。
- 定向 observer tests：3 tests，0 failures；含真实 missing test-bundle service 的 read-only status smoke。
- `swift test`：287 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一小步应先建立 LaunchAgent plist 的纯数据 preflight：严格校验 label、MachServices、同 executable 的 `--host-agent` arguments、bundle-relative program 与禁止 LaunchDaemon/root keys；在 validator 和 packaging tests 完成前，不把 plist 加入产品 bundle，也不允许 register/unregister。
