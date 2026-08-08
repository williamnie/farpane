# H3.3h4 snapshot-authoritative active-session UI

- 日期：2026-08-08
- 范围：Home Host card、active-session command gate、Swift App action chain
- 结论：Home 可从 recoverable HostSnapshot 呈现当前会话，并按 exact connection ID 撤销能力或断开；UI 不把 command enqueue 当作状态完成

## Product state

1. `activeSession == nil` 时整块会话卡片隐藏；非 nil 时展示“当前远程会话”、对方声明名称/ID、平台、开始时间和当前 active capabilities。
2. Rust 标记为 untrusted 的 remote metadata 在 UI 中固定显示“对方声明（未经验证）”，不参与按钮 authority 或错误判断。
3. `controlKeyboardMouse`、成对 clipboard capability、`hearSystemAudio` 分别控制三个撤权按钮是否出现；已撤销的能力不会继续显示可操作入口。
4. “断开连接”始终绑定当前 snapshot 的 canonical connection ID。HomeView callback 只传该 ID 与固定 action enum，App 在调用 core 前再次核对当前 snapshot ID。
5. 活动会话时 Host 状态显示“远程会话进行中”或更具体的 media status；Home 卡片扩展时设备列表的 minimum height 使用可压缩优先级，避免小窗口 required-constraint 冲突。

## Non-optimistic action gate

- 同一活动会话一次只允许一个撤权或断开动作；stale ID、能力已不存在和重复点击在 Swift gate 内 fail closed。
- C ABI 成功只表示命令已入队。输入/剪贴板/音频按钮保持“处理中…”，直到后续 Rust snapshot 中对应 capability 真正消失。
- clipboard 必须等 read/write 两项都消失才收敛；异常的单边状态不会被当作完成。
- disconnect 保持“正在断开…”，直到 snapshot 的 active session 消失或切换为新的 canonical ID。
- typed not-found/stale/unavailable 映射为脱敏中文状态；失败后显式释放 gate 以允许按当前 snapshot 重试。Host stop/start 会清空 gate，不把旧 intent 带入新 instance。

## Red-green evidence

- RED：新增 gate test 编译失败于缺少 `HostSessionCommandGate`、`HostSessionCommandIntent` 和对应方法。
- GREEN：测试覆盖无会话、stale ID、重复 action、accepted-but-unchanged snapshot、keyboard capability 收敛、clipboard 双项收敛、mismatched completion、disconnect 等待 session 消失、能力不存在与 reset。
- App target 编译覆盖 active card、四个 selector、callback、typed command 与 snapshot refresh 全链。

## Verification

- targeted `HostSessionCommandGate` test：1 passed, 0 failed。
- 实际加载 ABI v6 release core 的 `swift test --quiet`：132 passed, 0 skipped, 0 failed。
- `python3 -m unittest discover -s Tests/ScriptTests`：20 passed, 0 failed。
- `swift build -c release --arch arm64`：success。
- `git diff --check` 与 changed-file scope audit：通过。

## Security and scope

- UI 只消费 strict-decoded、bounded snapshot 字段；没有显示 connection ID 本身，没有记录远端 metadata、能力 action、剪贴板内容、输入、画面、密码、key 或服务器配置。
- 未修改 Host ABI/snapshot/event/media schema、Rust bridge、protobuf、Hermes、CI、根依赖、数据库或 TCC 数据库。
- 未安装到 Mini、未 push。`/Applications/FarPane.app` 保持此前已验证版本。

## Remaining boundary

- 当前是 Home window 内的会话卡片；窗口关闭时仍缺 §14.3 要求的全局可见活动指示和“停止共享/断开”入口，应作为下一独立 AppKit lifecycle 步骤完成。
- 卡片布局、untrusted 文案、三个撤权、处理中状态、断开/重连与 Home rebuild 仍需最终安装包在 Mini/控制端真机验收。
- TCC/active Aqua transition 主动同步与 H3.4 多显示器/Secure Input 真机矩阵仍未完成。

## Next step

增加 active-session-scoped menu-bar status item：只由 recoverable snapshot 创建/销毁，持续显示活动指示，并提供 exact-session“断开连接”与“打开 FarPane”入口；与 Home gate 共用同一 action authority。
