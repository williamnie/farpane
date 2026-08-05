# Host Mode 设计文档评审报告

> 评审对象：`docs/host-mode-design.md`（Draft v0.1，2026-08-03，25 节）
> 评审方式：只读审查（reviewer 子代理，未修改任何文件）
> 评审日期：2026-08-04
> 核验备注：主代理已沿 reviewer 引用的关键事实抽查仓库现状（Package.swift、UI 框架、AGPL 决策、notarization 状态），抽查结果与报告一致。

---

## 1. 总体结论

**有条件可行。** 核心决策（控制面留在 Rust、重写 macOS 媒体面、不嵌入上游 GUI、pinned 上游版本 + adapter 隔离）与本项目 viewer 侧已验证成功的路径一致，架构成立；但 **"媒体面如何接回 RustDesk server 会话"、"ABI 与进程间 IPC 的分裂"、"macOS 13 下 dirtyRects 不可用"** 三处关键缺口必须在进入 H1 前补齐，另有两项决策（helper 形态、notarization）需前置。

## 2. 设计亮点

1. **§1 核心决策正确且有先例支撑**：控制面复用 + 媒体面重写 + 自有 ABI 隔离上游，正是本仓库 CoreBridge 已走通的模式（现有 ABI v5 通过 `rdn_bridge.rs` 复用 `Session::send_mouse`/`input_key` 等内部路径），可行性不是纸上谈兵。
2. **§2 + §15.3 的性能诚实性**："不预设重写必然更快"、要求同时报告 WindowServer/videotoolboxd/总能耗、禁止用系统进程转移冒充优化——比同类设计严谨，直接防住最常见的自欺。
3. **§11.1/§11.6 数据面约束技术上正确**：copy count 门禁、"只丢未编码帧、reset 必须显式 flush+IDR、drops 按原因分类"，精准命中远程桌面编码器两个最常犯错点。
4. **§7.2/§13 的"ready 必须来自权威组件链"**：拒绝 boolean 服务状态、拒绝以进程存在冒充 ready，是对 launchd/TCC 现实的正确理解。
5. **§8.1/§16.1 敏感值处理完整**：password buffer 清零、快照禁含 secret、日志脱敏、§10.3 认证失败限流防通知轰炸，安全细节到位。

## 3. 主要问题

### 严重

1. **§4.1/§19.1：媒体面与 RustDesk server 会话的接缝完全未设计。** 文档说复用协议/传输、替换采集/编码，但外部 VT 编码产物如何注入上游 `src/server` 的 Connection/VideoService、远端 keyframe 请求如何回传编码器、codec 能力协商在哪一层完成，均无描述。viewer 侧补丁已证明 patch 路线可行，但 host 侧 patch 面显著更大，这是 H1 最大技术未知数。应单列补丁范围清单并作为 H1 前置条目，而非笼统的"最小 patch 集"。
2. **§8 与 §6.2 自相矛盾：ABI/IPC 混为一层。** §8 定义的全部是进程内 C FFI（opaque handle + 回调），而 §6.2 中 App↔HostAgent 是跨进程通信。XPC wire 协议、重连语义、回调流如何映射、Mach service 命名均未定义。H4 迁移时要么推翻 §8 要么在其上打洞。§8 应明确"本章仅定义进程内 ABI，进程间传输另行设计"或直接一并设计。
3. **§11.3 依赖 macOS 14+ API，与项目最低版本冲突。** `SCStreamFrameInfo.dirtyRects`、`SCStreamConfiguration.queueDepth`、色彩空间控制均为 macOS 14.0+；而 `Package.swift` 声明 `platforms: .macOS(.v13)`（已核实）。自适应 FPS 是 H2 主线和 §15.3"无全屏 CPU diff"门禁的基础，§5 只写了"单独设计 fallback"一句。必须明确：Host 最低版本提到 14，还是给出 13 上的降级检测方案。

### 中等

4. **§4.2 与项目现状脱节。** 仓库已按 AGPL 分发（README 许可证节、`THIRD_PARTY_NOTICES.md`、architecture.md §10.4 已决策"RustDesk 派生按 AGPL 管理"，已核实），文档却仍将"闭源 vs AGPL"列为未决 P0 门禁。若无闭源商业版计划，H0.1 应收缩为 AGPL 合规清单（corresponding source、修改说明、网络交互条款）。
5. **§4.3 与 §24.8 互相冲突。** §4.3 要求第一版就固定 Bundle ID/Team ID/designated requirement/安装路径，§24 却把"HostAgent 独立 helper 还是同 executable mode"留为待确认——TCC 归属恰恰取决于后者，该决策必须提前到 H1/H3 之前。
6. **UI 栈描述失真。** 全文以"SwiftUI App/SwiftUI 页面"立论，但实际项目是 AppKit（`Sources/RustDeskNative` 全部 `import AppKit`，README 明示，已核实；无 SwiftUI/NSHostingView 混用）。架构结论不受影响，但 §6.3"MainActor 堵塞/UI rebuild"等论据和后续 UI 验收口径应对齐 AppKit。
7. **§18 缺跨进程配置竞争。** App 进程内 viewer core 与 HostAgent 内 host core 是两个 RustDesk Core 实例，共享 hbb_common 配置目录（`RustDesk.toml`、id 密钥等）。§18 只讲单写者原子写，未处理双进程争用同一 Rust 配置命名空间的锁/归属设计。
8. **§6.2/§13.1 LaunchDaemon 必要性未论证。** 上游 RustDesk macOS 不用 privileged daemon（GUI 会话 LaunchAgent 即可），macOS 上真正需要 root 的操作极少。HostService 是全设计签名/XPC/版本握手成本最高部件，应给出"最小特权操作清单"；若仅为安装 plist，SMAppService + 一次授权可大幅降低 H4 复杂度。

