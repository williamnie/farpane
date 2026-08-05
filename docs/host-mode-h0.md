# Host Mode H0：基线与许可证门禁报告

> 日期：2026-08-05
> 对应计划：`docs/host-mode-design.md`（Draft v0.3）§26.1 阶段 0
> 状态：H0 完成（2026-08-05）
> 上游基线：RustDesk 1.4.9 @ `6c578292e8ebbbec708b76986ba8c4bc7c509747`（`Vendor/rustdesk/`）

## 1. H0.1 AGPL 合规清单

现状核对结果（已逐项核实）：

| 项 | 位置 | 状态 |
|---|---|---|
| AGPL-3.0 全文 | 仓库根 `LICENSE` | ✓ 已存在 |
| 上游 pinned commit 与修改说明 | `THIRD_PARTY_NOTICES.md` | ✓ 已记录 viewer 侧 `rdn-native-core` patch；Host patch 落地后需增补 |
| 许可证节（中英） | `README.md` §许可证 / §License | ✓ 已声明 AGPL 与对应源码义务 |
| 许可证决策记录 | `docs/architecture.md` §10.4 | ✓ "RustDesk 派生按 AGPL 管理" |
| patch 载体 | `CoreBridge/RustDeskPatch/upstream-1.4.9.patch`、`rdn_bridge.rs` | ✓ 修改集中在可追踪文件 |
| vcpkg 第三方许可 | `Contents/Resources/ThirdPartyLicenses/`（打包时内置） | ✓ NOTICES 已约定 |

发布前必须执行的清单（设计文档 §4.2）：

1. **对应源码（AGPL §6/§13）**：随二进制提供完整源码、构建脚本（`Scripts/`）与许可证/版权通知。当前公开仓库 + GitHub Release 已满足分发场景；每次 release 保持 tag 与源码可追溯。
2. **修改说明（AGPL §5a）**：`THIRD_PARTY_NOTICES.md` 记录 pinned commit 与修改范围。动作项：`rdn-native-host` feature 与 Host patch inventory（本报告 §3）落地后，同步增补该条目。
3. **网络交互条款（AGPL §13）**：FarPane 是桌面客户端而非网络服务；与被控/控制端的远程交互属于"通过计算机网络交互"，需保证对方用户可获得对应源码——由公开仓库/Release 源码附带满足。动作项：Host Mode 首次对外分发前复核一次。
4. **产物内通知保留**：`LICENSE`、`THIRD_PARTY_NOTICES.md`、`ThirdPartyLicenses/` 随 App bundle 分发（打包脚本已有先例，Host 阶段不得移除）。
5. **闭源另版禁止沿用本结论**（设计文档 §4.2 末段）：如未来另立闭源商业版，按新产品重新评估。

结论：**AGPL 清单对内部 Spike 无阻塞**；动作项 2、3 是 Host patch 落地/对外分发时的同步更新项，已列入追踪。

## 2. H0.2 进程全局状态与配置/Keychain 读写集盘点

### 2.1 配置与文件读写集（pinned core 实测代码路径）

所有桌面端配置都经由 `hbb_common::Config::path()`（`libs/hbb_common/src/config.rs` L783）决定，macOS 上为 `directories_next::ProjectDirs::from("", ORG, APP_NAME)` 的 `config_dir`，默认即 `~/Library/Application Support/com.carriez/RustDesk`（`ORG` L57 默认 `com.carriez`，`APP_NAME` L72 默认 `RustDesk`）。

| 存储项 | 文件/路径 | 内容 | 代码位置 |
|---|---|---|---|
| `RustDesk.toml` | `Config::file()` L738 | **本机 ID（`enc_id` 加密形式）、key_pair、options（含 rendezvous/direct 端口等）** | L738–745 |
| `RustDesk2.toml` | `Config2::file()` L513 | unlock_pin、trusted_devices | L513–515 |
| `LocalConfig` | `LocalConfig::load` L66 | 本地 UI/会话偏好 | L66 |
| `Status` | `_status` 后缀 L3251 | 状态项 | L3249–3252 |
| `peers/<id>` | `PeerConfig` L1704 | **每个对端的连接历史与存储密码（加密）** | L1704–1708 |
| 日志 | `~/Library/Logs/{APP_NAME}` | 运行日志 | `log_path` L815–822 |
| IPC socket | `/tmp/{APP_NAME}-{uid}/ipc`（macOS） | 单实例 IPC | `ipc_path` L845、`ipc_parent_dir_for_uid` L142 |
| icons | `Config::path("icons")` | 图标缓存 | L896 |

