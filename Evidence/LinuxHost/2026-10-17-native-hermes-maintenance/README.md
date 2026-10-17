# FarPane Linux GPU 媒体重构（linux-host）：原生 GUI 实机维护证据

2026-10-17，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。经用户明确授权进入维护窗口，完成原生 GUI 切换；用户随后确认 Mac mini 入站“画面和键鼠正常”。实机范围、资源数据、安装器修复与未验收项见[维护说明](../../../Linux/docs/native-hermes-maintenance.md)。

`runtime/` 包含真实 stage/plan 后的计划、activate、初次 bind 拒绝及修复后结果、公开配置状态、身份字段相等性检查、30 秒连接样本、10 秒 GUI 关闭样本、重开状态、用户验收与 RustDesk 手动停用说明。没有存放配置 TOML、密码/密钥值、配置备份或任意进程命令行。

GPU 开关和实际后端均开启；renderD128 编码计数持续增长。三进程 PSS 约 235 MiB，GUI 约 131 MiB，60 MiB 目标未达。GUI 进程退出/重开期间同一 Host 与授权连接保留，仅后台约 104 MiB。这是未控制内容的短时诊断，不是配对性能、动态视频、24 小时长稳或 Linux Viewer 验收。

最终权限单测 10 项通过（无 skip），隔离安装事务 25 项、真实包暂存/入口/媒体库探针/GIO 检查通过。`runtime/installer/20261017T130905Z` 保留首轮 24 项成功事务输出；之后真实包断言因 fixture 路径错误失败，具体错误及工具 session 记录在 `known-initial-failures.json`。`20261017T131014Z` 与 `20261017T131341Z` 为修正后的完整通过记录，后一轮含最终 ACL 边界。原始工作目录 `Build/Linux/native-maintenance/20261017T125413Z` 的私有配置备份未复制。

`.10`、`.11` 只更新独立安装器，完整应用 payload 仍为 `.9`，未重编 GUI/core/FFmpeg。最终 `.11` SHA-256 为 `5305789932d492224d21d726fcfa64308b77cd8c6b8816c43074f86981f517a8`。解包 payload 与 bundle、控制脚本与 canonical 哈希全部一致。未重跑完整 dpkg/视频矩阵，也未在宿主执行 dpkg；已安装的 `/opt` 应用使用工作区最终安装器完成用户入口绑定。

`canonical/` 为本轮源码、测试、文档副本；最终安装器完整源码也在 `.11` 的 `control/` 中。旧 `.9` 应用源码归档不包含本轮新测试、采样与安装器修改。`final-check.json` 汇总核对，`SHA256SUMS` 索引其余证据文件。完整发布许可审计及性能目标仍未关闭，没有 commit/push/公开发布。
