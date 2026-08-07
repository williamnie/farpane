# Host Mode H1a 进展报告 — Host Control ABI 与同进程 HostCore

- 日期：2026-08-05 ~ 2026-08-07
- 基线机：Mac mini（Mac16,11，M4 Pro，arm64），即 §26.2 指定的本机
- 上游：RustDesk 1.4.9 @ `6c578292e8ebbbec708b76986ba8c4bc7c509747`（pinned）
- 对应设计：`docs/host-mode-design.md` §6.1/§6.2/§6.3、§8.1–8.5、§9、§18、§20.2、§26.2

## 1. 范围与已落地决策（对齐清单 ★A–E）

| 决策点 | 落地形态 |
| --- | --- |
| ★A 控制面信封 | 版本化 JSON envelope（command/event/snapshot 三类），低频语义控制通道，媒体不走该通道 |
| ★B config-root 入口 | `rdn_host_set_config_root(app_name, org)`：进程级一次性早期入口，写 hbb_common `APP_NAME`/`ORG`（macOS），之后任何再调用返回 BAD_STATE |
| ★C HostCore 运行线程 | Rust 侧自持运行时线程（上游 `start_server` 语义），Swift 侧仅控制 |
| ★D 命名空间 | `APP_NAME=FarPaneHost`（产品）/测试用 `FarPaneHostTests`，三目录（config/log/库）隔离，namespace 验证拒绝 `/ \ : .. \0` 等 |
| ★E server 配置 | Host ABI v2 的 `RdnHostCreateOptions` 接收 rendezvous/relay/hbbs `key.pub`，create 时复制、校验，start 时在首次 identity/Rendezvous 访问前写入隔离 Host 配置根；不接受或暴露 hbbs 私钥 |

错误码合同（稳定，负值为合同失败）：`0 OK / -1 INVALID_ARG / -2 ABI_MISMATCH / -3 BAD_STATE / -4 NOT_SUPPORTED / -5 VALIDATION / -6 INTERNAL`。

## 2. H1a.1 Host Control C ABI（完成）

交付物：

- `CoreBridge/RustDeskPatch/rdn_host_bridge.rs`（新增，~490 行）：独立 `rdn-native-host` feature；`rdn_host_set_config_root/create/start/stop/command/copy_snapshot/free_bytes/destroy` + `rdn_host_abi_version/upstream_commit`；单实例互斥守卫 `HOST_INSTANCE_LIVE`；config-root 未设置时 create fail-closed；临时密码一次性 reveal（revealed 后自动回落 redacted），stop/destroy 轮换密码。
- `CoreBridge/RustDeskPatch/upstream-1.4.9.patch` 重新生成：Cargo.toml `rdn-native-host = []` + `lib.rs` feature-gated mod 声明；无该 feature 时上游行为不变。
- `CoreBridge/include/rustdesk_native.h`：Host Control ABI 声明节（错误码宏、状态/停止原因枚举、owned bytes/callbacks/options 结构、10 个函数声明），`cc -fsyntax-only` 通过。
- `Scripts/bootstrap-rustdesk-core.sh` / `Scripts/build-rust-core.sh`：host bridge 同步 + `--features rdn-native-core,rdn-native-host` + 8 个 host 符号 nm 门禁。
- `THIRD_PARTY_NOTICES.md`：AGPL 修改清单增补 `rdn-native-host` 条目。

构建证据：release dylib `Build/CoreBridge/arm64/liblibrustdesk.dylib`，`nm -gU` 导出 10 个 `rdn_host_*` 符号；Viewer ABI 保持 v5。

## 3. H1a.2 同进程 HostCore（完成）

合同测试（`Tests/CoreBridgeTests/HostBridgeContractTests.swift`，dlopen 实测 dylib）证明的完整生命周期：

