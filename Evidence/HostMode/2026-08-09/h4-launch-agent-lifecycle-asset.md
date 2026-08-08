# H4.2l signed LaunchAgent lifecycle asset

## Outcome

冻结完整 LaunchAgent identity/lifecycle contract，新增仓库 plist，并把它接入 universal App 的签名前打包链；本步不注册、安装或启动系统服务。

## Key evidence

- 本机 `launchd.plist(5)` 明确：`KeepAlive` 隐式触发首次 load；dictionary conditions 以 OR 组合；`Crashed=true` 只在 crash signal 退出时保持重启，找不到 keepalive 理由时回到 demand-based invocation。
- exact top-level allowlist 只有 8 个 key：Label、BundleProgram、ProgramArguments、MachServices、LimitLoadToSessionType、KeepAlive、ThrottleInterval、ExitTimeOut。
- session 固定为 `Aqua`，符合 V1 只支持已登录 GUI session 的边界；不声明 LoginWindow、Background 或多 session fallback。
- restart 固定为 `KeepAlive={Crashed=true}`。干净 HostAgent stop 不自动重启；之后 App 对固定 Mach service 的新连接可按需重新启动，注册状态无需改变。
- `RunAtLoad` 被明确禁止，因为 KeepAlive 已提供 load 语义且本机 man page 要求避免重复 speculative launch；SuccessfulExit、unconditional KeepAlive 和附加 condition 同样拒绝。
- `ThrottleInterval=10` 固定 crash-loop 节流，`ExitTimeOut=10` 给既有 DispatchSource SIGTERM teardown 有界宽限，之后由 launchd 执行最终 kill。
- EnvironmentVariables、stdout/stderr path、WatchPaths、ProcessType、Disabled 及所有未冻结 capability key 全部因 allowlist fail closed，不能把 server/key/path 或额外启动触发器塞进签名 plist。
- 仓库 asset 位于 `App/LaunchAgents/io.rustdesknative.viewer.host-agent.plist`；测试直接解析真实文件并通过同一 Swift preflight，不依赖重复 fixture 判断。
- `Scripts/build-universal.sh` 在 App codesign 前 lint source、复制到 `Contents/Library/LaunchAgents`、强制 0644、再次 lint 并 byte-compare；随后既有 deep/strict App signing verification 覆盖该 asset。
- 未调用 `SMAppService.register/unregister`、未修改系统 Login Items、未安装 App、未启动 eligible Agent；未修改 Host ABI、XPC wire、Rust、Hermes、CI、根依赖、根配置或数据库，未读取真实配置/密钥、未部署或 push。

## Verification

- TDD RED：Swift focused 首次因 `invalidLifecyclePolicy` 不存在而编译失败；脚本 focused 首次因 build script 未引用 LaunchAgent asset 而失败；实现后均转绿。
- LaunchAgent preflight focused：9 tests，0 failures、0 warnings；覆盖 exact asset、missing/mutated lifecycle、bool/integer type confusion、unfrozen keys、identity/argv/Mach service 与 malformed/oversized payload。
- registration identity gate focused：7 tests，0 failures、0 warnings；证明完整 lifecycle plist 仍按 plist→bundle→signature 顺序 fail closed。
- release metadata focused：1 test，OK；证明 asset source/target 与 copy-before-App-codesign 顺序。
- asset `/usr/bin/plutil -lint`：OK；`zsh -n Scripts/build-universal.sh`：通过。
- 临时 App bundle copy fixture：source/target plist lint、0644 mode 与 byte-for-byte compare 均通过。
- 完整 Swift 回归：505 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：23 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/新增行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.2m 建立显式用户 intent 驱动的 SMAppService registration mutation owner：注册前重跑 signed identity/lifecycle gate，区分 registered/requiresApproval/notRegistered/serviceUnavailable，并保持 register/unregister 与 Agent ready 独立；仍不自动注册真实系统服务。
