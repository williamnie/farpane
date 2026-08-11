# H6.3f2b2t2 Host file-transfer bootstrap publication policy lifecycle

## Outcome

schema v5 的 `HostAgentFileTransferPolicy` 现在贯通 canonical builder、publication coordinator、product integration 与后台 HostAgent runtime。策略变更参与同 revision document equality；开启、关闭或 receive root 变化都会推进 `configRevision`，完全相同的策略保持 idempotent。HostAgent 从已验证的 immutable bootstrap 精确投影 `fileTransferEnabled`/`fileTransferReceiveRoot` 到 Host ABI v17。

当前 App 仍只向 product integration 传 clipboard policy，因此新增 file policy 使用默认 `.disabled`，不会提前启用产品文件传输。Home picker、偏好持久化及 legacy 前台 Host 接线仍是下一边界。

## Key evidence

- coordinator 的 existing-revision comparison 与 new-revision projection 都携带同一 file policy；root 变化会推进 revision，exact retry 不变。
- product integration 只从调用方接受显式策略并原样传给 coordinator；其默认值继续关闭。
- 后台 Agent 只从 bootstrap context 读取策略，并把 permission/root 精确成对交给 `HostServerConfiguration`；不读取环境变量或其他旁路。
- 31 份历史 H6.3 审计的“产品保持关闭”判据已从“Agent 不含 ABI 参数”校正为“App 尚未传显式 file policy”，从而与当前分层状态一致。

## Verification

- RED：coordinator/product integration focused tests 首次编译失败，明确缺少 file policy 参数；runtime source contract 也先要求精确投影。
- `swift test --filter HostAgentBootstrapPublicationCoordinatorTests`：8/8。
- `swift test --filter HostAgentBootstrapProductIntegrationTests`：5/5。
- runtime projection contract：1/1。
- `swift test`：979/979，4 项按现有环境条件跳过。
- `python3 -m unittest discover -s Tests/ScriptTests`：171/171。
- `swift build -c release --arch arm64`：通过。
- 新 audit 状态：`bootstrap-publication-runtime-policy-implemented-home-opt-in-off`；`git diff --check`：通过。

未启动 GUI、未访问真实 receive root，也未安装 App/Agent。

## Next step

`host-file-transfer-host-home-receive-root-opt-in-lifecycle`：实现默认关闭的 Home 接收目录选择、私有目录 admission、偏好持久化，以及后台/legacy Host 同一策略投影。