要点：

- **ID、密钥、options 全部序列化在 `RustDesk.toml` 内**，没有独立 id/密钥文件；`Config::load`（L612）首次加载即可能生成 id 并回写（L650–652）。
- **上游 Rust 侧完全不使用 macOS Keychain**（全仓库 grep `keychain|Security.framework|SecItem` 零命中）。FarPane Swift viewer 的 Keychain 使用（`DeviceCredentialStore`）是自有命名空间，与上游无冲突。Host 永久密码（设计文档 §9.3）将新引入 Keychain 条目，需定义独立 service/account 命名并在 H3.1 记录。
- **桌面无 `RUSTDESK_*` 环境变量覆盖配置根**（config.rs 无 env 读取）：印证设计文档 §18 规则 6 "不用环境变量猜测路径"的判断；隔离只能靠 `APP_NAME`/`ORG` 或显式 patch。
- Rendezvous server 来源：`custom-rendezvous-server` option（在 `RustDesk.toml` 内）与 `EXE_RENDEZVOUS_SERVER`/`PROD_RENDEZVOUS_SERVER`（L70–71）。**隔离配置根后，自托管 Hermes 服务器配置必须在新根内预置**，否则 HostAgent 注册到错误服务器。

### 2.2 进程级全局状态清单

| 全局 | 位置 | Host 影响 |
|---|---|---|
| `CONFIG` / `CONFIG2` / `LOCAL_CONFIG` / `STATUS` / `KEY_PAIR` / `USER_DEFAULT_CONFIG` | config.rs L63–75（lazy_static，首次访问即加载落盘） | ID/密钥/密码/options 进程唯一；**Host 与 Viewer 同进程共享同一 ID** |
| `APP_NAME` / `ORG` | config.rs L57、L72（`RwLock`） | 唯一决定配置根/日志/IPC 路径；唯一写入口是 `read_custom_client`（common.rs），可被受控 patch 复用 |
| `PEER_DECODINGS` / `ENCODE_CODEC_FORMAT` / `USABLE_ENCODING` | `libs/scrap/src/common/codec.rs` L42–43 | **codec 协商全进程唯一**，host+viewer 并存会互相污染（本报告 §3.2） |
| `VIDEO_QOS` / `FRAME_FETCHED_NOTIFIERS` / `DISPLAY_CONN_IDS` | `src/server/video_service.rs` L68–81 | QoS/ACK 按 service name + conn id 登记 |
| `SYNC_DISPLAYS` / `PRIMARY_DISPLAY_IDX` / `TEMP_IGNORE_DISPLAYS_CHANGED` | `src/server/display_service.rs` | `PRIMARY_DISPLAY_IDX` 一次性固化，插拔显示器不更新 |
| `SHOULD_EXIT` / `MANUAL_RESTARTED` | `src/rendezvous_mediator.rs` | 进程唯一退出开关 |
| 端口 21116（rendezvous）/ 21117（relay）/ 21118（direct，`direct-access-port`） | config.rs、rendezvous_mediator.rs | 同机第二个 server 实例监听同一 direct 端口会失败 |
| IPC 单例 | `start_server` 中 `ipc::start("")`（server.rs L592） | IPC 被占则退出，天然单实例互斥 |

### 2.3 对后续阶段的结论

1. **H1–H3 同进程 Spike 的互斥有充分依据**（设计文档 §18 规则 1）：`CONFIG`、`ENCODE_CODEC_FORMAT`、`VIDEO_QOS` 都是进程全局，Host 与 outbound Viewer 不能同进程并存，必须保持现有互斥并用合同测试证明无残留。
2. **config-root 隔离的最小形态已确定**：独立 `APP_NAME`（+ macOS `ORG`）即可完成文件系统级隔离（配置目录、toml 文件名、日志目录、IPC socket 全部随之变化），无需 env 覆盖。**生死线是设置时机**：必须在 `CONFIG` lazy_static 首次触碰之前设置，Host ABI 需提供先于一切调用的早期入口（如 `rdn_host_set_config_root()`）。
3. **HostAgent 启动顺序约束**（H4.4）：新配置根建立 → 预置 canonical server 配置（rendezvous/relay/key）→ 才允许任何 `Config::*` 调用。
4. **Keychain 引入点唯一且受控**：仅 H3.1 永久密码（或可恢复 secret），独立 service 命名，不进 toml/日志。

