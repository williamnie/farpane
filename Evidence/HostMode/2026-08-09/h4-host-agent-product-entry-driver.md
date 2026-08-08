# H4.1ad HostAgent product entry state/build ownership

## Outcome

建立仍未接入真实顶层 dispatch 的 product entry driver：每次 boot 只拥有一组 event/snapshot/media state，并让 entry eligibility 的 build identity 成为 bootstrap projection 与 lease 的同一对账依据。

## Key evidence

- `HostAgentProcessEntryStateOwner` 唯一强持有全新的 bounded `HostAgentEventState`、`HostAgentSnapshotState` 与 `HostAgentMediaControlState`；不同 owner 不复用任何 mutable authority。
- driver 再次验证 typed build identifier；伪造值在 state factory 与 runner 前 fail closed，state 构造 Error 不保留并稳定映射为 `internalFailure`。
- 合法路径只构造一次 owner、调用一次 runner，并把同一份 `HostAgentProcessEntryEligibility` 与同一 owner 传入 product composition。
- product composition 把 eligibility build ID 逐层传过 `HostAgentProcess → HostAgentProcessStartup → HostAgentProcessRuntime → HostAgentBootstrapContext`；secure projection 必须 exact match 后才可能获取 lease。
- expected-build bridge 仅为 package scope，不接受路径、环境变量、Bundle dictionary 或配置 payload，也不改变既有无参数公开 product preflight。
- 已被 process-owned journal、snapshot refresh、media control/pipeline/diagnostics 覆盖的外部 event/media forwarding seam 已删除；accepted event 仍固定先 journal，再交给所有内部权威消费者。
- `RustDeskNativeApp` 仍只调用 `HostAgentBootstrap.failClosed()`，不调用 product entry、entry orchestrator 或 process runner，故本步没有读取真实配置、加载 Core、联网或启动 Agent。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService registration、plist、CI、根依赖、根配置或数据库，未读取真实配置/密钥，未安装、部署或 push。

## Verification

- TDD RED：focused test 首次因 `HostAgentProcessEntryStateOwner` 与 `HostAgentProcessEntryDriver` 不存在而编译失败；实现后转绿。
- entry driver focused：5 tests，0 failures、0 warnings；覆盖 fresh state authorities、factory/runner exactly-once、identity preservation、state failure、forged eligibility 与真实入口边界。
- bootstrap exact-build focused：3 tests，0 failures、0 warnings；覆盖 exact match、mismatch、invalid identifier-before-I/O 与 projection preservation。
- process composition contract：34 tests，1 skipped、0 failures、0 warnings；覆盖 journal-first internal consumer 顺序、bootstrap-before-Core、snapshot/media/diagnostic ownership 与入口禁用。
- lease-bound XPC identity focused：5 tests，0 failures、0 warnings；覆盖 expected build preflight、lease build/boot identity、initial snapshot bind 与 terminal invalidation ordering。
- 完整 Swift 回归：496 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：22 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/新增行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.1ae 组合 `entry preflight → sanitized orchestrator → product entry driver → terminal reporter` 为仍未从 `AppDelegate.main` 调用的单一 process bootstrap 函数；真实顶层 dispatch 继续留在后续独立小步。
