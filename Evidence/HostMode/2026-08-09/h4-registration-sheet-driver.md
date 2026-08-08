# H4.2p AppKit registration sheet driver

## Outcome

实现编入 FarPane executable 的 AppKit 单-sheet driver，并以独立纯 policy 把 H4.2o 两类 prompt 的肯定/取消响应映射为 typed intent；本步没有 AppDelegate/Home 调用点。

## Key evidence

- driver 只能由显式 `begin(on:)` 启动；构造 `makeProduct()` 仅组合 inert H4.2o owner，不请求 prompt、不显示 sheet、不调用 registration/navigation。
- `begin` 要求 main thread、单次 start、无 active sheet；H4.2o 发布 awaitingConfirmation 后，driver 直接使用 typed prompt 的 title/message/confirmButtonTitle/cancelButtonTitle 构造 `NSAlert`。
- 使用非阻塞 `beginSheetModal`，不使用 `runModal`；driver 任一时刻只强持有一个 alert。
- CoreBridge response policy 穷举四个组合：backgroundPersistence 的肯定/取消分别映射 confirm/cancel registration；loginItemsApproval 的肯定/取消分别映射 confirm/cancel navigation。
- sheet completion 捕获私有单调 presentation token、UX generation 与完整 prompt；处理前同时验证 alert identity、token、generation 和 prompt equality，任何 stale/duplicate completion 在 intent 前丢弃。
- 第二个 sheet 只有在上一个 typed intent 完成后，H4.2o 仍发布更高 generation 的 awaitingConfirmation 才能通过 `DispatchQueue.main.async` 呈现；不会由 requiresApproval 字符串或首个按钮回调直接打开设置。
- 非 awaiting 结果统一结束 driver 并至多一次发布 update/completion；navigationRequested、registered、cancelled、failure 都不会在 driver 内触发 Agent activation 或映射 ready。
- driver source 不引用 SMAppService、UserDefaults、HostControlClient、background activation、legacy `onHostToggle`/`setHostModeEnabled`、环境变量或密钥。
- source contract 证明 `RustDeskNativeApp.swift` 与 `HomeView.swift` 当前均不引用 driver，避免旧进程内 Host 与 background Agent 双启。
- 自动测试没有实例化 AppKit driver 或显示真实 sheet；只动态测试 pure response policy，并以编译与 source contract 验证产品 driver。因此本步不是 GUI/按钮真机验收。
- 未修改 Host ABI、XPC wire、Rust、Hermes、CI、根依赖、根配置或数据库，未读取真实配置/密钥，未安装、部署或 push。

## Verification

- TDD RED：focused test 首次因 response policy 不存在而编译失败；实现后转绿。
- sheet driver focused：3 tests，0 failures、0 warnings；1 个动态测试覆盖四种 exact response mapping，2 个 source contract 覆盖 nonblocking sheet、typed copy、token/generation gate、second-sheet scheduling 和 legacy isolation。
- 完整 Swift 回归：537 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：23 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/修改行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.2q 建立 legacy in-process Host → background Agent 的 single-owner migration gate：只有旧 Host preference/runtime 已安全停止且没有 active/pending session 时才允许进入 H4.2p，避免两个 HostCore 同时占用 identity/端口；在该 gate 完成前继续不接 Home 开关。