## 3. H0.3 Host patch inventory

行号均经抽查核实（service.rs L231、video_service.rs L669–685、connection.rs L3474/L3484/L4130、codec.rs L42–43/L237/L327）。patch 风格沿用 viewer 侧 `CoreBridge/RustDeskPatch/`（独立 feature、独立 bridge 文件、UPSTREAM_COMMIT 断言）。

### 3.1 NativeVideoSource 接缝（video_service.rs / service.rs）

**现状**：

- 服务创建：`video_service::new(source, idx)`（video_service.rs L243）→ `GenericService::run(&vs, run)` 启动主循环；调用链为 connection.rs `try_sub_monitor_services`（L1980）→ server.rs `try_add_primay_video_service`（L360），切屏走 `switch_display_to`（connection.rs L4180）。
- 主循环 `run`（L536–899）：`get_capturer`（L569，macOS 走 scrap quartz，L302–308）→ `setup_encoder`（L584）→ while 循环内每轮：`check_qos`（L662，读 `video_qos.spf()`）→ `OPTION_REFRESH` 检查（L671–677，触发 `bail!("SWITCH")` 重启整个 service）→ negotiated codec 变化检查（L678–685）→ `try_broadcast_display_changed`（L713，每秒）→ `c.frame(spf)` 采集 → `handle_one_frame`（L1137，`encoder.encode_to_message` → `sp.send_video_frame(msg)` L1172）→ `VideoFrameController` 等对端 `VideoReceived` ACK（L875–888）。
- 发送出口：`GenericService::send_video_frame`（service.rs L231）→ 遍历订阅者逐个发送。订阅：`subscribe/unsubscribe`、`has_subscribes`（service.rs L187）、`snapshot`（L191，新订阅者触发）。

**最小 patch 点**：在 `run` 的 capturer/encoder 创建处（L569 前）加 `#[cfg(feature = "rdn-native-host")]` 分支，替换"采集+编码"为"从 native adapter 接收已压缩 access unit"循环：手工构造 `VideoFrame` proto（display、压缩数据、ms）后调用现成 `sp.send_video_frame`，返回值继续喂 `VideoFrameController` 保留背压。循环保留：`sp.ok()`、OPTION_REFRESH 检查、codec 变化检查、display 变化广播、ACK 等待、spf 限速、`Raii` QoS 登记。

**风险**：

- 新订阅者场景（`handle_one_frame` L1149–1156 的 snapshot→SWITCH 保证新订阅者拿 IDR）：native 循环必须等价实现"新订阅出现→向 adapter 请求 IDR"，兜底仍可 `bail!("SWITCH")`。
- `VIDEO_QOS` bitrate 上报必须来自真实编码器，否则 ABR（video_qos.rs `adjust_ratio`）失效。
- camera 源与 SCREENSHOTS 分支首版可不支持，但 `source.is_monitor()` 判定保持正确。

### 3.2 codec 能力注入与协商接缝（scrap codec.rs / connection.rs）

**现状**：

- 对端能力：客户端 LoginRequest/OptionMessage 携带 `supported_decoding`；登录时 `update_codec_on_login`（connection.rs L2420）、会话中 `update_options`（L4431）调 `Encoder::update`。
- 协商核心：`Encoder::update`（codec.rs L171–324）。h264/h265 可用性 = 所有对端支持解码 **且本端有对应编码器**（L233–236 区域，依赖 `VRamEncoder::available`/`HwRamEncoder::try_get`）；结果写入进程级唯一 `ENCODE_CODEC_FORMAT`（L237）；Auto 优先级 h265 > h264 > av1/vp9（L271–291）。`negotiated_codec()`（L327）是唯一消费接口。

**最小 patch 点**：在 `Encoder::update` 的"本端编码能力"判定处（L233–236 区域）注入：`rdn-native-host` feature 下把 native adapter 实测能力（VideoToolbox 探测结果）作为本端 h264/h265 可用性来源之一。协商算法、prefer 统计、auto 排序全部复用；**selected codec 仍由唯一的 `ENCODE_CODEC_FORMAT` 产生**，满足设计文档 §6.4 第 3 条"Rust 产生唯一 selectedCodec"。

