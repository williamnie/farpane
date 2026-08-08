# H4.1ab HostAgent top-level entry eligibility preflight

## Outcome

新增只读 HostAgent process entry preflight，在未来 `--host-agent` 顶层 dispatch 之前组合 exact invocation、固定嵌入 LaunchAgent asset、安装包 identity 与签名 channel；当前入口仍固定 fail closed，不启动真实 runner。

## Key evidence

- invocation 只接受两个精确 shape：`RustDeskNative --host-agent`（匹配已冻结 LaunchAgent argv）或 `/Applications/FarPane.app/Contents/MacOS/RustDeskNative --host-agent`；参数数量必须为 2。
- 缺失/重复/额外 flag、`--host-agent=false`、NUL lookalike、fixture 混合参数、相对 executable、搬移路径、名称后缀和可归一化 `..` 别名均返回稳定 `invalidInvocation`，且不读取 bundle/plist/signature。
- invocation 通过后只调用既有固定 `HostAgentRegistrationIdentityGate.assessMainBundle()`：descriptor-relative 读取嵌入 plist，然后验证 `/Applications/FarPane.app` metadata 与固定 Team/signing requirement，没有第二套 identity authority。
- local development eligibility 再复核 bounded build identifier 后才输出 typed eligibility；invalid launch asset/application/signature 分别映射稳定枚举，不保留 Security/Foundation error、路径或签名原始数据。
- Developer ID 当前固定映射 `distributionNotarizationRequired`；H4.5 尚无 stapled/notarization authority 时不允许“签名通过”冒充可运行分发 Agent。
- product entry 不接受 path、arguments、identity、plist、bundle 或 signature override；测试注入只属于 package-scoped pure assessment seam。
- 本步不调用 `HostAgentProcess.run`、startup/runtime、AppKit/SwiftUI、UserDefaults 或 ServiceManagement mutation；`RustDeskNativeApp` 仍走 `HostAgentBootstrap.failClosed()` 并报告 69。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService registration、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused tests 首次因 entry preflight/assessment/eligibility/failure 类型不存在而编译失败；实现后转绿。
- entry preflight focused：8 tests，0 failures、0 warnings；覆盖 exact invocation、argument/executable rejection、identity stage mapping、Developer ID notarization gate、forged build token、product assessment 与 source boundary。
- 完整 Swift 回归：484 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：22 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/新增行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.1ac 建立 entry assessment → sanitized process terminal result/exit code 映射，并用纯 orchestration 测试证明 rejection 不触发 runner、eligible 才恰好调用一次；仍不在真实 `AppDelegate.main` dispatch，也不启动、安装或注册 Agent。
