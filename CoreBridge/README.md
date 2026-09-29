# Core Bridge

Swift 与固定版本 RustDesk Core 之间的语义边界。公共 C 接口位于
[`include/rustdesk_native.h`](include/rustdesk_native.h)，当前版本为 Viewer ABI 18、
Host ABI 19、Host Media ABI 1。Swift 不导入 RustDesk protobuf，不传原始视频帧。

## 加载与来源

`Shim/rdn_shim.c` 通过 `dlopen` 加载 Core。
`Shim/rdn_symbols.h` 是唯一动态符号清单，字段类型直接取自公共头文件。
Viewer 符号必须完整且 ABI 相符；Host 是可选能力，只有整套 Host 符号都存在才可用。
Swift client 还会核实固定 upstream commit。

Canonical Rust 源码位于 `RustDeskPatch/`：

| 入口 | 职责文件 |
| --- | --- |
| `rdn_bridge.rs` | `rdn_bridge/`：Viewer 会话、callback、输入、剪贴板、显示器、文件传输和测试 |
| `rdn_host_bridge.rs` | `rdn_host_bridge/`：Host 生命周期、存储、审批、会话、媒体、文件操作和测试 |
| `rdn_host_file_transfer.rs` | descriptor-relative 私有文件根与安全文件操作 |

入口中的 `include!` 保持同一 ABI 编译单元与现有私有作用域。新增职责文件后无需手动
添加复制清单：`Scripts/sync-rustdesk-bridge.py` 会复制、`--check` 会校验全部 `.rs` 文件。
`Scripts/bootstrap-rustdesk-core.sh` 负责固定上游与分层补丁，
`Scripts/verify-rustdesk-core-source.sh` 负责只读核验。
`Vendor/` 和 `Build/` 中的 checkout、依赖及二进制不是 canonical 源码。

## 数据及权限

- Viewer 视频只传 H264/H265 编码包、帧元数据及指标。输入只传坐标、按键、修饰键和已提交文本。
- Host control 使用有界 JSON 命令、事件与快照；临时密码只在明确 reveal 后的一次快照中出现。
  永久密码通过专用可擦除 buffer 传递，成功还要求持久化读回验证。
- 剪贴板小文本上限 64 KiB；RTF/HTML 各 1 MiB；RGBA/PNG 上限 128 MiB、SVG 上限 4 MiB。
  格式、尺寸、UTF-8、NUL、压缩输出、独立方向及会话权限均需校验。
- 文件传输使用独立会话、正 request/transfer ID、epoch、规范化 manifest 与 opaque lease/token。
  每块最多 128 KiB；Swift 持有本地 descriptor，Rust 持有协议与网络状态。
  staging 必须私有、no-follow、单链接；提交使用 durable no-replace，不能覆盖既有目标。
- Host 媒体控制及编码包绑定 host instance、connection/codec epoch、display ID/revision。
  队列饱和、过期路由、格式错误与关停有不同的结果，不能混为普通重试。
- 断开、撤权和 teardown 会使旧回调失效。后台 XPC 的身份、generation、命令 ID 及重试检查
  留在 `Sources/CoreBridge/` 的 typed state owners 中。

## 找到 Swift 实现

Viewer client 在 `Sources/CoreBridge/CoreBridge.swift`；Host client 在 `HostControlClient.swift`。
数据类型、callback、snapshot、session gates 和 media events 都有对应职责文件。
`XPCDocument.swift` 共用 JSON 基础规则，`HostAgentXPCWire*.swift` 保留各类消息的严格合同。
完整调用关系见 [`docs/architecture.md`](../docs/architecture.md)。

## 验证

`swift test` 检查 Swift 边界和生命周期；`Tests/ScriptTests/test_bridge_loader.py` 编译真实测试
动态库，逐个移除公共符号验证加载策略；Rust tests 验证 ABI 实现、权限、存储和媒体队列。
真实远程连接、安装后的 TCC 与双机性能需另外验收，不能从源码标记推断完成。
