# H3.3h3 scoped active-session revoke/disconnect commands

- 日期：2026-08-08
- 范围：Host Control ABI、Rust active-session broker command routing、Swift typed command API
- 结论：本机调用方可用 snapshot 中的 canonical connection ID 精确撤销当前会话的输入、剪贴板、系统音频能力，或请求有序断开；产品会话卡片和真机验收仍是后续边界

## Contract

1. Host Control ABI 从 v5 升至 v6；HostSnapshot schema 继续为 v4，event schema 与 Host Media ABI 继续为 v1。旧 v5 core 因 ABI mismatch fail closed，不会把新命令误判为成功的 unknown command。
2. 固定命令为 `disableInputForActiveSession`、`disableClipboardForActiveSession`、`disableAudioForActiveSession` 与 `disconnectSession`。每个 envelope 只允许 `commandId`、`name`、`connectionId` 三个字段。
3. connection ID 必须绑定当前 Host instance。其他 instance 返回 session-not-found；当前 instance 下非活动 ID 返回 session-stale；无活动会话返回 session-not-found。
4. 三种撤权分别向该 connection 的既有 command queue 发送 `SwitchPermission(keyboard|clipboard|audio, false)`。connection 继续负责 effective permission、epoch 轮换、ordered cleanup、Viewer permission notification 与最终 capability snapshot；broker 不乐观修改状态。
5. `disconnectSession` 向同一 queue 发送 `Close`，因此复用既有 connection teardown、输入 cleanup 与 single-session lease release。活动会话上的重复请求幂等，不重复发送 `Close`。
6. 已禁用能力返回成功且不重复入队；sender 已关闭返回稳定 session-command-unavailable。错误码分别为 -24、-25、-26，Swift 只对 `.command` 错误做 typed classification。

## Red-green evidence

- Swift RED：类型化 capability/API 尚不存在，合同测试编译失败于缺少 `HostSessionRevocableCapability` 与 `sessionCommandFailure`。
- Rust RED：带额外字段的撤权 envelope 被旧 generic handler 当作 unknown command 返回成功；预期 validation failure，实际为 0。
- GREEN：精确 envelope 才能进入当前 session broker；三类 permission IPC、stale/foreign/ended ID、重复断开、already-disabled no-op 与 closed sender 全部由 Rust 定向测试覆盖。
- built-core lifecycle 直接调用 C ABI，验证无活动会话返回 -24，带额外字段返回 -5，并校验 ABI v6。

## Verification

- targeted Rust session command test：1 passed, 0 failed。
- targeted Swift command typing/error test：1 passed, 0 failed。
- Rust library tests with `rdn-native-core,rdn-native-host`：130 passed, 0 failed。
- `Scripts/build-rust-core.sh`：release arm64 core 生成成功，Mach-O 与导出符号门禁通过。
- 实际加载新 core 的 `swift test --quiet`：131 passed, 0 skipped, 0 failed。
- `python3 -m unittest discover -s Tests/ScriptTests`：20 passed, 0 failed。
- `swift build -c release --arch arm64`：success。
- canonical/vendor Host bridge mirror、rustfmt、diff whitespace 与 patch reverse-check 通过。
- 锁定 RustDesk `6c578292` 与 hbb_common `7e1c392` 的 clean clone 重放后，16 个 upstream patched files、2 个 canonical bridge files 与 2 个 hbb_common files 逐一一致。

## Security and scope

- 命令只携带本地生成的 connection ID 与固定枚举，不含密码、密钥、服务器、剪贴板内容、输入内容、坐标、画面或远端原始错误。
- 未修改 protobuf、Hermes、CI、根依赖、数据库、TCC 数据库或服务器配置。
- 新 core 未安装到 Mini；`/Applications/FarPane.app` 继续保留此前已验证 build，避免在产品 UI 与真机验收前覆盖运行版本。

## Remaining boundary

- Host 卡片还没有展示 active session，也没有把三个撤权和断开操作接到用户界面；本步是 shared command contract，不等同于产品会话管理完成。
- App rebuild、撤权 backlog、断开/重连、TCC 与 active Aqua transition 仍需最终 UI build 和 Mini/控制端真机验收。
- 当前 snapshot capability 只在 connection 应用 permission 后更新；这是有意保留的单一 authority，不应由 Swift 根据 command success 乐观推断。

## Next step

实现 Host active-session card：只从 recoverable snapshot 呈现 remote metadata/capability，调用 typed revoke/disconnect API，随后以 `snapshotChanged`/有界 refresh 重新 copy snapshot，并对 stale/not-found/unavailable 给出明确的非乐观状态。
