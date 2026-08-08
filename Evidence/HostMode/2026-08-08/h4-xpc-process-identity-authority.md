# H4.3c1 process-lifetime XPC identity authority

## Outcome

CoreBridge 现在具有独立的 process-lifetime XPC identity authority：消费 single-writer lease 已绑定的 build ID 与 agentBootId，等待首次权威 Host snapshot 提供 hostInstanceId 后只绑定一次。identity 未完整、冲突或已失效时不能创建可用于 H4.3b handler 的 ready identity。

## Key evidence

- H4.3c2 后续审计纠正了本步的初始判断：`HostAgentBootstrapContext` 已生成 `agentBootID` 并把同一 UUID 写入 single-writer lease record；本步最初另生成 UUID 会形成错误的双 authority，现已删除该 generator。
- product factory 现在必须同时接收 lease-bound build ID 与 boot UUID：build 按既有 128-byte component token authority 校验，boot 只接受 lowercase canonical UUID；不再自行生成、读取 Bundle/env 或接受 per-connection override。
- 初态固定为 `waitingForHostInstance`，没有 ready identity。首次合法 Host token 生成 immutable `HostAgentXPCWireAgentIdentity` 并进入 ready；相同 token 重入幂等 unchanged，不重新生成 boot ID。
- 空白/非法 Host token 立即永久 invalidated；ready 后出现不同 Host token 视为 identity contradiction 并永久 invalidated。显式 termination invalidation 幂等，失效后任何后续输入都只能返回稳定 invalidated。
- NSLock 串行化 bind/invalidate/snapshot。64 个并发相同 Host bind 精确得到 1 个 bound、63 个 unchanged，最终 build/Host/boot identity 完全一致。
- product source 不生成 boot ID，不读取 Bundle、environment、UserDefaults、文件或 XPC peer，不持有 listener/connection/handler，也不接受 path/server/key 输入；build/Host/boot identifiers 不写日志。
- 本步没有接入尚禁用的 `HostAgentProcess.run`，没有从 snapshot state 自动绑定，也没有把 H4.3b interface 安装到 connection；H4.2k 继续拒绝全部连接。
- 未修改 Host Control/Media C ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：authority tests 先因 state/bind result/authority 不存在而按预期编译失败。
- 定向 authority：7 tests，0 failures；覆盖 lease-bound canonical/stable boot identity、invalid build/boot、invalid/conflicting Host terminal failure、explicit invalidation、64-way concurrent same-ID binding 和无外部 fallback source guard。
- 完整 `swift test`：357 tests，4 skipped，0 failures（含 H4.3c2 新增的 4 个 composition/source-order tests）。
- ScriptTests：22 tests，0 failures。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

H4.3c2 已把 authority 接到 `HostAgentProcess` 的 startup composition。下一步 H4.3c3 必须处理后续 snapshot identity contradiction，并让 H4.2k 仅为 identity-eligible peer 安装握手 interface、设置 interruption/invalidation 清理并 resume connection；仍不得在握手成功前开放 snapshot/event/Host command。
