# H4.3d1 strict snapshot-first wire Data contract

## Outcome

冻结独立、严格、有界的 `snapshotRequest`/`snapshotResponse` Data 契约。握手成功后的未来 XPC handler 可据此返回与 request、Host instance、agent boot identity 关联的全量脱敏快照和 Agent-local event cursor；本步不增加 Objective-C selector、不启动 XPC 调用，也不改变顶层 Host Agent 的 fail-closed 状态。

## Key evidence

- schema 1 envelope 精确要求 `wireVersion`、`messageType`、canonical `requestId`、`hostInstanceId`、canonical `agentBootId`、`sentAtUnixMilliseconds`、`payloadLength` 和类型化 `payload`；request payload 固定为空对象，response payload 固定为 `{lastEventId, snapshot}`。
- `payloadLength` 是 sorted-key canonical JSON payload 的实际 byte count；解码会重新编码并对账声明长度。全部 document 同时受 32 KiB 上限保护，未知/缺失键、Boolean 冒充整数、fraction、非 canonical ID、unsupported schema/wire、错误 message type 和不一致长度都 fail closed。
- response factory 只接受 `.available` 且 projection/authority/request/agent identity 的 Host instance 与 boot identity 全部一致的 state；waiting、copy failure 后清空的 projection、Host mismatch 或 boot mismatch 不会产生可发送快照。
- `lastEventId` 明确定义为 `agentBootId` 生命周期内按 Agent callback 到达顺序分配的 local event sequence，不冒充 Rust event envelope 的 `eventId`。App-side `evaluate(for:)` 同时对账 request ID、wire version、Host instance 和 boot ID。
- typed snapshot 仅从 `HostAgentSnapshotProjection` 显式映射 schema 5 Host state、local ID、registration、pending approval、active session/input availability、permanent-password policy、last error 与 observed time；每层字典都有 exact keys、枚举/长度/关系约束。
- projection 的 temporary-password policy 只能编码为 `redacted`；测试以真实含 one-shot revealed password 的 `HostCoreSnapshot` 发布后断言 wire 不含 password、`rawJSON`、`revealedTemporaryPassword` 或原始 presentation。
- source guard 证明该 Data contract 不引用 `NSXPCInterface`、listener/connection activation、exported object、command 或 event wire types；没有修改 Host Control/Media ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库，未安装、部署或 push。

## Verification

- TDD RED：focused test 首次因 snapshot wire request/response/error/contract 类型均不存在而编译失败。
- `swift test --filter HostAgentXPCWireSnapshotTests`：7 tests，0 failures。
- 完整 `swift test`：377 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3d2 在现有 handshake-only connection lifecycle 中增加唯一 snapshot Data selector/handler 状态：仅 compatible handshake 后接受请求，严格对账该 connection 已绑定的 Host/boot/wire identity，返回本契约数据；snapshot 成功前仍不开放事件订阅或 Host command。App client、event wire、command/dedupe 和顶层 Host Agent enablement 继续留在后续小步。
