# Host Mode H3 进展报告 — 认证、权限与输入

- 最后更新：2026-08-08
- 对应设计：`docs/host-mode-design.md` §8.1–§10、§12、§26.6
- 状态：H3 进行中。H3.1a verifier authority/JSON secret firewall、H3.1b dedicated secret-buffer ABI 与本机 secure-field UI、H3.1c bounded login cooldown 已完成；H3.2a policy model、H3.2b1 native pending-request broker、H3.2b2 recoverable snapshot/decision contract，以及 H3.3/H3.4 的输入授权、epoch、cleanup 和 semantic normalization 自动边界已完成多项。Mini 上的点击、拖拽、滚动、键盘/输入法、修饰键清理和断线重连真机矩阵已通过。仍未完成的是 H3.1b 密码 UI 真机验收、H3.2 Swift 入站 UI/AND mode、H3.3 active session/revoke snapshot contract，以及 H3.4 Secure Input、TCC/session transition、多显示器和正式性能证据。

## H3.1a verifier authority

pinned RustDesk 1.4.9 已将永久密码转换为带 salt 的 32-byte H1 verifier，使用随机 nonce secretbox 封装 storage；认证链直接从 storage 恢复 H1，计算 challenge response 并 constant-time compare。更新密码会清除 trusted devices。FarPane 应复用该 Rust authority，不应把 Host 永久密码明文存进 Viewer Keychain。

默认认证失败策略已有按 IP/IPv6 prefix 的一分钟限流、累计 hard block 和审计；临时密码还有连续失败轮换。H3.1c 已为累计 hard block 加入独立有界 cooldown，不再需要重启进程才能解除。

## H3.1a generic JSON secret firewall

`HostControlClient.command` 现在统一经过 `HostCommandEnvelopePolicy`。generic JSON command 拒绝：

- `setPermanentPassword`；
- 任意层级的 password/credential/secret/token/private-key/recovery-key 字段；
- opaque binary material；
- 顶层 payload 覆盖 canonical `name` / `commandId`。

这条 firewall 防止永久密码被错误实现成不可清零的 JSON/String 复制链。H3.1b 已在 ABI v3 增加 dedicated mutable-byte set 入口；`clearPermanentPassword` 无秘密输入并已作为 generic command 接入 Rust。

## 验证与边界

- 定向 CoreBridge test 覆盖安全 approval/capability payload、empty clear 命令、顶层/嵌套敏感字段、binary payload、保留字段覆盖和 dedicated-ABI error；
- 第一次测试准确暴露嵌套 capability `name` 的误拒绝，修正为只限制顶层保留字段后通过；
- 最终全量 `swift test` 105 项、0 failure（4 项 built-core 条件跳过），release `RustDeskNative` 编译链接通过；
- vendored Rust patch reverse-check、bridge mirror comparison、diff/空白与秘密扫描通过；
- 未修改 Host ABI、HostSnapshot、Hermes、Keychain、配置文件或任何真实凭据；
- 详细审计与下一 ABI 检查点见 `Evidence/HostMode/2026-08-08/h3-permanent-password-authority-audit.md`。

## H3.1b dedicated secret-buffer ABI

经用户明确授权，Host ABI 已从 v2 升到 v3，新增 caller-owned mutable UTF-8 password buffer。Swift `Data` 与 Rust `SecretBuffer` 分别清零；hbb_common setter 的 H1 临时数组也在 storage encoding 后清零。Rust 固化 policy v1：6–128 个 Unicode scalar、最多 512 UTF-8 bytes，拒绝 empty、invalid UTF-8、control characters 与 outer whitespace，并为各 reject、change-disabled、storage failure 提供稳定错误码。

HostSnapshot schema v2 新增 local/effective/preset/changeAllowed 与 versioned strength policy；set/clear result 只含 command ID、stable status 与脱敏 detail。clear 会区分 local cleared 和 preset still effective。完整 ABI 实现和验证见 `Evidence/HostMode/2026-08-08/h3-permanent-password-secret-buffer.md`。

本机 Host 卡片现已投影上述权威状态，并提供 secure-field 设置/更换和显式清除入口。输入控件提交后立即清空；显式 mutable `Data` transfer buffer 由 UI owner、`HostControlClient` 与 Rust secret buffer 分层清零，密码不进入 JSON、持久化或日志。clear 的 change-disabled/storage failure 也会同步返回 typed error，避免 UI 误报成功。自动验证见 `Evidence/HostMode/2026-08-08/h3-permanent-password-ui.md`；视觉、设置/更换/清除及 preset fallback 仍需安装包真机验收，因此 H3.1 产品验收尚未关闭。

## H3.1c bounded cumulative login cooldown

pinned HostCore 的默认密码登录保留既有一分钟 burst gate，并把 direct IP 累计超过 30 次、IPv6 /64、/56、/48 prefix 分别累计超过 60、80、100 次后的 hard block 收敛为从最后失败分钟开始的 30 分钟 cooldown。blocked attempt 不继续滚动计时；到期在同一 failure-map lock 内移除 bucket，下次失败从 1 重新计数。错误回应给出剩余 1–30 分钟，既有审计类型保持不变。

成功登录现在无条件清除 direct IP 与对应 IPv6 prefix bucket，避免 direct bucket 已过期而 prefix 低于阈值时留下陈旧计数；计数器使用 saturating add，避免长时运行整数溢出。Rust 定向 tests 2/2、OS credential policy 回归 3/3、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；canonical patch clean replay 后 13 文件一致。详见 `Evidence/HostMode/2026-08-08/h3-bounded-login-cooldown.md`。

该策略是进程内、分钟精度的 pinned-core authority；进程重启本来就会清空 failure map。本步未改动 OS credential 独立 backoff、Host ABI、password verifier、Hermes 或 wire protocol，也不代表 H3.1 永久密码产品合同已完成。

## H3.2a canonical approval policy

新增 `HostApprovalMode` / `HostApprovalPolicy` / `HostLocalApprovalPath`，精确定义 `manualOnly`、`temporaryPassword`、`permanentPassword`、`passwordAndLocalApproval`、`passwordOrLocalApproval`，以及 local decision 的 prohibited / primary / required-after-password / alternative-to-password 阶段。无人值守仍需独立显式开启，并拒绝所有必须有本机用户在场的模式。

pinned upstream 只有 `click/password/both` 三种 approve mode。manual、temporary、permanent 以及 password-or-local 有精确 config projection；password-and-local 无现成映射，必须 fail closed，不能降级成 OR 或 password-only。config projection 不等于完整授权语义：一般 upstream 架构中 password mode 的空密码仍可能尝试旧 CM，本地 broker 仍必须按 `HostLocalApprovalPath` 拒绝或路由。

审计同时确认：native Host 绑定后会禁用旧 Connection Manager，因此 upstream 的 local-click 分支当前没有 receiver。H3.2b 必须在 Rust 登录生命周期加入 native pending-request broker，并同步扩展 Host event/command/snapshot，之后才能实现真实入站弹窗。仅设置 upstream config 或先画 Swift UI 都不能构成 H3.2。

