# H6.3f2b2t1 Host file-transfer bootstrap schema v5 contract

## Outcome

Host Agent immutable bootstrap 已从 schema v4 升至 v5，并新增独立的 `HostAgentFileTransferPolicy`。默认投影仍为关闭；关闭时 `receiveRoot` 必须是 JSON `null`，开启时必须提供非根目录、规范化且不超过 4 KiB UTF-8 的绝对路径。schema v1–v4 解码后均迁移为 file transfer 关闭，不会因升级隐式开放文件接收。

本步只建立 bootstrap 文档和 canonical projection 的安全合同。publication coordinator、Home 目录选择、UserDefaults、后台 HostAgent 与 legacy 前台 Host 的实际策略接线仍未完成，因此产品文件传输仍关闭。

## Key evidence

- schema v5 对顶层 `fileTransfer` 与内部 `enabled`/`receiveRoot` 使用 exact-key 校验；future schema、数值伪装 Boolean、permission/root pair mismatch、相对路径、`..` 标准化漂移与 `/` 均 fail closed。
- canonical builder 默认发出 `false/null`，只有调用方显式提供 policy 才投影 `true/absolute-root`，并继续用严格 decoder 做发布前自校验。
- schema v1–v4 保留原 clipboard 迁移语义，同时把新增 file policy 固定迁移为 `.disabled`。
- 三份历史 clipboard product audit 已改为验证当前 schema v5 仍保留原有小文本、富文本与图片方向，不改变其既有产品结论。

## Verification

- RED：focused tests 首次编译失败，明确缺少 `HostAgentFileTransferPolicy`、`fileTransferPolicy` 与 builder 参数。
- `swift test --filter HostAgentBootstrapConfigurationTests`：8/8。
- `swift test --filter HostAgentBootstrapPreparationTests`：6/6。
- `swift test`：977/977，4 项按现有环境条件跳过。
- `python3 -m unittest discover -s Tests/ScriptTests`：170/170。
- `swift build -c release --arch arm64`：通过。
- `git diff --check`：通过。

未启动 GUI、未创建或读取真实 receive root、未安装 App/Agent，也未进行双机文件传输验收。

## Next step

`host-file-transfer-bootstrap-publication-policy-lifecycle`：让 explicit file policy 参与 product integration、publication equality/revision 与 Agent runtime projection；继续默认关闭，随后再单独实现 Home 的目录选择和 opt-in UI。