**风险**：

- adapter 能力探测必须早于首次 `Encoder::update`（登录即协商），否则首会话回退 VP9；依赖后续 `EncodingUpdate::Check` 重协商可兜底但不理想。
- `supported_encoding()` 回报给 viewer 的能力需同步反映 native 能力。
- 失败回落路径（`Encoder::set_fallback`、VP9 回退）不应误清 native 能力登记。

### 3.3 refresh/IDR 接缝（connection.rs / video_service.rs / video_qos.rs）

**现状**：

- `Misc::RefreshVideo`（connection.rs L3474）、`RefreshVideoDisplay`（L3484）→ `refresh_video_display`（L4130）→ `Server::set_video_service_opt(display, OPTION_REFRESH, "Y")`。
- 生效机制：video_service.rs 循环 L671–677 检测到 `OPTION_REFRESH` → `bail!("SWITCH")` **重启整个 video service 换 IDR**。
- QoS/ACK 链：`VideoReceived`（connection.rs L3490 区域）→ `notify_video_frame_fetched_by_conn_id` → `VideoFrameController` 背压；`TestDelay` → `VIDEO_QOS.user_network_delay`（video_qos.rs L246）；video service 读目标参数的唯一位置是 `check_qos`（video_service.rs L1318–1353，`spf`、`ratio`、quality）。

**最小 patch 点**：OPTION_REFRESH 通道保持不动；native 循环检测到该标志时**不重启 service**：清标志 → 向 adapter 发 `requestIdr(display, codecEpoch, reason)` → 继续循环；adapter 无法原地出 IDR 时兜底 `bail!("SWITCH")`。QoS 映射：每帧前读 `VIDEO_QOS.spf()` 作节拍，`bitrate()/ratio()` 换算 VT 目标码率，`VideoReceived` ACK 链原样保留。这满足设计文档 §6.4"刷新只触发下一帧 IDR，不沿用一律重启"。

**风险**：上游"重启出 IDR"同时解决新订阅者共享编码器问题，native 原地 IDR 必须同时覆盖该场景；VBR 不支持时 `check_qos` 会 `bail!("SWITCH")`（L1336 区域），adapter 若不支持动态改码率需如实上报 `support_changing_quality=false`。

### 3.4 display 接缝（display_service.rs）

**现状**：`try_get_displays()`（L421，macOS 走 scrap quartz）→ `check_update_displays`（L306，含 scale）；display service 每 300ms 轮询变化并广播 `PeerInfo`（run L229–249）；video service 每秒 `try_broadcast_display_changed`（video_service.rs L1235–1265），变化即发 `SwitchDisplay` misc 并 `bail!("SWITCH")`。切屏由客户端 `SwitchDisplay`/`CaptureDisplays` 触发（connection.rs L4141/L4224）。

**最小 patch 点**：**display 枚举与检测完全复用，零 patch**。每个 `video_service::new(Monitor, idx)` 对应 adapter 一个 `SCStream` 会话；display 变化继续走现有 SWITCH 重建。ScreenCaptureKit 热插拔回调仅作加速提示，权威判定交给 `check_display_changed`，避免双检测竞争。

**风险**：`PRIMARY_DISPLAY_IDX` 一次性固化（L30），插拔后不更新，native 路径不得依赖其实时正确；`DisplayInfo.scale`（retina）影响客户端坐标换算，native 采集尺寸必须与 display_service 上报一致；`temp_ignore_displays_changed` 窗口（L72–85，含 1s sleep）需容忍。

### 3.5 config-root 接缝（hbb_common config.rs）

**现状**：见本报告 §2.1/§2.2。`APP_NAME`/`ORG` 是唯一目录决定因素；`CONFIG` lazy_static 首次访问即加载并可能回写。

**最小 patch 形态（推荐）**：`rdn-native-host` feature 下在**任何 `Config` 访问之前**将 `APP_NAME` 设为 `FarPane`、`ORG` 设为项目 org。效果：配置目录、toml 文件名、日志目录、IPC socket 全部隔离。**结论：单独 `APP_NAME`（+ `ORG`）足够完成文件系统级隔离**，与设计文档 §18 规则 6 的预判一致。备选（env 覆盖 `Config::path`）不推荐：`log_path`/`ipc_path` 不走 `Config::path`，需要多处 patch 且违反 §18"不用环境变量猜路径"。