定向 policy tests 4/4、全量 Swift 109 项 0 failure（4 项 built-core 条件跳过）及 release App 构建通过；详细模式矩阵与共享检查点见 `Evidence/HostMode/2026-08-08/h3-approval-policy-authority.md`。

H3.2b 前置事件链审计发现并修复一个 H3.1b 引入的 schema coupling：snapshot 升至 v2 时，Rust `emit_bound_event` 误用了 snapshot 常量，而 Swift `HostCoreEvent` 正确地仍只接受 event schema v1，导致新核心发出的 Host 事件全部在 Swift 解码入口被丢弃。event 与 snapshot 版本常量现已拆分；普通 Swift 113 项、release core、built-core 113 项（含实际 C callback 事件逐条 v1 断言和 Host lifecycle 3/3）及 Release App 均通过。H3.2 broker 仍未实现，本修复只恢复其必需的事件通道。详见 `Evidence/HostMode/2026-08-08/h3-host-event-schema-regression.md`。

## H3.2b1 native pending-request broker

pinned Rust 登录生命周期现已把本机点击确认分支接入 native Host broker，而不是依赖已禁用的旧 Connection Manager。broker 每次只保留一个 connection-scoped pending request，以单调时钟执行 30 秒期限；批准、拒绝、过期、断连和 Host stop 都只有一个最终状态，过期后的迟到批准不会重新授权。第二个连接、已终结 ID、Host 解绑竞态与不支持的作用域均 fail closed；密码验证失败不会生成本机确认通知。

request event 只包含有界、去控制字符并显式标记为 untrusted 的远端显示元数据，以及由登录 options 推导的固定 capability 名称；不包含密码、原始地址或密钥。`manual/click` 与 upstream `both` 的 Remote 路径可进入 broker，non-Remote 和 password-only 路径拒绝。`passwordAndLocalApproval` 仍因 pinned upstream 没有 AND 映射而保持 fail closed。

Rust broker 1/1、登录作用域 1/1、既有单远端槽 2/2、release arm64 core、实际加载该 core 的 Swift 113/113 与 Release App 均通过。H3.2 尚未完成：snapshot schema v2 不含 pending state，generic command 尚未接通 approve/reject，Swift 没有入站确认 UI，App 重建也不能恢复请求。详见 `Evidence/HostMode/2026-08-08/h3-native-pending-approval-broker.md`。

## H3.2b2 recoverable pending approval contract

Host Control ABI 现升至 v4，HostSnapshot 升至 schema v3，并以 `pendingApproval: object | null` 投影 H3.2b1 broker 的当前权威请求。对象复用同一脱敏请求结构：canonical connection ID、有界且标记 untrusted 的远端显示元数据、请求/到期时间、固定 capability、unknown/direct/relay transport、认证方式与有界风险码；不包含地址、密码、密钥或认证 payload。snapshot copy 会先用 broker 的单调 deadline 原子淘汰过期请求，不能把已过期项恢复给重建 UI。

generic command 现只接受精确三字段的 `approveConnection`/`rejectConnection` envelope，并把 connection ID 交回同一 broker；批准发送 Authorize，拒绝发送 Close。不存在、已终结、已过期分别返回稳定 `-21/-22/-23`，超时后批准不会复活连接，未知/额外字段 fail closed。request begin 和所有 final transition 都追加独立 event-schema-v1 `snapshotChanged`；event 与 snapshot 版本继续解耦。

Swift 新增严格 `HostPendingApproval` 解码、typed decision API 和失败分类；pending 字段集合、metadata trust、时间、有界 capability/transport/authentication 均校验，schema v3 尚未定义风险码，因此 risk array 必须为空，未知字段/能力/风险码或旧 snapshot schema 均拒绝。该步尚未加入 Swift 入站弹窗，所以 H3.2 仍未完成；下一步才可让 App 从 snapshot/event 展示一次性同意/拒绝 UI。实现证据见 `Evidence/HostMode/2026-08-08/h3-recoverable-pending-approval-contract.md`。

## H3.3a ordered input revocation cleanup

pinned Rust connection input worker 新增 connection-scoped `Release` marker。keyboard permission 被撤销时先关闭 permission gate，再在同一输入队列中把 cleanup 排到先前已接受事件之后；connection loop 结束也走相同路径。cleanup 强制释放远端按键、清除 relative-mouse 状态，并按 connection 释放尚未收到 mouse-up 的 left/right/middle/back/forward 按钮。macOS mouse release 与既有注入使用同一串行 platform queue，避免 cleanup 与旧事件重排。

Rust 定向 tests 2/2、touched-file rustfmt、release core build、built-core Host lifecycle/ABI smoke、全量 Swift 109 项及 release App build 均通过；canonical patch 在 clean pinned clone 重放后 13 个文件逐一一致。详细证据见 `Evidence/HostMode/2026-08-08/h3-input-revocation-cleanup.md`。

H3.3 仍未完成：按键 pressed-state 仍是 process-global，依赖尚未落地的 single-active-session authority；native Host 也还没有 App/Host ABI revoke command、对外 session permission snapshot 或 adapter epoch。真实 CGEvent stuck-input 验收需要用户在有辅助功能/输入监控权限的真机会话中完成。

## H3.3b connection-scoped input permission epoch

每个 desktop connection 新增单原子 permission generation：奇数 enabled、偶数 disabled。可注入 mouse、pointer/touch、key event 入队时捕获 immutable snapshot，input worker 在 platform input service 前复核；local revoke 和 connection teardown 会先轮换 epoch，再执行 H3.3a cleanup。撤销前已积压但尚未被 worker 接受的事件因此失效，re-enable 也不会让旧 snapshot 重新有效。仅显示远端光标的 non-injecting mouse message继续可用。

Rust epoch tests 2/2、release cleanup tests 2/2、release core、built-core Host lifecycle/ABI smoke、Swift 全量 109 项及 Release App build 均通过；canonical patch 在 clean pinned clone 重放后 13 文件逐一一致。详细证据见 `Evidence/HostMode/2026-08-08/h3-input-permission-epoch.md`。

H3.3 仍未完成：native single-active-session authority、HostSnapshot/event/command 中的 current permission/revoke contract 与 App rebuild 恢复尚未建立；最终 H3.4 还要把 epoch 带到 semantic HostInputAdapter/CGEvent 边界。当前不能把 Rust 内部 epoch 冒充产品 UI 已可撤销。

## H3.3c native single active remote-control lease

native Host 生命周期现在最多允许一个已授权 `ConnType::Remote`。availability check 与 reservation 在 `AUTHED_CONNS` 同一把锁内原子完成，`authorized` 只在 reservation 成功后提交；第二个 remote 得到脱敏 busy error 并关闭。`AuthedConnID` 的既有 RAII drop 是唯一 release authority，所以旧连接必须先完成 H3.3a/H3.3b 输入清理并退出，下一连接才可取得 lease。

