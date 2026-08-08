# H4.1aa Agent terminal result reporting

## Outcome

HostAgent 的 process result 现在有唯一终端呈现路径：最多向指定 stderr sink 写一条固定脱敏诊断，并返回对应 sysexits。当前 pre-AppKit `--host-agent` fail-closed 分支已改用该路径，因此未来把结果来源替换为真实 `HostAgentProcess.run` 时，不需要再复制诊断和退出码逻辑。

## Key evidence

- package-scoped `HostAgentProcessTerminalResult.unavailable` 固定映射到 `EX_UNAVAILABLE` 69 和现有 build-unavailable 诊断；真实 runner result 通过 `.process(...)` 进入同一路径，成功 `stopped` 映射 0 且不写任何内容，不扩大 public runner enum。
- `HostAgentProcessTerminalReporter` 只消费已经结构化、无底层 Error 的 process result；输出至多为 `diagnostic + "\n"`，不接收路径、server、key、credential 或自由文本。
- stderr 已关闭或写入失败时不保留、不打印 Foundation Error，也不改变原始退出码，避免诊断通道反向篡改进程结果。
- `HostAgentBootstrap.failClosed()` 不再持有独立 exit 常量或诊断字面量，直接 `exit(HostAgentProcessTerminalReporter.report(.unavailable))`；mode dispatch 仍发生在 `NSApplication.shared` 前。
- 入口审计确认现有 runner 以 `DispatchSourceSignal` 接收 SIGTERM/SIGINT，并在 `HostAgentProcessLifetimeGate.waitUntilTerminated()` 的 condition wait 中阻塞；不需要创建 AppKit/CFRunLoop 或 busy loop。
- 本步没有调用 `HostAgentProcess.run`、读取 bootstrap projection、加载 Core 或联网；authenticated XPC 尚未建立，因此真实 Agent 继续 fail closed，不伪装 ready。
- 不修改 Host/Media ABI、XPC wire、Rust、Hermes、SMAppService、CI、根依赖或数据库；未安装、部署或 push。

## Verification

- TDD RED：新增 3 个 terminal reporter 测试先因 reporter 与 `.unavailable` result 不存在而按预期编译失败；入口 source contract 同时要求移除旧硬编码。
- 定向 terminal reporting + pre-AppKit contract：4 tests，0 failures。
- debug/release executable `--host-agent` smoke：两者均输出 exact 固定诊断并 exit 69。
- `swift test`：277 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

H4.1 的进程等待、structured result 和 terminal reporting 已具备；真实入口仍不能启用，因为当前没有 authenticated XPC listener/consumer 来持有并发布 event、snapshot 与 media component 状态。下一小步应进入 H4.3 的最小 wire-version handshake 合同，先冻结严格长度、类型和版本边界，不提前启动 HostCore 或注册 SMAppService。