**风险**：设置时机是唯一难点（见 §2.3 结论 2）；`KEY_PAIR` 缓存与 `get_key_pair` 内的 spawn 写回线程需注意与早期设置的顺序；新配置根需预置 Hermes 自托管服务器配置。

### 3.6 patch inventory 汇总（对照设计文档 §6.4 五条约束）

| # | 设计约束 | 对应 patch | 侵入面 |
|---|---|---|---|
| 1 | 独立 feature，不改无 feature 行为 | `rdn-native-host` feature + `rdn_host_bridge.rs`（新增文件） | 新增 |
| 2 | `NativeVideoSource` 产生者端注入，保留订阅/display/QoS/writer | video_service.rs `run` 循环 cfg 分支（§3.1） | 1 个函数内分支 |
| 3 | native 能力注入协商，Rust 唯一 selected codec | codec.rs `Encoder::update` 能力判定（§3.2） | 1 处判定 |
| 4 | Rust 控制事件映射为 adapter 控制 | OPTION_REFRESH/QoS 读点复用（§3.3） | 零新增（复用现有检查点） |
| 5 | 压缩 AU 包装成现有 `VideoFrame` 走现有 send 路径 | `sp.send_video_frame`（§3.1 出口） | 零修改（调用现有函数） |

另加一项启动顺序 patch：config-root 早期设置（§3.5）。所有 Rust 侧改动收敛在 3 个文件（video_service.rs、codec.rs、config.rs 或独立早期入口），其余接缝零侵入复用。

## 4. H0.4 被控端 CPU 基线采集模板（待手动执行）

### 4.1 基线机器（已确认，2026-08-05）

主基线：**M4 Pro Mac mini（Mac16,11，Apple M4 Pro，macOS 15.7.7）**——用户现有唯一可测机器，与"Apple Silicon 优先"原则一致；Intel 仍按设计文档 §24 冻结决策 7 作独立功能门禁，性能数据单独记录。注意被控机实际运行系统为 macOS 15.7.7（设计文档最低支持版本 macOS 13 不受影响，但官方客户端基线数据需标注该系统版本）。机器元数据由采集脚本自动记录到 JSON。

### 4.2 采集脚本

`Scripts/baseline-official-host.sh`（已就绪）：每秒采样官方 RustDesk 进程、WindowServer、videotoolboxd 的 CPU/RSS，同时记录热压力（`pmset -g therm`）与电源来源，输出 CSV + JSON metadata + log，口径与设计文档 §2/§15.1 一致。

```sh
# 被控机上先安装并启动官方 RustDesk（允许屏幕录制/辅助功能），
# 由另一台机器建立连接后，在被控机执行：
Scripts/baseline-official-host.sh static 600 Evidence/HostBaseline/<date>/<machine>-static
Scripts/baseline-official-host.sh normal 600 Evidence/HostBaseline/<date>/<machine>-normal
Scripts/baseline-official-host.sh scroll 600 Evidence/HostBaseline/<date>/<machine>-scroll
Scripts/baseline-official-host.sh video  600 Evidence/HostBaseline/<date>/<machine>-video
```

四场景定义（设计文档 §2）：

| 场景 | 输入画布 |
|---|---|
| static | 静态桌面，10 分钟无操作 |
| normal | 普通窗口操作、文本输入 |
| scroll | 持续滚动网页/文档 |
| video | 播放视频（高动态） |

### 4.3 Instruments 模板（归因定位）

脚本给出进程级数字后，用 Instruments 定位 40–50% CPU 的归属（capture/conversion/encode/network/polling/系统进程）：

1. **Time Profiler**：target 选 RustDesk 进程，记录 normal 场景 2–3 分钟；看 Rust 线程热点（scrap quartz 采集、YUV 转换、编码、tokio poll）；
2. **System Trace**：观察采集回调/编码回调节奏与线程调度；
3. 同时记录 WindowServer 与 videotoolboxd 进程占比（Activity Monitor 口径），**不得只报 RustDesk 进程**（设计文档 §15.3）；
4. 每场景记录：采集尺寸/缩放、实际 codec 与编码器（H.264/HEVC/VP9、硬编/软编）、码率与 FPS。

