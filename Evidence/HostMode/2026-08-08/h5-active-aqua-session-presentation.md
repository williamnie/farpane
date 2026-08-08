# H5.2b active Aqua session presentation

## Outcome

运行中的 in-process Host 现在由同一次 snapshot refresh 缓存独立的 Aqua-session availability，并让主状态、Home 活动会话卡和菜单栏共用组合 presentation。即使当前会话是 view-only、本机关闭键鼠、控制端关闭键鼠或 Accessibility denied，只要 Mac 已锁屏、进入 LoginWindow、切到其他用户或 `CGSession` 查询 fail closed，UI 都会显示 `远程会话受限：当前 Mac 会话不可用`，不会继续声称 `FarPane 正在共享屏幕`。

这是 H5.2 的 in-process active-session UI 子边界，不是后台 Agent 顶层 `hostAvailability`。LaunchAgent/LoginWindow readiness、无 active connection 时的 Host availability、真实锁屏/FUS transition 与安装态 UI 仍待后续。

## Key evidence

- `HostSessionPresentationPolicy` 先要求现有 `HostSessionInputPresentationPolicy` 成功验证 input availability/reason tuple；即使 Aqua unavailable，矛盾 tuple 仍返回 nil，不能制造可信 UI。
- active Aqua 可用时继续呈现原 input authority：Accessibility denied、local/remote disabled 与 available 文案不变。
- active Aqua 不可用时 session authority 优先，统一呈现：
  - overall：`远程会话受限：当前 Mac 会话不可用`；
  - detail：画面采集已暂停、远程键鼠不可用，并明确锁屏/LoginWindow/其他用户；
  - menu title：`FarPane 远程会话受限`。
- App 在每次 authoritative snapshot refresh 只读取一次 `CGSession`，同一结果同时驱动媒体 suspend/resume 与三处 UI；snapshot read failure 会缓存 unavailable 并暂停媒体，避免 UI 和采集状态分叉。
- Host stop/start 和 snapshot 清空会清除缓存；无 active session 时不制造 session availability。

## Verification

- TDD RED：组合 presentation 与 indicator 测试先分别因缺少 `HostSessionPresentationPolicy` 和 `activeAquaSessionAvailable` 参数编译失败。
- 定向 `HostApplicationLifecyclePolicyTests`：7 tests，0 failures。
- 完整 `swift test`：137 tests，4 conditional skips，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，0 failures。
- `swift build -c release --arch arm64`：完成 arm64 production build。
- `git diff --check`：0 whitespace errors。

## Manual follow-up

Mini + Viewer 可用后，至少覆盖 available、local-disabled、Accessibility denied 三种输入状态下的锁屏：画面停止后 Home 与菜单栏均必须显示会话不可用；解锁同一用户后无需重连，画面和 UI 恢复。Fast User Switching 单独重复。
