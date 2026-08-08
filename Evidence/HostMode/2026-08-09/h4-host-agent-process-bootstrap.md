# H4.1ae HostAgent process bootstrap composition

## Outcome

建立仍未接入真实顶层 dispatch 的唯一无参数 HostAgent bootstrap，把入口资格、产品 runtime 与 terminal reporting 串成一个固定流程。

## Key evidence

- 通用 composition 严格先求值一次 entry assessment，再由既有 orchestrator 决定是否运行，最后把唯一 terminal result 交给 reporter 一次。
- rejection 路径调用顺序为 `assess → report`，runner 调用次数为零；typed failure 原样保持到 terminal result。
- eligible 路径调用顺序为 `assess → run → report`，同一 eligibility 只进入 product driver 一次；startup/process result 不被 bootstrap 改写。
- 产品 bootstrap 无参数绑定 `HostAgentProcessEntryPreflight.assessMainProcess()`、`HostAgentProcessProductEntry.run` 与 `HostAgentProcessTerminalReporter.report`，没有第二套 identity/runtime/diagnostic authority。
- composition 本身不执行 stderr I/O 或 process exit；产品绑定不读取 Bundle、环境变量、替代 path 或动态配置，也不使用 `.unavailable` 绕过真实结果。
- `RustDeskNativeApp` 仍只调用 `HostAgentBootstrap.failClosed()`，不调用本步 bootstrap、entry orchestrator、product entry 或 process runner，故 `--host-agent` 仍固定 69。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService registration、plist、CI、根依赖、根配置或数据库，未读取真实配置/密钥，未安装、部署或 push。

## Verification

- TDD RED：focused test 首次因 `HostAgentProcessBootstrapOrchestrator` 不存在而编译失败；实现后转绿。
- bootstrap composition focused：4 tests，0 failures、0 warnings；覆盖 rejection no-run、eligible exactly-once、调用顺序、真实 terminal reporter 与产品/真实入口 source boundary。
- debug executable disabled-entry smoke：`.build/debug/RustDeskNative --host-agent` 仍返回 69，并且只输出固定 unavailable 诊断。
- 完整 Swift 回归：500 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：22 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/新增行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.1af 在 pre-AppKit `--host-agent` 分支调用本步 bootstrap 并以其返回值退出；先以 rejection-path executable smoke 证明真实入口不初始化 AppKit、不触及 runtime，eligible 真机启动与退出生命周期仍须独立验收。