证据归档至 `Evidence/HostBaseline/<date>/`，与现有 `Evidence/IntelMBP/` 结构一致（JSON + CSV + log）。

### 4.4 采集结果（2026-08-05，M4 Pro Mac mini 实测）

环境：被控机 macOS 15.7.7、3840x2160 显示器、官方 RustDesk 1.4.9；控制端为已连接的远端客户端（仅支持 H265 解码）。画布：static=无操作；normal=TextEdit 文本增长+窗口变化自动化（`Scripts/baseline-canvas-normal.sh`）；scroll=Safari CSS 自动滚动页（`Evidence/HostBaseline/2026-08-05/scroll-canvas.html`）；video=ffplay 循环播放 `Fixtures/hevc-4096x2304-30.hevc`（缩放 2560x1440 窗口）。每场景 600s、每秒采样。

| 场景 | RustDesk 进程 avg/max | WindowServer avg/max | VTEncoderXPCService avg |
|---|---|---|---|
| static | **36.5% / 45.2%** | 42.0% / 110.4% | 1.1% |
| normal | 34.6% / 41.7% | 35.0% / 83.8% | 1.2% |
| scroll | 21.3% / 45.0% | 34.2% / 160.8% | 0.8% |
| video | 36.1% / 40.5% | 29.0% / 43.7% | 1.2% |

归因（`sample` 30s 深采样 + 官方日志，见 `m4pro-mini-rustdesk.sample.txt`）：

1. **编码不是 CPU 大头**：日志确认协商为 H265 + `hevc_videotoolbox`（HwRamEncoder，VideoToolbox 硬编，3840x2160），VTEncoderXPCService 全程仅 ~1%——官方客户端在 M4 Pro 上已经用上硬编；
2. **消耗集中在采集/帧缓冲路径**：最热工作线程的 user-space 栈为 `bzero`（~2874 样本）+ `memmove`（~3724）+ `memcmp`（~789）的连续内存操作（scrap quartz 捕获帧的缓冲清零/拷贝/比较），另有 IOSurface/CoreVideo attachment 处理与 SkyLight display 查询；官方 dylib 已 strip，函数级归属以 H1 阶段用本地源码构建后复测为准；
3. **WindowServer 29–42% avg**：远程会话本身推高合成开销，属系统侧成本（设计文档 §15.3 要求一并上报，不以转移冒充优化）。

已知限制（如实记录）：

- normal 场景自动化画布在采样开始约 2 分钟后才生效，前 2 分钟接近静态负载；
- scroll 场景数值低于 static，原因是 CSS transform 动画主要由 GPU 合成（WindowServer max 160.8% 佐证），采集侧脏区较小；该场景反映的是"GPU 合成型滚动"，不代表所有滚动形态；
- 基线机为 macOS 15.7.7，与 V1 最低支持版本 macOS 13 不同，后续 FarPane Host 数据须在同机同系统对比。

### 4.5 结论（对应退出条件"知道 CPU 消耗归属"）

官方被控端在 M4 Pro + 4K + **已启用 VT 硬编** 的条件下，静态桌面即消耗 ~36% CPU；消耗归属为 **capture 帧缓冲拷贝/转换（主）+ 系统合成（WindowServer）**，而非编码、网络或轮询。这直接支持设计文档的重写前提：SCK→IOSurface→VT 的零拷贝链路消除全帧 CPU 拷贝是降 CPU 的主攻方向（§11.1），H1/H2 的性能门禁以本组数据为对照基线。

## 5. H0 退出条件核对

| 退出条件 | 状态 | 依据 |
|---|---|---|
| 知道 CPU 消耗归属 | ✅ 完成 | §4.4/§4.5：capture 帧缓冲拷贝/转换为主，编码已是 VT 硬编非瓶颈 |
| Host patch/config 边界可 review | ✅ 完成 | §3（五接缝 + inventory 汇总）、§2（全局状态） |
| AGPL 清单对内部 Spike 无阻塞 | ✅ 完成 | §1（动作项 2/3 为落地时同步更新项） |

**H0 阶段关闭（2026-08-05）**，进入 §26.2 阶段 1（H1a：Host Control ABI 与同进程 HostCore）。