策略只在完整 native Host instance lifetime 内生效且只约束 remote-control scope；file transfer、port forward、view camera、terminal 与非 native upstream 行为保持兼容。Rust policy/concurrency tests 2/2、epoch 2/2、cleanup 2/2、release core、built-core Host lifecycle/ABI、Swift 全量 109 项及 Release App build 均通过；canonical patch clean replay 后 13 文件一致。详细证据见 `Evidence/HostMode/2026-08-08/h3-single-active-control-session.md`。

H3.3 仍未完成：HostSnapshot/event/command 没有 active-session aggregate/current permission/revoke contract，App rebuild 后不能展示或终止会话；H3.2b2 已补齐 pending approval 合同但尚无 Swift UI，H3.4 adapter/CGEvent epoch 与真机边界仍待后续。真实双 controller busy/reconnect/stuck-input 验收需要用户在 Mini 上完成。

## H3.3d authorization-bound effective input permission

connection input epoch 现在默认 disabled，只有“登录已认证、会话是 Remote control、display service 已订阅并 ready、本机 keyboard policy 允许、Viewer 未设置 `disable_keyboard`”五个条件同时成立才启用。这使预认证阶段、显示服务尚未就绪、file-transfer/terminal/view-camera scope 和任一方禁用键盘时，permission authority 本身就 fail closed，不再只依赖 `on_message` 分支不转发未授权事件。

本机 `SwitchPermission` 和 Viewer `disable_keyboard` 现在共用同一 effective-permission 同步点。enabled→disabled 会原子旋转 epoch，让先前已排队但尚未到 adapter 的事件失效，并在同一 input queue 中排入既有 connection-scoped release marker；重复设置同一状态不会无意义旋转 generation。之前 Viewer 禁用键盘仅拒绝新输入、已排队事件仍可以携带 current epoch 落到 adapter 的窗口因此被关闭。

effective policy、epoch、adapter、release 与 session-scope 相关 Rust tests 10/10、release core、built-core lifecycle/ABI、Swift 109 项及 Release App 均通过；canonical patch clean replay 后 13 文件一致。本步未改动 Host ABI、HostSnapshot、protobuf、Hermes 或 macOS 权限。详见 `Evidence/HostMode/2026-08-08/h3-effective-input-permission.md`。

H3.3 仍未完成：App 还没有 active-session permission snapshot/revoke/disconnect contract，App rebuild 后也不能展示该 Rust authority。真实 Viewer disable 与 local revoke 在 CGEvent backlog 下的验收仍需 Mini 的 Accessibility/Input Monitoring 权限。

## H3.3e disconnect-safe local block-input cleanup

pinned input worker 会在 block-input 模式中每 500ms receiver timeout 重申 `platform::block_input(true)`，但 sender 断开时也走同一分支：它再次启用本机输入阻断后立即退出线程，没有任何后续 owner 负责恢复本机输入。这与 connection teardown 必须清理所有输入状态的要求冲突。

receiver error 现在先转成 typed action：Timeout + active block 继续重申 `true` 且不退出，Disconnected + active block 则在退出前调用 `block_input(false)`；未 blocked 时不做多余 platform call。RED 准确得到 `Some(true)+exit`，GREEN 得到 `Some(false)+exit`。这一改动不改变活动会话中的 block-input 保持行为。

block cleanup 与 permission/adapter/release 相关 Rust tests 7/7、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；canonical patch clean replay 后 13 文件一致。本步未修改 Host ABI、HostSnapshot、Hermes、macOS 权限或 block-input 产品 capability policy。详见 `Evidence/HostMode/2026-08-08/h3-block-input-disconnect-cleanup.md`。

本步自动验证状态机与真实 platform call 编译/链接路径。进一步审计确认 pinned macOS `platform::block_input` 当前是 success-returning no-op，所以该清理是跨平台生命周期防线，不能据此声称 macOS 已支持锁住或恢复本机输入；若后续实现真实 macOS block-input，才需要在可恢复的 Mini 会话补断线验收。H3.3 的 App snapshot/revoke/disconnect 共享合同仍未完成。

## H3.3f local block-input permission revoke cleanup

本机 `SwitchPermission { name: "block_input", enabled: false }` 原本只更新 connection capability 并向 Viewer 发送 `PermissionInfo(false)`，没有通知持有 active block 状态的 input worker。因此远端先前排入的 `BlockOn` 可以继续生效，直到远端主动发送 `BlockOff` 或连接断开；本机撤权不是 runtime authority。

现在 capability 从 `true` 变为 `false` 时，会在同一个 connection input queue 中排入 `BlockOff`。FIFO 保证先前已接受的 `BlockOn` 之后必有本机权威的 unblock；撤权后的远端 `BlockOn` 又会被既有 `self.block_input=false` gate 拒绝。重复 false、重新授权或同值 true 都不产生多余 runtime action。

RED 精确证明旧路径返回 `None`，GREEN 与断线 cleanup、permission epoch、adapter gate、pressed-state cleanup 合计 8/8；release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过，canonical patch clean replay 后 13 文件一致。本步没有修改 Host ABI、HostSnapshot、protobuf、Hermes 或产品 capability schema。详见 `Evidence/HostMode/2026-08-08/h3-block-input-permission-revoke.md`。

pinned macOS block-input 仍是 success-returning no-op，本步只修复 connection/runtime 一致性，不把该 capability 冒充可用的 macOS 功能。下一步应独立审计 macOS 是否需要 fail closed 地禁止广告该能力；H3.3 的 App snapshot/revoke/disconnect 共享合同仍未完成。

## H3.3g Native Host block-input capability fail-closed

pinned macOS 与 Linux 的 `platform::block_input` 都是 success-returning no-op，只有 Windows 调用真实系统 API。此前 connection 初始化仅读取 `enable-block-input`/provider permission，因此 macOS Native Host 会把 capability 广告给 Viewer；Viewer 请求后 worker 又收到“成功”，形成 UI 可用但平台无行为的虚假能力。

connection 现在把 configured permission、Native Host instance lifetime 与 platform support 组合成同一 capability gate：Native Host 只在 Windows 保留 block-input；macOS/Linux Native Host 强制 false，并在登录时向 Viewer发送 `PermissionInfo(false)`。同一 gate 也覆盖内部 `SwitchPermission(true)`，防止未来本机控制入口重新开启；如果旧状态异常为 true，则 H3.3f 的 `true→false` 路径继续排入 `BlockOff`。非 Native Host 的 pinned upstream 行为保持不变。

RED 精确证明 Native Host + unsupported platform 仍返回 true，GREEN 与 capability/revoke/disconnect/permission/adapter/release/single-session/session-scope 回归合计 15/15；release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过，canonical patch clean replay 后 13 文件一致。本步没有修改 Host ABI、HostSnapshot、protobuf、Hermes、根依赖或平台实现。详见 `Evidence/HostMode/2026-08-08/h3-native-block-input-capability.md`。

H3.3 的 active-session snapshot/revoke/disconnect 与 App rebuild 恢复仍未完成；macOS block-input 不再需要真机“锁定”验收，因为产品已明确不广告该 no-op capability。若未来实现真实 macOS platform support，应以新的 capability/probe 与可恢复真机验收重新开启。

