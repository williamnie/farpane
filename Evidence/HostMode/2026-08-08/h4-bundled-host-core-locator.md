# H4.1m bundled Host Core immutable locator

## Outcome

HostAgent 的未启用产品装配层现在只会从 App 自身 `Contents/Frameworks/liblibrustdesk.dylib` 加载 Core。产品入口不再接受 library URL，也没有环境变量、当前工作目录、开发 Build 目录或相邻文件 fallback；测试用目录注入保持 CoreBridge module-internal。

## Key evidence

- 无参数 `HostAgentBundledCoreLocator.locate()` 的唯一根为 `Bundle.main.privateFrameworksURL`，文件名固定为 `liblibrustdesk.dylib`。
- Frameworks 必须为非 symlink directory，owner 只能是 root 或当前 euid，且不可 group/world writable。
- Core 必须与 Frameworks 同 owner、非空、single-link、非 symlink regular file，且不可 group/world writable。
- 缺失固定文件时，即使目录内存在其他 `.dylib` 也返回 `coreUnavailable`；symlink、hard link、宽权限和 symlinked Frameworks 均稳定拒绝。
- `HostAgentProcessRuntime.start` 先持有 bootstrap context/lease，再调用无参数 locator，随后才创建 `HostControlClient`；其 public/product assembly 不再接收路径。
- concrete client 继续在任何 config root 或 Host create 前验证 Host ABI v7、Host Media ABI v1，以及 viewer/host commit 都精确等于 pinned `6c578292e8ebbbec708b76986ba8c4bc7c509747`。
- `RustDeskNativeApp.swift` 仍未调用装配层并保留 exit 69 fail-closed stub，因此没有后台进程或网络副作用。

## Verification

- TDD RED：locator/error 类型不存在时，固定定位与不安全布局测试先编译失败；装配尚未调用 locator 时 source contract 先失败。
- 定向 locator：6 tests，0 failures；装配 source contract：1 test，0 failures。
- 当前 arm64 built Core 的 shim Host surface 与 concrete viewer/Host ABI loader：2 tests，0 failures，均实际执行且未 skip。
- `swift test`：190 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Remaining boundary

该 locator 不是 H4.5 代码签名、公证、Library Validation 或干净机 quarantine 验收，也没有无 AppKit run loop、结构化 Agent 启动状态或 authenticated XPC。下一小步应建立 Agent 启动结果的脱敏、结构化错误分类与可测试 process runner；在 run loop/XPC/状态所有权齐备前继续保留 exit 69。
