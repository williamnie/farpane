# H4.1a HostAgent pre-AppKit mode dispatch

## Outcome

FarPane executable 现在识别精确的 `--host-agent` process role，并在首次访问 `NSApplication.shared` 之前分流。普通 Viewer/Host App 参数继续进入现有 AppKit 路径；`--host-agent=false` 等相似参数不会意外改变角色。

H4 专用配置所有权、单写者锁和 authenticated XPC runtime 尚未实现，因此 Agent 分支当前明确以 `EX_UNAVAILABLE`（69）fail closed 退出。它不会创建 `NSApplication`、Dock 图标、菜单或窗口，也不会启动第二个 HostCore、读取 Viewer 配置或伪装后台 ready。这是 H4.1 的安全 bootstrap 子步骤，不代表 HostAgent 已可用。

## Key evidence

- `RustDeskNativeProcessModePolicy` 是不依赖 AppKit 的纯参数策略，只接受 exact `--host-agent`。
- `AppDelegate.main()` 在 `NSApplication.shared` 与 `AppDelegate()` 之前解析 role；Agent 分支直接进入 `HostAgentBootstrap.failClosed()`。
- bootstrap 输出固定脱敏诊断，不包含路径、配置、身份、server、key 或 credential，然后以 sysexits `EX_UNAVAILABLE` 值退出。
- 在 XPC/config ownership 准备好前没有引入无效常驻 run loop，也没有复用当前 in-process Host 启动链；这避免双 HostCore 争用 identity/port/config。

## Verification

- TDD RED：process-mode 测试先因缺少 `RustDeskNativeProcessModePolicy` 编译失败；源码顺序测试先缺少 dispatch/bootstrap 标记。
- 定向 mode policy 1/1、pre-AppKit source contract 1/1 通过。
- debug executable smoke：`.build/debug/RustDeskNative --host-agent` 输出固定 unavailable 诊断并退出 69。
- 完整 `swift test`：139 tests，4 conditional skips，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，0 failures。
- `swift build -c release --arch arm64`：完成 arm64 production build。
- release executable smoke：`.build/arm64-apple-macosx/release/RustDeskNative --host-agent` 输出固定 unavailable 诊断并退出 69。
- `git diff --check`：0 whitespace errors。

## Next boundary

H4.1b 需要在继续驻留前建立 HostAgent 专用 bootstrap configuration contract：不能调用 `Config::*` 或启动 HostCore，直到 Host config root/server authority、build/config revision 与单写者锁输入均完成验证。之后再接 H4.3 authenticated XPC listener；在此之前顶层 `hostAvailability` 只能报告 unavailable，不能声称 ready。