## H3.4a macOS input-adapter epoch gate

审计确认 H3.3b worker check 后，macOS mouse、pointer 与 key 还会异步进入 `Queue::main()`，形成独立的迟到执行窗口。connection 现在为每个可注入 platform task 捕获 one-shot gate，main queue 在调用 `handle_*_`/Enigo/rdev 前再次比较 immutable snapshot 与 connection epoch；revoke 后积压在 platform queue 的旧 task 因此失效，re-enable 也不会使旧 generation 有效。cursor-only non-injecting task 保持可用。

macOS cleanup 同时改为在这条串行 main queue 内读取并释放 key/button state，而不是在 worker 线程提前读取后只异步 post release。这样先前已开始的 task、cleanup 与之后的新 task具有明确队列顺序。Rust adapter gate 1/1、epoch 2/2、cleanup 2/2、single-session 2/2、release core、built-core lifecycle/ABI、Swift 109 项及 Release App build 均通过；canonical patch clean replay 后 13 文件一致。详细证据见 `Evidence/HostMode/2026-08-08/h3-input-adapter-epoch.md`。

H3.4 仍未完成：当前 adapter 仍消费 upstream protobuf payload，没有独立 semantic event model 和 revisioned display/coordinate mapping；Secure Input、登录窗口、系统快捷键、键盘布局与 TCC 降级也需要真机验收。HostSnapshot/revoke/App rebuild 合同仍属于尚未决策的共享 schema 边界。

## H3.4b connection-scoped input display-mapping epoch

macOS mouse、pointer/touch 与 cursor-only queued task 现在携带 connection-scoped display mapping generation。display list/scale、selected display 或 connection lifetime 改变时 generation 单调前进；worker 和异步 main-queue adapter 都会拒绝旧 generation。Retina absolute mapping 在缺 display、非有限/非正 scale 时 fail closed，relative/wheel/trackpad 保持 delta 语义；相同 display list 不产生无意义 epoch rotation。

该 generation 是 Host 内部 input normalization authority，不复用媒体 route 的 `displayRevision`，也没有修改 `MouseEvent` protobuf、Host ABI 或 Hermes。Rust mapping tests 2/2、Retina 1/1、adapter 1/1、permission 2/2、cleanup 2/2、single-session 2/2、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；canonical patch clean replay 后 13 文件一致。详细证据见 `Evidence/HostMode/2026-08-08/h3-input-display-mapping-epoch.md`。

H3.4 仍未完成：wire event 不携带 display id/revision，absolute bounds/button sentinel 语义与独立 typed semantic event 仍需收敛；多显示器/scale、Secure Input、登录窗口、快捷键、键盘布局与 TCC 降级需真机验收。HostSnapshot/revoke/App rebuild 仍是共享 schema 检查点。

## H3.4c typed mouse semantic normalization

desktop Host 现在把 protobuf `MouseEvent` fail-closed 转换成 `NormalizedMouseInput`：absolute/relative move、single-button down/up、discrete/precise scroll 六类语义。unknown type、非法/多按钮 transition、move/scroll 携带 button bits、unknown/duplicate modifier 都在 connection queue 前拒绝；relative 与 scroll delta 分别按现有 FarPane Viewer 合同有界化。typed value 穿过 input queue 并由 macOS main-queue adapter 消费，之后才投影给 pinned Enigo/rdev。

absolute move 与带实际坐标的 button event 必须落在当前有效 display rectangle，dimension overflow、无效尺寸/scale 或缺 display 均 fail closed；legacy button `(0,0)` sentinel 继续兼容，避免破坏旧版 FarPane。Rust semantic 1/1、Retina 1/1、mapping 2/2、adapter 1/1、permission 2/2、cleanup 2/2、single-session 2/2、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；canonical patch clean replay 后 13 文件一致。详见 `Evidence/HostMode/2026-08-08/h3-mouse-semantic-normalization.md`。

H3.4 仍未完成：`PointerDeviceEvent` 和 Host 入站 key 仍需独立 semantic normalization；wire display id/revision 与 button `(0,0)` 无歧义 sentinel 需要共享 contract 才能彻底解决。多显示器/scale、Secure Input、登录窗口、快捷键、键盘布局与 TCC 降级仍需真机验收；HostSnapshot/revoke/App rebuild 仍是共享 schema 检查点。

## H3.4d typed pointer/touch semantic normalization

desktop Host 现在会在 connection queue 前把 protobuf `PointerDeviceEvent` 转成 `NormalizedPointerInput`，只允许 scale update、pan start/update/end。缺失或未来未知 union、unknown/duplicate modifier 均 fail closed；scale 千分比增量限制为 `[-1000, 1000]` 并显式识别零值结束，pan update delta 限制为 `[-10000, 10000]`。typed value 连同 permission/mapping epoch 穿过 input queue 并到达 platform adapter。

本步没有把边界验证冒充 macOS 功能：pinned macOS `handle_pointer_` 仍不注入 touch gesture；Windows 既有 scale 路径仅消费规范化后的 projection。Rust pointer semantic 1/1 与既有回归 11/11、release core、built-core lifecycle/ABI、Swift 109 项及 Release App 均通过；canonical patch clean replay 后 13 文件一致。详见 `Evidence/HostMode/2026-08-08/h3-pointer-semantic-normalization.md`。

H3.4 仍未完成：Host 入站 key 需要 typed semantic normalization；macOS touch gesture 是否映射为滚动/缩放、wire display revision、Secure Input/登录窗口/快捷键/布局/TCC 与真实多显示器输入仍是平台决策或真机边界。HostSnapshot/revoke/App rebuild 仍是共享 schema 检查点。

## H3.4e typed key semantic normalization

desktop Host 现在会在 connection queue 前把 protobuf `KeyEvent` 转成 `NormalizedKeyInput`，并明确区分 Legacy control/character/unicode/sequence、Map/Translate physical/sequence 与 Down/Up/Press/Text action。Auto 继续兼容 pinned Legacy 行为；缺 union、未知 mode/union、错误 mode-union 配对、非法 Unicode、歧义 down+press、未知/重复 modifier、NUL 或超过 4096 bytes 的 sequence 均 fail closed。macOS physical keycode 与 Viewer C ABI 一致限制为 `0...0x7f`。

typed key 连同 permission epoch 穿过 queue；Press 只在 worker 展开为有序 down/up，每个 macOS main-queue task 在最终 Enigo/rdev 前再次复核 adapter gate。Rust key semantic + Viewer producer 3/3、相关输入回归 12/12、release core、built-core lifecycle/ABI、Swift 109 项及 Release App 均通过；canonical patch clean replay 后 13 文件一致。详见 `Evidence/HostMode/2026-08-08/h3-key-semantic-normalization.md`。

H3.4 的 mouse/pointer/key typed semantic 边界已齐备，但真实键盘布局、dead key/IME、AltGr、系统快捷键、Secure Input、登录窗口、TCC 降级、macOS touch capability 与多显示器输入仍需平台决策或真机验收。HostSnapshot/revoke/App rebuild 仍是共享 schema 检查点。

