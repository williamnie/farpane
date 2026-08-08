# H3.3h2 recoverable active-session snapshot contract

- 日期：2026-08-08
- 范围：Host Control ABI、HostSnapshot、Rust active-session broker projection、Swift strict decoder
- 结论：App 可从 shared HostSnapshot 恢复同一 Rust authority 的 typed active-session state；撤权、断开与产品 UI 留作后续独立步骤

## Contract

1. Host Control ABI 从 v4 升至 v5；HostSnapshot schema 从 v3 升至 v4。Host event schema 独立保持 v1，Host Media ABI 保持 v1。
2. snapshot 顶层新增必需字段 `activeSession`，无会话时为 null；有会话时直接复制 H3.3h1 `SESSION_BROKER` 的 snapshot，不从事件、媒体 route 或 Swift 状态推断。
3. active object 精确包含 `connectionId`、remote ID/name/platform、固定 `remoteMetadataTrust=untrusted`、`startedAt`、`initialCapabilities` 与 `activeCapabilities`。
4. canonical connection ID 仍由 Rust Host instance ID 和 core connection ID 生成。snapshot copy 会验证当前 Host instance prefix；不匹配时 fail closed 为 null。
5. remote metadata 只用于显示，已经过 256 UTF-8 byte 上限和控制字符清洗；它不参与 authority、命令路由或信任判断。
6. initial capabilities 是授权时的 immutable baseline；active capabilities 是当前 effective permission。两者都固定包含 `viewDisplay`，clipboard read/write 成对，active 必须为 initial 子集。

## Swift fail-closed decoder

- `HostActiveSession` 要求精确字段集合，拒绝额外字段。
- connection ID 必须非空、最多 128 UTF-8 bytes、无控制字符，并绑定 snapshot 的 `hostInstanceId`。
- remote ID 必须非空；remote name/platform 可为空，但都受 256 UTF-8 byte 与控制字符门禁。
- capability array 必须有界、无重复、只含 `viewDisplay`、`controlKeyboardMouse`、`readClipboard`、`writeClipboard`、`hearSystemAudio`。
- 未知 capability、伪造 trusted metadata、clipboard 单边能力、active 超出 initial、旧 schema 或非 object/null 均拒绝整个 snapshot。
- App 既有 `copySnapshot` polling 与 event-schema-v1 `snapshotChanged` 只触发重新读取；不会用事件建立第二套 session owner。

## Red-green evidence

- Swift RED：新增 snapshot 合同测试首先编译失败，精确原因为 `HostCoreSnapshot` 没有 `activeSession`。
- Rust RED：活动会话生命周期测试读取 snapshot，精确失败于实际 schema 3 而合同要求 4。
- GREEN：broker begin 后 snapshot 返回 canonical ID、untrusted metadata 与 initial/active capability；permission update 后 active capability 同步，connection end 后恢复 null。
- Swift GREEN：valid active session 与 pending approval 可同时恢复；null、unknown field/capability、伪 trust、capability 越权和 schema 3 拒绝矩阵通过。

## Verification

- targeted Rust active-session snapshot/lifecycle：1 passed, 0 failed。
- targeted Swift active-session decoder：1 passed, 0 failed。
- Rust library tests with `rdn-native-core,rdn-native-host`：129 passed, 0 failed。
- `Scripts/build-rust-core.sh`：release arm64 core、Mach-O 与导出符号门禁通过；130 个 pinned/upstream warnings，无编译错误。
- 实际加载新 core 的 `swift test --quiet`：130 passed, 0 skipped, 0 failed；Host lifecycle/ABI 3/3 包含 ABI v5 与 schema v4 检查。
- `python3 -m unittest discover -s Tests/ScriptTests`：20 passed, 0 failed。
- `swift build -c release --arch arm64`：success。
- canonical/vendor Host bridge mirror、rustfmt、diff whitespace 与 patch reverse-check 通过。
- 锁定 RustDesk/HBB clean clone 重放后，16 个 upstream patched files、2 个 hbb_common files 与 2 个 canonical bridge files 逐一一致。

## Security and scope

- snapshot 不含密码、认证 payload、服务器、公钥、地址、输入内容、剪贴板内容、画面、坐标或原始错误。
- 未修改 RustDesk protobuf、Hermes、CI、根依赖、数据库、TCC 数据库或密钥配置。
- 本步构建的新 core 未安装到 Mini；Mini 继续使用 build `20260808131034` 和此前已验证 core。

## Remaining boundary

- 还没有精确绑定 canonical connection ID 的 permission revoke 或 disconnect command；Swift 也没有对应 typed command API。
- Host 卡片尚未显示活动会话或提供本机控制，因此“可恢复 typed state”不等于产品会话管理已完成。
- Accessibility TCC 与 active Aqua session 的运行时 transition 不会主动更新 snapshot capability；adapter 仍按现有 fail-closed gate 拒绝输入。
- 双 controller busy、App rebuild、撤权 backlog、断开与重连仍需安装最终 command/UI build 后真机验收。

## Next step

在 ABI v5/schema v4 上增加精确 `setSessionCapability` 与 `disconnectSession` command：只接受当前 canonical connection ID、固定 capability/action 和精确字段集合；由同一 broker/connection sender 执行，并提供稳定 stale/not-found/finalized 结果。
