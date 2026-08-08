# H4.3c1 process-lifetime XPC identity authority

## Outcome

CoreBridge 现在具有独立的 process-lifetime XPC identity authority：在 Agent process composition 时从已验证 bootstrap build ID 生成一次 canonical agentBootId，等待首次权威 Host snapshot 提供 hostInstanceId 后只绑定一次。identity 未完整、冲突或已失效时不能创建可用于 H4.3b handler 的 ready identity。

## Key evidence

- runtime 审计确认 `agentBuildID` 来自 H4.1 secure bootstrap context，而 `hostInstanceID` 只有 HostCore 启动并完成 initial snapshot refresh 后才存在；此前没有任何 `agentBootID` owner。直接在 listener factory 中构造三者会迫使占位、Bundle/env fallback 或每连接重生 identity，因此本步先建立唯一生命周期 authority。
- product factory 要求调用方提供已验证 build ID，先按既有 128-byte component token authority 校验，再只调用一次 `UUID().uuidString.lowercased()` 生成 process boot ID；无效 build 不调用 generator，无效 UUID 构造失败。
- 初态固定为 `waitingForHostInstance`，没有 ready identity。首次合法 Host token 生成 immutable `HostAgentXPCWireAgentIdentity` 并进入 ready；相同 token 重入幂等 unchanged，不重新生成 boot ID。
- 空白/非法 Host token 立即永久 invalidated；ready 后出现不同 Host token 视为 identity contradiction 并永久 invalidated。显式 termination invalidation 幂等，失效后任何后续输入都只能返回稳定 invalidated。
- NSLock 串行化 bind/invalidate/snapshot。64 个并发相同 Host bind 精确得到 1 个 bound、63 个 unchanged，最终 build/Host/boot identity 完全一致。
- product source 不读取 Bundle、environment、UserDefaults、文件或 XPC peer，不持有 listener/connection/handler，也不接受 path/server/key 输入；build/Host/boot identifiers 不写日志。
- 本步没有接入尚禁用的 `HostAgentProcess.run`，没有从 snapshot state 自动绑定，也没有把 H4.3b interface 安装到 connection；H4.2k 继续拒绝全部连接。
- 未修改 Host Control/Media C ABI、Rust、Hermes、SMAppService、plist、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：authority tests 先因 state/bind result/authority 不存在而按预期编译失败。
- 定向 authority：7 tests，0 failures；覆盖 product canonical/stable boot identity、validation order、invalid/conflicting Host terminal failure、explicit invalidation、64-way concurrent same-ID binding 和无外部 fallback source guard。
- 完整 `swift test`：353 tests，4 skipped，0 failures。
- ScriptTests：22 tests，0 failures。
- `swift build -c release --arch arm64`：成功。
- `git diff --check`：通过。

## Remaining boundary

下一步 H4.3c2 在 `HostAgentProcess` 的真实 startup composition 中创建一次 authority：build ID 必须直接来自持有 single-writer lease 的 bootstrap context，initial snapshot refresh 成功后以 snapshot authority 的 exact Host instance bind，termination preparation 最先 invalidate。只有该组合返回 ready identity 后，后续 H4.3c3 才可让 H4.2k 为 identity-eligible peer 安装仅握手 interface、设置 interruption/invalidation 清理并 resume connection。