## H3.4f Native Host pointer/touch capability fail-closed

最终 platform consumer 审计确认：pinned `handle_pointer_` 只有 Windows scale update 有实际实现；macOS/Linux 的全部 pointer kind 与 Windows pan kind 都是 no-op。Native Host 现在会先完成既有 typed normalization，再按 instance lifetime、compile-time platform capability 和 normalized semantic kind fail closed；拒绝发生在 display mapping snapshot、input queue 与 auto-disconnect timer 之前。非 Native Host 的 pinned upstream 行为保持不变。

这一步没有把 macOS touch gesture 映射成 mouse/scroll，也没有增加虚假的 capability advertisement。Rust capability/semantic/mapping/permission/adapter/release/session 回归 15/15、release core、built-core lifecycle/ABI、Swift 109 项及 Release App 均通过；canonical patch clean replay 后 13 文件一致。详见 `Evidence/HostMode/2026-08-08/h3-native-pointer-capability.md`。

H3.4 仍需处理 Secure Input、TCC、LoginWindow、真实布局/IME/系统快捷键和多显示器真机边界；pointer capability feedback 若要显式暴露给 Viewer，需要共享 protobuf 或 Host snapshot contract 决策，本步未修改。HostSnapshot/revoke/App rebuild 仍是共享 schema 检查点。

## H3.4g Native Host Accessibility TCC fail-closed

pinned macOS 已有 `AXIsProcessTrustedWithOptions(false)` 权威查询，但此前只供 UI 使用；Host connection 的 keyboard capability 和最终 Enigo/rdev adapter 均未消费它。Native Host 现在以 `configured && (!nativeHost || accessibilityTrusted)` 计算 connection capability，本机 permission switch 也走同一 policy；macOS main queue 的 simulated mouse、pointer 与 key 在最终注入前再次无提示查询 TCC，覆盖排队后撤权窗口。cursor-only non-injecting 路径保持可用，非 Native pinned upstream 行为不变。

Rust TCC policy/permission/adapter/mapping/semantic/release/session 回归 17/17、release core、built-core lifecycle/ABI、Swift 109 项及 Release App 均通过；canonical patch clean replay 后 13 文件一致。未请求权限弹窗，也未修改 Input Monitoring policy、TCC 数据库、protobuf、Host ABI/snapshot 或 Hermes。详见 `Evidence/HostMode/2026-08-08/h3-native-accessibility-gate.md`。

H3.4 仍有明确边界：运行中 TCC 变化尚不会主动刷新 shared HostSnapshot/UI，key-down/key-up 之间撤权、Secure Input、LoginWindow/锁屏、Fast User Switching、真实布局/IME/快捷键和多显示器仍需共享 contract 决策或真机验收。

## H3.4h Native Host active Aqua session fail-closed

pinned macOS 的 `is_prelogin()`/`is_locked()` 分别启动 `ls`/`ioreg`，查询失败会返回“非 prelogin/未锁定”，且不适合高频 adapter。Native Host 新增无子进程的 `CGSessionCopyCurrentDictionary` projection：只有 on-console、login-done 且未锁定才可控制；required key 缺失、类型异常或 dictionary 获取失败都 fail closed，只有 Apple 在 unlocked session 省略的 lock key 按 false 解释。

connection keyboard capability、本机 permission switch 与最终 simulated mouse/pointer/key adapter 共用 active Aqua + Accessibility gate；锁屏、LoginWindow、Fast User Switching 非 active session 和 unknown query 都拒绝输入，cursor-only/non-Native upstream 保持。Rust session/TCC/permission/adapter/mapping/semantic/release/scope 回归 18/18、release core、built-core lifecycle/ABI、Swift 109 项和 Release App 均通过；canonical patch clean replay 后 14 文件一致。详见 `Evidence/HostMode/2026-08-08/h3-native-active-aqua-session-gate.md`。

Mini 首轮真机输入验收发现 on-console 字典键误写为 `kCGSessionOnConsoleKey`，而当前 macOS runtime 实际提供 `kCGSSessionOnConsoleKey`；因此已授权的活动 Aqua 会话仍被 fail-closed，并被 Viewer 归类为远端未授权。现已修正 canonical patch 与 vendor projection，并增加精确键名回归门禁。修复后 Rust 定向 session 测试、Swift 110 项、release core、built-core Host/Viewer ABI、arm64 App 签名与 ZIP 解压复验均通过；真实 CGEvent 控制仍等待同一 Mini 重新安装后复测。详见 `Evidence/HostMode/2026-08-08/h3-active-aqua-console-key-hotfix.md`。

H3.4 仍需 shared HostSnapshot/UI 的 `limited/sessionUnavailable` 主动刷新、transition cleanup、Secure Input、真实布局/IME/快捷键、多显示器与真机锁屏/FUS/CGEvent 验收；高频 CGSession/TCC query 的性能也必须用真实指标确认。

## H3.4i macOS Secure Input authority audit

本机 SDK 和 runtime 已确认 Carbon `IsSecureEventInputEnabled()` 可用，返回任意进程是否启用 Secure Event Input，并标注 not thread safe；pinned Enigo 已链接 Carbon。唯一安全查询位置是 macOS main key queue。CGSession 的 `kCGSSessionSecureInputPID` 在当前会话缺失且没有公开 header contract，不能作为替代 authority。

本步没有擅自把 Secure Input 变成 hard gate：静默丢 key 会让普通密码框无法远程输入且 UI 仍显示可控；把它并入现有 keyboard capability 又会连 mouse 一起关闭。需要先选择“key-only temporary limited / 继续由系统决定 / 暂停全部控制”，并为前两种降级补 shared runtime status、event 与 cleanup。详见 `Evidence/HostMode/2026-08-08/h3-secure-input-authority-audit.md`。

因此 Secure Input 现为明确架构/真机检查点，runtime 与 canonical patch 未改。H3.4 其余 layout/IME/快捷键、多显示器、TCC/session UI 同步和真机输入仍待后续。

## H3.4j pointer semantic activity side-effect gate

pointer ingress 之前会在 typed normalization 与 platform capability gate 之前写 `MOUSE_MOVE_TIME`。因此 malformed event 或 macOS Native Host 最终必拒绝的 pointer/touch event 虽未进入 input queue，仍会通过 IPC 被观察成最近 peer input。

现在 wire normalization 与 Native Host/platform semantic capability 合并为单一 acceptance gate；只有得到 supported typed input 后才更新时间、取得 mapping snapshot 并入队。malformed、macOS/Linux Native Host pointer 以及 Windows Native Host pan 均在副作用前拒绝，non-Native upstream 与 Windows scale 保持。

相关 Rust 回归 19/19、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；canonical patch 在 pinned HEAD 快照 clean replay 后 16 个 tracked 文件逐一一致。详见 `Evidence/HostMode/2026-08-08/h3-pointer-activity-side-effect-gate.md`。

## H3.4k Native Host pointer queue-admission activity commit