### 轻微

9. **§2 的"40–50%"证据错位**：仓库现有实测全部是控制端 CPU（architecture.md §2.2），无被控端数据。H0.2 应注明该数为外推。
10. **§11.4**：`UsingHardwareAcceleratedVideoEncoder` 的可读时机（通常在编码开始后）应写明；建议把 `kVTCompressionPropertyKey_RealTime` 也列入门禁。
11. **§11.6** 缺"远端主动请求刷新/keyframe → 编码器 IDR"的对称映射（viewer ABI 已有 `rdn_client_request_keyframe`）。
12. **§7.1** 缺权限长期拒绝后 `AwaitingPermission → Failed` 的出路。

## 4. 技术疑点与未列风险

- **Notarization 缺失**：README 明示 release 包未 notarized（已核实）；带 quarantine 属性的未公证二进制被 launchd 拉起会有 Gatekeeper 问题，§4.3 只讲签名未讲 notarization。
- **能量决策缺失**：远程被控通常需在会话中持有 IOPMAssertion 阻止休眠，§13.4 只被动处理 sleep/wake；"会话中是否保持唤醒""电池/空闲能耗"未决策，§23 风险表无能量/散热条目（仅 §11.3 thermal 输入间接覆盖）。
- **协议版本漂移方向单一**：风险表只写了"上游无稳定 SDK"，未写 pinned 上游 host 面对持续更新的官方控制端的互操作漂移。
- **SCK 像素格式**：部分 macOS 版本 SCK 稳定输出仅 BGRA，NV12 直出不可靠；§11.1 已有 hedging，但建议把"0/1 次转换实测"写进 H1 退出条件原文。
- **Host+Viewer 并发**：用户一边外连一边被控的双 Core 并发场景，§20.2 只测 ABI 并存，不够。
- **macOS 应用防火墙**首次监听（21118 等）的入站询问未提及。
- **Intel 编码能力**：HEVC 硬编需 Kaby Lake+，验收机（i7-9750H）满足，但 §11.5/§15.2 应显式覆盖 Intel 硬编能力探测，避免 HEVC 协商在旧 Intel 上静默软编。
- **§13.3 LoginWindow**：Aqua 会话 LaunchAgent 对锁屏/登录窗口的采集与输入注入实际受限很大，建议 H5 直接以"锁屏后不支持控制"为 V1 明确边界，而非追求完整支持。

## 5. 建议补充（按优先级）

- **P0**：① 新增"媒体面接回 RustDesk server 会话"补丁设计（注入点、keyframe 回传、codec 协商归属），列为 H1 前置；② §8 补充进程间 IPC 定义或明确 scope；③ 决策 §24.8 helper 形态并在 §4.3 补 notarization。
- **P1**：④ macOS 13 fallback / 最低版本决策（§11.3、§5）；⑤ 双进程 Rust 配置/identity 争用设计（§18）；⑥ 能量/防休眠产品决策（§13.4、§23）；⑦ §23 风险表补"官方客户端版本漂移"与"能量/散热"两行。
- **P2**：⑧ 防火墙首启提示；⑨ host+viewer 并发场景矩阵；⑩ 远端 keyframe 请求对称 ABI；⑪ Intel HEVC 硬编能力探测用例。

## 6. 评审依据

实际读取：`docs/host-mode-design.md`（全文 25 节）、`docs/architecture.md`（全文，含 §2.2 性能证据与 §10.4 许可证决策）、`docs/research.md`（前 150 行）、`README.md`（全文）、`Package.swift`、`CoreBridge/include/rustdesk_native.h`（全文，ABI v5）、`CoreBridge/README.md`（ABI 演进史）、`CoreBridge/RustDeskPatch` 目录结构、`Sources/` 与 `App/` 结构及 UI 框架 grep 验证。未覆盖：`Evidence/` 原始采样、`docs/product-ui-design.md`、上游 RustDesk `src/server` 源码（问题 1 的补丁面估计基于既有 bridge 模式推断，属风险推断而非确认结论）。

---

## 附：主代理核验备注

- 抽查了 reviewer 引用的四处关键事实：`Package.swift` 的 `.macOS(.v13)`（问题 3 ✓）、`Sources/RustDeskNative` 全部 AppKit 无 SwiftUI（问题 6 ✓）、architecture.md §10.4 的 AGPL 决策（问题 4 ✓）、README 的 notarization 未接入（疑点 1 ✓）。抽查均与报告一致。
- 问题 8（LaunchDaemon 必要性）评审建议主代理裁决：倾向接受 reviewer 建议——H4 阶段先按 SMAppService/LaunchAgent 最小方案推进，仅当出现真实 root 需求时再引入 HostService，并在设计文档中补充"最小特权操作清单"论证。
