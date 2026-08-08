# H4.1q disabled HostAgent process runner composition

## Outcome

HostAgent 已有一个完整但仍未从产品入口启用的 process-lifetime runner。它组合现有安全启动、SIGTERM/SIGINT ingress 和 single-stop lifetime，并把全部终态压缩为固定 exit code 与脱敏 diagnostic。

## Key evidence

- `HostAgentProcessRunner` 严格先安装 termination ingress，再启动 runtime；ingress 安装失败时不调用 startup，也没有不存在的 ingress 可 cancel。
- ingress 安装成功后以 `defer` 保证所有返回分支恰好撤销一次；startup failure 不 bind、不 wait，并保留 H4.1n 的固定 sysexits/diagnostic。
- runtime 成功后才 bind；正常路径随后 blocking wait，terminal `stopped` 映射 exit 0/无 diagnostic，`stopFailed` 映射 EX_SOFTWARE 70 与固定英文诊断。
- bind 返回 false 被视为 orchestration invariant failure：runner 先以 `.error` 请求 single-stop；无论本次请求认领 runtime，还是已有请求正在 stop，都会等待已发布的 terminal outcome 后才撤销 signal ingress，避免 stop 窗口暴露恢复后的默认 signal disposition。
- ingress installation/bind invariant failure 都只返回固定 lifecycle error，不保留 underlying Error、路径、server/key/build ID 或自由文本。
- `HostAgentProcess` 接入真实 `HostAgentProcessSignalController`、`HostAgentProcessStartup`、`HostAgentProcessLifetime`，且要求调用方显式传入 `HostCoreEvent` consumer；没有默认 no-op consumer。
- 产品组合层不写 stderr、不调用 `exit`；`RustDeskNativeApp.swift` 仍只调用 `HostAgentBootstrap.failClosed()`，没有调用 `HostAgentProcess.run`。

## Verification

- TDD RED：`HostAgentProcessRunner` 不存在时 6 个 runner 测试编译失败；`HostAgentProcess.swift` 不存在时产品 source contract 以 file-not-found 失败。
- 定向 runner 6 tests + product source contract 1 test：7 tests，0 failures。
- `swift test`：211 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check：无 whitespace error。

## Remaining boundary

本步刻意不把 `--host-agent` 从 exit-69 stub 切到真实 runner。启用前仍需建立不丢弃 Host 事件的 Agent-owned event state/consumer，并增加独立子进程真实 SIGTERM/SIGINT smoke；否则即使 Core 已运行，也无法把后台状态和会话事件交给后续 authenticated XPC authority，不能声称后台 Host ready。