H3.4j 后，Native Host 在 peer keyboard permission 关闭时仍会无条件重置 auto-disconnect；Windows scale 也可能在 effective permission epoch disabled、`input_pointer` 未取得 snapshot/未入队时提前提交 `MOUSE_MOVE_TIME`。semantic/platform acceptance 还不是授权 queue admission。

`input_pointer` 现在返回 permission snapshot + channel send 的 admission 结果；Native Host 只有 queued=true 才提交 peer activity 与 auto-disconnect。non-Native desktop compatibility 和 Android/iOS 原行为保持。相关 Rust 19/19、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；16 文件 clean replay 一致。详见 `Evidence/HostMode/2026-08-08/h3-pointer-queue-admission-activity.md`。

## H3.4l Native Host key queue-admission activity commit

key ingress 原本在 `input_key` 取得 effective permission snapshot 前写 Enter click time、peer input time，并在 peer keyboard disabled 或未入队后照样重置 auto-disconnect。`input_key` 现在返回 snapshot + channel send 的 admission 结果；Native Host 只有 queued=true 才提交三类 activity，non-Native activity compatibility 保持。

相关 Rust 20/20、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；16 文件 clean replay 一致。pressed-modifier tracking 仍是下一独立 queue-admission 边界。详见 `Evidence/HostMode/2026-08-08/h3-key-queue-admission-activity.md`。

## H3.4m Native Host key modifier admission tracking

physical-modifier cleanup 集合原本在 `input_key` admission 前更新：rejected press 会制造断线时无对应 down 的 key-up，rejected release 又会删除先前已接受的跟踪状态。Native Host 现在只在 queued=true 后 insert/remove；被拒绝的 release 保留已跟踪状态，继续由 teardown cleanup 释放。non-Native compatibility 保持。

相关 Rust 21/21、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；16 文件 clean replay 一致。真实 modifier 撤权/断线键状态仍需 Mini 真机验收。详见 `Evidence/HostMode/2026-08-08/h3-key-modifier-admission-tracking.md`。

## H3.4n Native Host mouse queue-admission activity commit

simulated mouse 原本在 Retina mapping、permission snapshot/channel send 前写 click/peer time，且无实际 queue item 也会重置 auto-disconnect。`input_mouse` 现在返回 admission 结果；Native Host simulated mouse 只在 queued=true 后提交活动，cursor-only non-injecting item 成功入队时仍维持 auto-disconnect。non-Native desktop 与移动端兼容保持。

相关 Rust 21/21、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；16 文件 clean replay 一致。详见 `Evidence/HostMode/2026-08-08/h3-mouse-queue-admission-activity.md`。

## H3.4o Native Host typed modifier action state

physical-modifier cleanup 集合虽然已在 H3.4m 对齐 queue admission，但状态更新仍复用了 pinned upstream 的 `is_press`。该布尔值服务于旧 platform projection，并不等价于 typed action 的“事件结束后仍按下”：Native Host `Down` 因 `is_press=false` 被错误移除，`Press` 因 `is_press=true` 被错误保留，即使 worker 会把 Press 展开为有序 down+up。

Native Host 现在在任何 promotion 前捕获 typed action，并只在授权入队后按 `Down -> tracked`、`Up/Press -> untracked` 更新 cleanup state；`Text` 不参与 physical modifier tracking。non-Native 继续使用原 `is_press` compatibility。相关 Rust 22/22、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；16 文件 clean replay 一致。真实 modifier down、撤权、断线与本地键状态仍需 Mini 真机验收。详见 `Evidence/HostMode/2026-08-08/h3-key-modifier-action-state.md`。

## H3.4p Native Host ordered modifier drop cleanup

H3.3a 已在撤权和 connection-loop teardown 时把 `Release` marker 排在同一 input queue 中，并让 macOS cleanup 与最终 adapter task 共用串行 main queue。`Connection::drop` 却仍从连接线程遍历 `pressed_modifiers`，直接调用 `rdev::simulate(KeyRelease)`；它可能与 ordered cleanup 重复，也可能越过尚在队列中的已接受 key event。

Native Host 的 `Drop` 现在只清空 connection-side modifier bookkeeping，真实 release 保持由已存在的 ordered `Release` authority 执行。Host instance live flag 明确覆盖 runtime stop/drain 窗口；non-Native 仍保留 pinned upstream 的 direct Drop cleanup。完整 Rust lib 121/121、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；16 文件 clean replay 一致。真实 modifier down、撤权/断线和最终本地键状态仍需 Mini 验收。详见 `Evidence/HostMode/2026-08-08/h3-ordered-modifier-drop-cleanup.md`。

## H3.4q Native Host cleanup-completion Remote lease

single-active Remote lease 原本随 `Connection` drop 释放；connection loop 在此之前虽然已发送 ordered `Release`，macOS input worker 只会把实际 cleanup 异步提交到 serial main queue。新 Remote 因而可能在旧 cleanup 尚未执行时取得 lease、注入新 key，随后被旧 cleanup 的 process-global pressed-key drain 意外释放。

Native Host Remote teardown 现在把 `AuthedConnID` lease guard 随 `Release` marker 交给 input worker；macOS guard 由 serial queue cleanup closure 在实际 key/button release 后 drop，其他 desktop platform 则在同步 cleanup 后 drop。permission revoke 不转移 lease，非 Remote/non-Native 生命周期保持。完整 Rust lib 122/122、release core、built-core lifecycle/ABI、Swift 109 项与 Release App 均通过；16 文件 clean replay 一致。真实快速断开/重连与键状态仍需 Mini 验收。详见 `Evidence/HostMode/2026-08-08/h3-cleanup-completion-remote-lease.md`。

## H3.4r typed absolute-drag held buttons

FarPane Viewer 的 `ViewerMetalView.sendMove` 会在 drag 期间把 `heldButtons` 放进每个 absolute Move；Rust viewer bridge 也明确允许 Move 携带已知 button mask。H3.4c 的 Host normalization 却只接受 `MOUSE_TYPE_MOVE` 且 buttons=0，导致 button-down 成功后所有拖动 move 被静默拒绝。

`NormalizedMouseInput` 现在允许 absolute move 携带 left/right/middle/back/forward 的任意已知组合并保留原 mask；button down/up 仍只允许单 button，relative move、scroll 携带 button 或任何未知位仍 fail closed。targeted normalization 与完整 Rust lib 122/122、release core、built-core lifecycle/ABI、Swift 109 项、Release App 及 16 文件 clean replay 均通过。真实 click-drag 仍需 Mini 验收。详见 `Evidence/HostMode/2026-08-08/h3-absolute-drag-held-buttons.md`。

## H3.4s Viewer pointer producer semantic parity

Rust Viewer bridge 的 `pointer_mask` 原本只验证 button 位是否合法，并只对 Down/Up 限定单 button；Scroll/PreciseScroll 携带 button 仍返回成功并发出 wire event，但 H3.4c Host normalization 会拒绝它。调用方因此得到 status=0，实际输入却被静默丢弃。

