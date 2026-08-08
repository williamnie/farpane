# H4.1ac HostAgent sanitized entry orchestration

## Outcome

建立 entry assessment 到 sanitized terminal result 的纯编排边界：拒绝不会运行 HostAgent，合法资格只会被 runner 消费一次；真实产品入口继续保持 fail closed。

## Key evidence

- 编排器对 assessment 只求值一次；五种 typed entry rejection 原样成为 `entryRejected`，runner 调用次数保持为零。
- eligible evidence 在 runner 前再次经过 bounded build identifier 校验；伪造 typed eligibility 映射为 `invalidApplication`，不会跨越 trust boundary。
- 合法 eligibility 被同一 runner closure 恰好消费一次，runner 的 stopped/startup failure structured result 不被重写或降级。
- entry failure 经唯一 terminal reporter 映射固定 sysexits：invalid invocation 为 64，invalid launch/application identity 为 78，invalid signature/notarization evidence 为 77。
- 每类 failure 只输出固定英文诊断；不插入参数、路径、build identifier、签名详情、Foundation/Security error 或其他动态值。stderr 已关闭/写失败时仍返回同一退出码。
- 纯编排 source 不引用 AppKit、ServiceManagement、环境变量、process exit 或真实 runtime。`RustDeskNativeApp` 仍调用 `HostAgentBootstrap.failClosed()`，不调用本步编排器或 `HostAgentProcess.run`。
- 未修改 Host Control/Media ABI、XPC wire schema/selector、Rust、Hermes、SMAppService registration、plist、CI、根依赖、根配置或数据库，未读取真实配置/密钥，未安装、部署或 push。

## Verification

- TDD RED：focused test 首次因 `HostAgentProcessEntryOrchestrator` 与 `entryRejected` 不存在而编译失败；实现后转绿。
- entry orchestration focused：7 tests，0 failures、0 warnings；覆盖全 rejection、不运行 runner、eligible exactly-once、runner failure preservation、forged eligibility、固定 terminal mapping、closed sink 与真实入口边界。
- 完整 Swift 回归：491 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：22 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/新增行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.1ad 建立仍不接入 `AppDelegate.main` 的 product entry driver：唯一拥有 process event/snapshot/media state，并在 eligible build identity、bootstrap context 与 runner authority 之间完成对账；真实顶层 dispatch 继续留在后续独立小步。