1. create 在 set_config_root 之前返回 BAD_STATE（fail closed）；
2. namespace 验证：`../evil`、`a/b`、空串返回 VALIDATION，nil 返回 INVALID_ARG；
3. set_config_root 成功且二次调用返回 BAD_STATE（一次性）；
4. create 成功；第二并发实例返回 BAD_STATE（§18 规则 1 互斥）;
5. start 后 snapshot：未注册时保持 `hostState=starting`、`registrationStatus=pending`，不伪造 ready；注册成功后才收敛到 `ready`，`localId` 非空、密码 `policy=redacted`；
6. `regenerateTemporaryPassword` / `revealTemporaryPassword` 命令后 snapshot 一次性携带明文（`policy=revealed`），下一次 copy 自动回落 redacted（§9.2）；
7. stop/destroy 成功，实例槽位释放（可重新 create）；事件回调有 envelope 到达；
8. 测试专用配置根（`~/Library/Application Support/FarPaneHostTestsRoot`）清理。

接入面：

- `CoreBridge/Shim/rdn_shim.c`：生产加载路径扩展 host 符号解析（all-or-nothing，viewer-only core 仍可加载），`rdn_shim_host_*` 包装函数齐备；
- `Sources/CoreBridge/HostControlClient.swift`：Swift 封装（加载/ABI 校验 → setConfigRoot → start → command/copySnapshot → stop），事件经 DispatchQueue 派发，临时密码仅存在于一次性 snapshot 内存对象；
- App 启动集成已完成：主页按用户偏好启动 HostCore，展示权威状态/本机 ID/临时密码操作；发起 outbound Viewer 前完整停止并释放 Host Core，返回主页后恢复。

## 4. H1a.3 稳定 ID 与临时密码（完成）

- `config::Config::get_id()` 提供隔离 Host 配置根中的稳定 ID；`password_security::update_temporary_password()` 生成协议兼容的 CSPRNG 临时密码。密码默认 redacted，仅在一次性 snapshot 中 reveal，30 秒后 UI 自动清除；可主动隐藏和轮换。
- Hermes hbbs 公钥未硬编码。Host ABI v2 接收 canonical rendezvous/relay/public-key 输入，在 acquire singleton 之前执行 base64、长度与非法分隔符校验，并在首次 identity/Rendezvous 访问前写入隔离配置根。
- HostCore 自持可取消 Rendezvous runtime 线程；stop/destroy 设置上游退出标志并 join。只有 `Config::get_key_confirmed()` 与 online state 同时满足才报告 `registrationStatus=ready`；运行时异常退出报告 degraded/error。
- Hermes 实链完成两次完整注册，中间执行 stop/destroy，两个非空 ID 相同且均到达 ready。隔离 App 还验证了首次启动 ready、Host 关闭、重新开启后再次 ready。

## 5. App 接入与互斥生命周期

- 主页新增“允许连接此 Mac”开关、注册状态、本机 ID、临时密码显示/隐藏/轮换入口；错误只显示稳定、脱敏的产品文案。
- 用户偏好存入 `UserDefaults`；服务器配置仍以产品 catalog 为唯一 canonical 输入，不复制私钥或建立第二套设置。
- 普通开关与服务器配置更新复用同一已完成 config-root 隔离的 Host Core，避免二次切换配置根；发起 Viewer 或 App 退出时才 stop/destroy 并释放动态库，保持 H1–H3 的 Host/Viewer 互斥约束。
- 隔离验收 App 使用独立 bundle ID、临时 catalog 和现有本机公开配置；验收后进程、偏好域和临时目录均已清理。

## 6. 证据索引

- `Evidence/IntelMBP/2026-08-06/HostMode/h1a-contract-tests.log`：全量 swift test 41/41 通过（含 3 个 host 合同测试）。
- `Evidence/HostMode/2026-08-07/h1a-registration.md`：arm64 Core 构建、Hermes 双注册稳定 ID、产品 App 启动/开关/密码操作实链证据。

## 7. 下一步

H1a 退出条件已满足，进入 §26.3 H1b 媒体链路：ScreenCaptureKit → VideoToolbox → RustDesk transport 的单显示器编码与发送闭环。
