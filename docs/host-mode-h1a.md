# Host Mode H1a 进展报告 — Host Control ABI 与同进程 HostCore

- 日期：2026-08-05 ~ 2026-08-06
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
| ★E server 配置 | 预留 `RdnHostCreateOptions`（当前仅 abi_version，零初始化），Hermes server 配置后续经 create options 传入 |

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
5. start 后 snapshot：`hostState=ready`、`registrationStatus=pending`、`localId` 非空、密码 `policy=redacted`；
6. `regenerateTemporaryPassword` / `revealTemporaryPassword` 命令后 snapshot 一次性携带明文（`policy=revealed`），下一次 copy 自动回落 redacted（§9.2）；
7. stop/destroy 成功，实例槽位释放（可重新 create）；事件回调有 envelope 到达；
8. 测试专用配置根（`~/Library/Application Support/FarPaneHostTestsRoot`）清理。

接入面：

- `CoreBridge/Shim/rdn_shim.c`：生产加载路径扩展 host 符号解析（all-or-nothing，viewer-only core 仍可加载），`rdn_shim_host_*` 包装函数齐备；
- `Sources/CoreBridge/HostControlClient.swift`：Swift 封装（加载/ABI 校验 → setConfigRoot → start → command/copySnapshot → stop），事件经 DispatchQueue 派发，临时密码仅存在于一次性 snapshot 内存对象；
- App 启动集成（RustDeskNativeApp 接入 HostCore + UI 开关）与 H1a.3 注册验收一同收尾，避免在无 Hermes 配置下产生半成品 UI。

## 4. H1a.3 稳定 ID 与临时密码（部分就绪，注册验收阻塞）

- 已就绪：`config::Config::get_id()` 稳定 ID 读取 + `password_security::update_temporary_password()` CSPRNG 临时密码（协议兼容上游），snapshot 最小字段集（§8.3）已按合同输出；生命周期测试断言 `localId` 非空、密码不落文件/日志（仅内存一次性 reveal）。
- 阻塞项：Rendezvous 注册验收需要 Hermes hbbs 公钥（`key.pub`）；本机未存储该密钥，待用户提供后执行 §9.1 注册验收与 `registrationStatus=ready` 断言。

## 5. 证据索引

- `Evidence/IntelMBP/2026-08-06/HostMode/h1a-contract-tests.log`：全量 swift test 41/41 通过（含 3 个 host 合同测试）。

## 6. 下一步

1. `[手动]` 用户提供 Hermes hbbs 公钥 → H1a.3 注册验收（稳定 ID 不随 App 重启变化、registrationStatus=ready）；
2. App 启动路径接入 `HostControlClient`（早期 setConfigRoot + HostCore 开关）；
3. H1a 收尾 commit/push 后进入 §26.3 H1b 媒体链路。
