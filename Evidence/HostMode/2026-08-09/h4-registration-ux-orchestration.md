# H4.2o background registration UX orchestration

## Outcome

建立 toolkit-independent 的后台注册 UX 顺序所有者，组合 H4.2m registration mutation 与 H4.2n approval navigation；本步没有接当前 Home 开关或真实 AppKit sheet。

## Key evidence

- 真实调用链审计确认：当前 `HomeView.onHostToggle` → `AppDelegate.setHostModeEnabled` 仍直接写 `farpane.host.enabled` 并启动旧进程内 `HostControlClient`；在迁移所有权前同时调用后台 registration 会产生两个 Host runtime 争用 identity/端口，因此本步保持隔离。
- owner 构造固定 inert；`requestBackgroundRegistration` 只发布第一份 prompt，不调用 register、navigation、activation、UserDefaults 或旧 HostCore。
- 第一份 prompt 明确说明：启用后即使退出 FarPane，当前已登录用户仍可通过这台 Mac 接受连接；按钮固定为“允许后台连接”/“取消”。只有 matching confirmation phase 才能调用 H4.2m register。
- registered 结果仅发布 registration enabled，不启动 Agent observation/activation，也不映射为 H4.2a ready。
- requiresApproval 结果发布第二份 prompt，明确引导“系统设置 > 通用 > 登录项与扩展”，并写明“这一步不代表已可被连接”；不会自动调用 H4.2n。
- 第二份 prompt 的肯定确认才调用 H4.2n；取消不导航。navigationRequested 仍不代表窗口出现、用户审批或 service enabled。
- 错序 confirmation、不同 prompt 的 cancel、并发 operation 和 observer reentrant intent 全部稳定拒绝；用户确认不能被代码回调隐式串联。
- H4.2m/n 的 Bool 与 typed snapshot 必须彼此一致；registration/status 或 navigation/status 矛盾均转为脱敏 invalid-result failure，不沿用猜测状态。
- product composition 只强持有 H4.2m/n product owners 并通过 typed operations 调用；源码不直接引用 SMAppService、AppKit、SwiftUI、NSAlert、UserDefaults、HostControlClient 或 H4.3e4g activation owner。
- 自动测试只执行注入 fake operations；`makeProduct()` 仅验证惰性构造和 source boundary，没有调用 flow，故未注册/取消注册服务、打开 System Settings、启动 Agent 或修改当前 Host preference。
- 当前尚无真实 sheet presenter/Home binding；本步证明 prompt copy 与 sequencing contract，不能作为人工确认、系统导航或后台运行验收。
- 未修改 Host ABI、XPC wire、Rust、Hermes、CI、根依赖、根配置或数据库，未读取真实配置/密钥，未安装、部署或 push。

## Verification

- TDD RED：focused test 首次因 UX owner/types 不存在而编译失败；实现后转绿。
- registration UX focused：11 tests，0 failures、0 warnings；覆盖 inert/request copy、两次 cancel/confirm、错序、registered、requiresApproval、registration failure、status drift、并发/reentry 和 product source boundary。
- 完整 Swift 回归：534 tests，4 skipped，0 failures、0 warnings；`Test Suite 'All tests' passed`。
- 脚本回归：23 tests，OK。
- arm64 Release 构建：`swift build -c release --arch arm64` 成功。
- `git diff --check` 与本步新增/修改行的私钥、长 Base64 secret-like 内容检查均通过。

## Remaining boundary

下一步 H4.2p 建立 AppKit sheet presenter/driver：只消费 H4.2o typed prompt 并把 sheet 的肯定/取消结果映射回 matching intent；仍不接当前 legacy Host toggle，直到 single-owner migration 能证明不会双启 Host。
