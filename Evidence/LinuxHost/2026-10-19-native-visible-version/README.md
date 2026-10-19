# FarPane Linux GPU 媒体重构（linux-host）：可见版本与实际安装

2026-10-19 北京时间。界面显示 `v0.1.0-dev.20261019.1` / `主机核心 c403acbf`，已安装到 linux-host。说明、完整哈希与限制见 [visible-version.md](../../../Linux/docs/visible-version.md)。

- `gui-build-receipt.json`、`gui-test.log`：增量 GUI 编译来源与 9 通过 / 1 忽略。
- `layout-inputs.json`、`layout-exit.json`、`layout-result.json`：四组隔离窗口/缩放检查。两份首页 PNG 是私有测试环境，不是用户桌面；截图 ID 不可用于连接 linux-host。
- `manifest.json`、`release-info.json`：封存 payload 与 GUI 显示的版本/核心映射。
- `stage.json`、`plan.json`、`activate.json`、`bind-user.json`：真实安装事务。用户先前明确授权安装测试，本轮又要求界面版本可见。
- `runtime-verification.json`：旧进程退出、新进程实际 executable 哈希、配置字段相等与服务状态。只导出相等判断，不导出密码、密钥或配置正文。
- `host-public.json`、`cli-version.txt`：安装后只读身份/就绪与可执行版本输出。
- `canonical-sha256.json`：本次源码与测试文件指纹；其余既有未提交工作保留。

维护原始工作目录为 `Build/Linux/native-maintenance/20261019-version-8f_fkjxe`；私有配置备份没有复制到本目录。GUI 构建 `gui-updates/run-1ps3tezz`、布局 `native-home-layout/run-jbkckisr` 均完成，无遗留测试容器或采集任务。

本次保留 `.8` 中文核心；用户反馈 `.8` 仍无中文，故没有关闭该缺陷。未说明用户为何未观察到之前的断线，也未把本轮版本标签测试当成真实远程输入验收。继承的 notice/source publication 门槛继续开放；未 commit/push。
