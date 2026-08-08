# H4.1n sanitized structured Agent startup result

## Outcome

HostAgent 的未启用启动装配现在返回结构化 `Result`，而不是把任意 Swift/Rust/dlopen 错误直接拼到 stderr。成功值保留完整 runtime owner；失败值只含固定 kind，并由 kind 计算稳定 sysexits 与脱敏诊断。

## Key evidence

- `HostAgentStartupFailure` 不持有 underlying `Error`、字符串 payload、路径、服务器、public key 或 build ID。
- 固定映射：configuration unavailable → EX_CONFIG 78；ownership unavailable/already running → EX_TEMPFAIL 75；Core unavailable/incompatible → EX_UNAVAILABLE 69；runtime startup/internal → EX_SOFTWARE 70。
- 六条 diagnostic 都是固定英文句子，不含换行或控制字符；`description` 也只返回同一 sanitized diagnostic。
- 通用 runner 成功时不调用 classifier；factory 抛错时只将 Error 短暂交给 classifier，返回的 failure 不保留原错误。带 path/token 的 synthetic error 测试确认结果和 `String(describing:)` 均不泄漏。
- executable classifier 单独识别 `HostAgentSingleWriterLeaseError.alreadyHeld`；其他 lease/record 问题、bootstrap/config 问题、bundled Core 问题、HostControl load/ABI/commit 与 config-root/create/start 均进入对应稳定 kind，未知错误归 internal。
- `HostAgentProcessStartup.prepare` 通过现有 H4.1l/m 产品装配启动 runtime，并要求调用方提供未来事件 consumer；没有空 handler 静默吞事件。
- `RustDeskNativeApp.swift` 不调用该 prepare 层，仍保留 exit 69 stub；本步不会创建后台 Core、输出错误或联网。

## Verification

- TDD RED：failure/runner 类型不存在时 3 个 runner 测试先编译失败；concrete classifier 文件不存在时 source contract 先失败。
- 定向 runner：3 tests，0 failures；concrete classifier source contract：1 test，0 failures。
- `swift test`：194 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Remaining boundary

本步只建立“准备成功或结构化失败”，尚未决定成功 runtime 的无 AppKit wait/cancel ownership，也未将失败诊断写入 stderr/统一日志，更没有 authenticated XPC/状态投影。下一小步应实现可测试的 Agent lifetime gate：收到终止请求时只触发一次 Core stop，成功 runtime 在此之前保持强引用；该 gate 与事件/XPC 所有权明确后，才可考虑替换入口 exit 69。