Viewer bridge 现在与 Host typed contract 对齐：Move 继续允许 H3.4r 所需的已知 held-button 组合；Down/Up 要求恰好一个 button；Scroll/PreciseScroll 要求 buttons=0；未知位保持拒绝。producer/Host targeted tests、完整 Rust lib 122/122、release core、built-core lifecycle/ABI、Swift 109 项、Release App 与 16 文件 clean replay 均通过。详见 `Evidence/HostMode/2026-08-08/h3-viewer-pointer-semantic-parity.md`。

## H3.4t Viewer character NUL semantic parity

Rust Viewer bridge 的 `key_name(Character, unicodeScalar)` 原本会把 scalar 0 转为包含 NUL 的字符串并返回成功，但 Host `NormalizedKeyInput` 和 text API 都明确拒绝 NUL。调用方因此可能收到 status=0，而远端 Host 只会静默丢弃该事件。

Viewer producer 现在只接受非 NUL 的有效 Unicode scalar；NUL 与其他无效 scalar 都在 wire event 生成前 fail closed，普通 Unicode 字符语义保持不变。定向 producer test 1/1、完整 Rust lib 122/122、release core、built-core lifecycle/ABI、Swift 109 项、Release App 与 16 文件 clean replay 均通过；bridge mirrors 一致。未修改 ABI shape、wire/protobuf、Host ABI/snapshot 或 Hermes。真实键盘布局、dead key、IME 与远端文本输入仍需 Mini 验收。详见 `Evidence/HostMode/2026-08-08/h3-viewer-character-nul-parity.md`。

## H3.4u zero-delta scroll semantic no-op gate

Viewer bridge 原本会为 Scroll/PreciseScroll 的 `(0,0)` delta 返回成功并发出 wire event；Host `NormalizedMouseInput` 也会接受并入队。macOS adapter 对两个轴都为零时没有任何输入动作，但 Native Host 已经把该消息当作 authorized queue admission，可能刷新 peer-input activity 与 auto-disconnect timer。

Viewer producer 现在在 clamp 后拒绝 `(0,0)` scroll，Host typed normalizer 同样拒绝来自旧版或非 FarPane peer 的零增量 wheel/trackpad event。非零 delta 继续按 `[-120,120]` clamp，Swift `ScrollDeltaMapper` 原有的零值过滤保持。producer/Host 定向 tests 各 1/1、完整 Rust lib 122/122、release core、built-core lifecycle/ABI、Swift 109 项、Release App 与 16 文件 clean replay 均通过；bridge mirrors 一致。未修改 ABI shape、wire/protobuf、Host ABI/snapshot 或 Hermes。真实 wheel/trackpad 方向与手感仍需 Mini 验收。详见 `Evidence/HostMode/2026-08-08/h3-zero-delta-scroll-gate.md`。

## H3.4v zero-delta relative-mouse semantic gate

Host typed normalizer 原本接受 `MOUSE_TYPE_MOVE_RELATIVE` 的 `(0,0)` delta。最终 adapter 会调用 zero-delta relative move、把 connection 标记为 relative-mouse active，并刷新 cursor tracking；connection 还会把成功入队提交为 peer-input activity 与 auto-disconnect reset，尽管光标没有移动。

`NormalizedMouseInput` 现在先按既有 `[-10000,10000]` 限幅，再拒绝两个轴都为零的 relative event。任一非零轴、极值限幅、absolute move 和其他 mouse kind 保持。Host normalization 定向 test 1/1、完整 Rust lib 122/122、release core、built-core lifecycle/ABI、Swift 109 项、Release App 与 16 文件 clean replay 均通过。未修改 Viewer ABI、wire/protobuf、Host ABI/snapshot 或 Hermes。FarPane Viewer 当前不生产 relative mode；真实第三方 peer/gaming relative input 属于后续互操作验收。详见 `Evidence/HostMode/2026-08-08/h3-zero-delta-relative-mouse-gate.md`。

## H3.4w privileged pseudo-key canonical action gate

`ControlKey::LockScreen` 与 `ControlKey::CtrlAltDel` 不是普通物理键：adapter 的 `is_function_key` 收到任意 action 都会立即触发系统动作。typed normalizer 原本允许 Up，也允许 Press；后者在 input worker 被展开为 down/up，因而可能执行两次。携带 modifiers 的消息同样被接受，但系统动作 consumer 完全忽略这些 modifiers。

官方 pinned producer 对两种 pseudo-key 都只生成 Legacy、`down=true`、`press=false`、无 modifiers 的事件。`NormalizedKeyInput` 现在把该形式设为唯一 canonical contract；Up、Press、down+press 与任何 modifier 组合都在 queue admission 前拒绝。定向 key normalization 1/1、完整 Rust lib 122/122、release core、built-core lifecycle/ABI、Swift 109 项、Release App 与 16 文件 clean replay 均通过。未修改 protobuf enum、Viewer/Host ABI、Hermes 或其他 control key。真实 Mini 锁屏行为不在本步自动触发，避免破坏用户会话。详见 `Evidence/HostMode/2026-08-08/h3-privileged-pseudo-key-action-gate.md`。

## H3.4x Native Host privileged-key platform capability

H3.4w 已规范 privileged pseudo-key action，但 `CtrlAltDel` 的最终 consumer 只在 Windows 编译 SAS 实现；macOS/Linux 分支仍返回 handled，实际没有系统动作。macOS Native Host 因而会把合法格式的 CtrlAltDel 入队并提交 peer-input activity/auto-disconnect，最终却 no-op。

Native Host 现在在 typed normalization 后、queue admission 前按 platform capability gate `CtrlAltDel`：仅 Windows-capable build 允许；macOS/Linux Native Host 拒绝。`LockScreen` 继续允许，non-Native pinned upstream 继续兼容。定向 capability test 1/1，完整 Rust lib 增至 123/123；release core、built-core lifecycle/ABI、Swift 109 项、Release App 与 16 文件 clean replay 均通过。未修改 protobuf、Viewer/Host ABI、Hermes 或系统状态，也未触发真实锁屏/SAS。详见 `Evidence/HostMode/2026-08-08/h3-privileged-key-platform-capability.md`。

## H3.4y desktop control-key consumer coverage

typed key normalizer 原本接受 protobuf 中除 Unknown 外的全部 `ControlKey`，但 desktop `process_control_key` 只会消费 `KEY_MAP` 命中的键；`VolumeMute`、`VolumeUp`、`VolumeDown`、`Power` 在该 map 中不存在。它们经 Legacy/Auto wire 进入 Native Host 时会成功入队并提交 activity，最终没有键盘动作。

Legacy/Auto control-key normalization 现在以 desktop `KEY_MAP` 为普通键 authority，并显式保留 `LockScreen`/`CtrlAltDel` 两个由 `is_function_key` 消费的 pseudo-key。四个无 desktop consumer 的媒体/电源键及 Unknown 在 admission 前拒绝；所有现有映射保持。定向 key normalization 1/1、完整 Rust lib 123/123、release core、built-core lifecycle/ABI、Swift 109 项、Release App 与 16 文件 clean replay 均通过。未修改 protobuf、Viewer/Host ABI、Hermes，也不影响移动端专用输入路径。详见 `Evidence/HostMode/2026-08-08/h3-desktop-control-key-consumer-coverage.md`。

