# FarPane Linux GPU 媒体重构（linux-host）：冻结候选许可复核证据

2026-10-18。范围与复现见[冻结候选的许可来源复核](../../../Linux/docs/frozen-notice-verification.md)。

- `inputs.json`：完整命令、源码 manifest 的预期 SHA。
- `historical-mode.*` 与退出记录：旧模式对当前 `.5` 拒绝，原因是补充 baseline 已不同；旧校验没有放宽。
- `frozen-mode.*` 与退出记录：新增模式对 `.5` 与其编译源码快照通过，91,478 条目、两个 crate 各六个发布文件及已交付原文通过；未使用活动构建 receipt/Cargo 缓存。
- `source/` 与 `source-manifest.json`：本轮三份验证器/入口/测试源码，便于独立复查。
- `validation.json`：14 项测试全部通过的工具执行结果记录、使用命令及未部署范围。原始 unittest 输出在会话工具记录中，未另存为本目录 stdout；不将此记录伪装成原始日志。

候选、旧配套源码归档与安装版本不变；未新添许可证授权或关闭剩余 17 条记录。`SHA256SUMS` 覆盖本目录其他全部普通文件。
