# H4.2n user-confirmed approval navigation owner

## Outcome

建立与 registration mutation、Agent activation/readiness 分离的 Login Items 导航 owner；本步没有接 App UI，也没有打开本机 System Settings。

## Key evidence

- 本机 macOS SDK `SMAppService.h` 明确要求：App 先向用户展示提示，用户确认要重新启用 helper 后，才调用 `openSystemSettingsLoginItems` 帮助导航。
- owner 构造态固定为 inert `idle`，不观察 registration、不打开设置；唯一入口是 typed `openLoginItemsAfterUserConfirmation`，供未来 UI 的肯定按钮调用。
- 收到 post-confirmation intent 后先通过既有只读 observer 重查权威 service status；只有仍为 requiresApproval 才调用 Apple 专用 Login Items API。
- notRegistered/enabled 均发布 notRequired 且不打开设置；notFound 与未来未知 status 已由 H4.2b adapter 收敛为 serviceUnavailable，并在本 owner fail closed。
- 专用结果名为 navigationRequested：API 返回 void，故不声称设置窗口已出现，也不声称用户已批准、registration enabled、Agent running 或 H4.2a ready。
- operation 期间第二个 confirmation 和 observer reentrant confirmation 都稳定拒绝，防止一次用户动作造成重复导航；publication 使用单调 generation。
- owner 不构造 `SMAppService.agent`，不具备 register/unregister，不引用 H4.2m mutation owner 或 H4.3e4g activation owner，不写 UserDefaults，也不依赖 AppKit、SwiftUI、NSWorkspace、环境或 URL override。
- product factory 的闭包只引用固定 read-only registration observer 与 `SMAppService.openSystemSettingsLoginItems()`；构造 product owner 本身不执行二者。
- 自动测试仅用注入 fake 执行 apply；product owner 只验证惰性构造与 source boundary，未触发真实设置导航、注册 mutation 或 Agent activation。
- 当前尚无实际确认对话框/UI binding；因此本步只证明 post-confirmation capability boundary，不能作为真实用户确认或真机导航验收。
- 未修改 Host ABI、XPC wire、Rust、Hermes、CI、根依赖、根配置或数据库，未读取真实配置/密钥，未安装、部署或 push。

## Verification

- TDD RED：focused test 首次因 navigation owner/types 不存在而编译失败；首次实现后 source-boundary 精确字符串断言发现换行差异，修正测试为等价的 type/method 双断言后转绿。
- approval navigation focused：7 tests，0 failures、0 warnings；覆盖 inert construction、requiresApproval、notRegistered/enabled、serviceUnavailable、并发 confirmation、observer reentry 和 product source boundary。
- 完整 Swift 回归：523 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：23 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/修改行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.2o 建立 App-side registration UX orchestration：在用户明确选择“App 退出后仍可被连接”后调用 H4.2m，requiresApproval 时真实展示说明，并只把肯定按钮映射到 H4.2n；注册状态、导航请求与 H4.2a ready 继续独立。