## H3.4z Viewer pointer payload-field canonicality

`RDNPointerEvent` 同时携带 position (`x/y`) 与 scroll (`scrollX/scrollY`) 字段，但每种 semantic kind 只消费其中一组。Viewer bridge 过去会忽略另一组中的非零值并返回成功，使同一 ABI payload 可以有多种有歧义的表示，也会掩盖调用方把 position 与 delta 写反的错误。

Viewer ABI 现在要求 Move/Down/Up 的 scroll 字段必须为零，Scroll/PreciseScroll 的 position 字段必须为零；混用字段在生成 wire event 前以 `-4` fail closed。当前 Swift producer 已按该 canonical 形式构造事件，所以正常移动、拖拽与滚动行为不变。producer 定向 test 1/1、完整 Rust lib 123/123、release core、built-core Host lifecycle 3/3、built-core ABI 1/1、Swift 109 项（4 项条件跳过）、Release App 与 16 tracked + 2 bridge clean replay 均通过。未修改 ABI shape、wire/protobuf、Host ABI/snapshot 或 Hermes。详见 `Evidence/HostMode/2026-08-08/h3-viewer-pointer-payload-field-canonicality.md`。

## H3.4aa Viewer key payload-field canonicality

`RDNKeyEvent` 为 Character、special key 和 Physical 同时暴露 `unicodeScalar` 与 `hardwareKeycode`，但每种 key kind 只消费其规定字段。Viewer bridge 过去会静默忽略另一字段中的非零值，使错误构造的 ABI payload 仍返回成功。

Viewer ABI 现在要求 Character 的 hardware keycode 为零、Physical 的 Unicode scalar 为零、所有 special key 的两者都为零；混用字段在 session/wire 前以 `-4` fail closed。当前 Swift producer 已严格按该 canonical 形式构造事件，正常字符、特殊键和 exclusive physical-key 输入保持不变。producer 定向 test 1/1、完整 Rust fresh rerun 123/123、release core、built-core Host lifecycle 3/3、built-core ABI 1/1、Swift 109 项（4 项条件跳过）、Release App 与 16 tracked + 2 bridge clean replay 均通过。首轮完整 Rust 的 cursor-data 运行态测试因测试期间本机光标变化失败，单测复跑及完整复跑均通过，未修改无关测试。未修改 ABI shape、wire/protobuf、Host ABI/snapshot 或 Hermes。详见 `Evidence/HostMode/2026-08-08/h3-viewer-key-payload-field-canonicality.md`。

## H3.4ab Mini native input acceptance

用户在 Mac mini 安装当前 arm64 Host build，并从 MacBook Pro 的 FarPane Viewer 完成此前列出的输入矩阵；点击、拖拽、滚动、键盘/输入法、修饰键清理、连接保持、断开后回到可连接状态及重连均通过，未发现输入异常。这关闭了上述普通单显示器 active-Aqua 输入链的本轮人工验收，但不覆盖多显示器切换、Secure Input、Accessibility 撤权恢复、锁屏/LoginWindow 或 off-console transition。

同次观察的编码/呈现帧率约为 9–12 FPS，随后约 8.3 FPS。它落在 adaptive cadence 的 low-motion 档附近，但当前没有“持续运动期间”的 cadence/encode/queue/renderer 时间序列，因此不能据此判定正常或异常，也不能把它作为 30 FPS 性能验收。若持续拖拽/滚动时仍保持该范围，应回到 H2 performance runner 分层定位。详见 `Evidence/HostMode/2026-08-08/h3-mini-input-acceptance.md`。

## H3 automatic completion audit

按 §21 H3 与 §26.6 的交付/退出条件逐条核对后，H3 明确仍未完成，不能把 H3.3/H3.4 的内部输入安全工作等同于产品阶段完成：

- H3.1 的 dedicated mutable-byte password ABI、双端 wipe、set/clear、Rust policy、snapshot 状态与本机 secure-field UI 已在后续 H3.1b 完成；UI 真机验收仍待进行。
- H3.2 已有五种模式的 policy model、native single-pending broker 和后续 H3.2b2 snapshot/approve-reject 合同；App 入站 UI 与 AND mode runtime mapping 仍未实现。
- H3.3 已有 connection-scoped permission epoch、ordered cleanup、single active lease 与 final adapter gate；但 HostSnapshot 没有 active session/capability state，generic command 也没有 revoke/disconnect，App 重建不能恢复或操作当前会话。
- H3.4 的 Rust authorization → typed semantic input → platform adapter 自动链基本闭合，普通单显示器 active-Aqua 的 click/drag/scroll/keyboard/IME/modifier cleanup/断连重连已获 Mini 人工通过；Secure Input、TCC/session transition、多显示器及正式性能 telemetry 仍缺真机证据。

该审计完成时 Host Control ABI 仍只有通用 JSON command 和最小 H1 snapshot；其 H3.1 缺口已由后续 ABI v3/schema v2 实现关闭。H3.2/H3.3 的 shared snapshot/event 缺口仍成立。详细历史矩阵、证据强度和推荐顺序见 `Evidence/HostMode/2026-08-08/h3-automatic-completion-audit.md`。

## H3.1b permanent-password secret-buffer readiness（历史检查点）

pinned core 的真实 setter 已确认可作为唯一 Rust authority：它为本地更新生成稳定 salt-bound 32-byte H1，将 verifier 编码并用随机 nonce secretbox 保护后写入配置，实际变更会清除 trusted devices；认证链直接恢复 H1 并完成 challenge comparison。因为不需要恢复永久密码明文，FarPane 不应另外把明文存入 Keychain。

当前 setter 接受 `&str`，没有 Rust strength gate；旧 UI 的至少 6 字符规则只在 UI，不能作为 HostCore 权威。空字符串只清除 local storage，若 preset password 可用，effective permanent password 仍然存在。因此正式 ABI 必须区分 set 与 clear，并在 snapshot/result 中分别报告 local/effective/preset/changeAllowed，不能把“local cleared”显示成“无永久密码”。

专用入口可以使用 caller-owned mutable UTF-8 bytes，Rust 借用而不复制、调用 in-process setter，并以现有 libsodium `memzero` 在所有返回路径清零；Swift 用 mutable `Data` 调用并在 `defer` 中再次 `resetBytes`。正式实现还必须清零 setter 内部的 H1 临时数组。AppKit secure field 的系统内部副本不可由应用证明擦除，只能立即清空控件并保证显式 transfer buffer 的双端 wipe。

该检查点当时尚未修改 ABI；其建议合同现已由 ABI v3/schema v2 实现。readiness 原始证据保留于 `Evidence/HostMode/2026-08-08/h3-permanent-password-secret-buffer-readiness.md`，最终实现证据见 `Evidence/HostMode/2026-08-08/h3-permanent-password-secret-buffer.md`。
