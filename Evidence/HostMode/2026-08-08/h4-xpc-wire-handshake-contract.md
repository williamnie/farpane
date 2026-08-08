# H4.3a strict XPC wire handshake contract

## Outcome

CoreBridge 现在具有独立于 listener/runtime 的严格 handshake Data contract，用于 App 与 HostAgent 在任何 Host 消息前交换 wire version、组件 build ID、request identity、Host instance identity、Agent boot identity 和发送时间。当前唯一产品 wire version 固定为 1；没有共同版本时返回相关联的 incompatible response，不能进入后续消息阶段。

## Key evidence

- request/response 分别固定 `handshakeRequest` / `handshakeResponse` 和 schema v1，使用 exact top-level key allowlist；未知、缺失、类型错误、布尔冒充整数、分数、零时间戳或 future schema 均 fail closed。
- 每份文档最多 8 KiB；支持版本列表为 1...8 个严格递增、无重复、`UInt32` 范围内的正整数。产品 offer 与 Agent response 只能引用单一 authority `[1]`，不能由路径、环境或 peer 输入扩展本地支持范围。
- request ID 与 agent boot ID 必须为小写 canonical UUID；Host instance ID 与 component build ID 限制为 1...128 UTF-8 bytes 的 token。首次连接的既有 Host/boot identity 明确用 JSON null 表达，不能省略字段。
- response 总是回显 request ID，并携带 Agent 实际支持版本、build ID、Host instance ID 和 agent boot ID；compatible 必须选择双方最高共同版本，incompatible 必须把 selected version 设为 null。
- App-side evaluation 再次核对 request ID、双方版本交集和 selected version；错误关联、伪 incompatible、未 offer 或非最高共同版本均返回稳定 `invalidResponse`。
- `sentAtUnixMilliseconds` 当前只做非零和 JSON 精确整数上限校验；尚未冒充 clock freshness、rate limit 或 replay protection。
- contract 只编码/解码有界 `Data`，不引用 `NSXPCInterface`、listener、connection 或 exported object，不激活 IPC，也没有 Host command、snapshot 或 event surface。
- 本步没有修改 Host Control/Media C ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：focused tests 先因 handshake request/response/negotiator 不存在而按预期编译失败。
- 定向 handshake：8 tests，0 failures；覆盖产品版本 authority、compatible/incompatible round trip、strict limits/type/shape、稳定失败分类、响应关联和源码无 XPC/runtime surface。
- 完整 `swift test`：340 tests，4 skipped，0 failures。
- ScriptTests：22 tests，0 failures。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3b 才定义最小 Objective-C-compatible XPC interface 和 handshake handler，把入站 `Data` 限定到本合同；在 handler 能提供真实 build/host/boot identity、完成 identity admission 且设置 interruption/invalidation lifecycle 前，H4.2k 必须继续拒绝全部连接。snapshot-first 状态机、HostSnapshot envelope、事件订阅、三段式命令、dedupe/rate/replay policy 都保持后续独立边界。
