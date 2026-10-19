# FarPane Linux GPU 媒体重构（linux-host）：持续连接证据

**最终状态：30 分钟隔离软件连续连接检查已通过。** 修正后的 `run-fyslr5yc` 出图 1,800.112 秒，91 次新画面、进程/FD 稳定与退出回收通过；命令会话 `38625` 已退出 0，测试容器已删除。`long-passed` 保存最终报告/图表/精确源码，`long-passed-raw.tar.gz` 保存全部原始采样，已逐文件核对一致。下文的“运行中”文字为历史阶段，不应重新启动或等待已终止句柄。

预热后最大 PSS 增量 GUI/Host/Viewer 为 0/2,180/616 KiB，最后约五分钟各自增量为零；FD 全程 17/44/15。前段并行 GUI 总线检查改变库/字体页的 PSS 分摊，造成两次暂时下降，具体 smaps 归因在 `long-passed/shared-page-dip.json`；这不是产品内存优化或排除其他负载的性能 A/B。GPU/真实桌面、24 小时、首页 60 MiB、完整产品预算与中文输入仍未完成。未构建、打包、部署、提交或推送。

2026-10-18，冻结 `.20261018.3`，没有产品修改、构建或部署。暂停中的 Warp 特判不在该包中。

- `short-failed`：首次已认证，但灰色挑战与界面颜色相似，测试拒绝误计；这是夹具失败。
- `short-passed`：修正为互不混淆的颜色后，实际 60.131 秒、4 次新画面、固定 GUI/Host/Viewer 身份及 FD、主动断开回收和 GUI 关闭后 Host 保留通过；启动命令退出 0。
- 3 项入口/设备/颜色碰撞单测已通过，代码为 `Linux/tests/test_native_sustained_guard.py`。
- 30 分钟运行 `Build/Linux/native-sustained/run-ycewdmkc` 已启动，尚未取得最终结果；不在本目录伪造完成证据。

每个短测保存 exact 测试快照、输入/镜像/manifest 哈希、二进制哈希、日志、原始 smaps、各轮结果和私有截图。所有身份/密码均为容器内合成测试配置，未挂载用户数据。没有 GPU、root 服务、真实桌面、Mac、输入法、音频/文件并发或全部内存预算验收。

方法与复现见 [持续连接检查](../../../Linux/docs/viewer-sustained.md)。本轮未重编 FFmpeg，现有包和已安装服务不变。

后续首个长测 `run-ycewdmkc` 在第五次挑战前被颜色预检查拒绝，真实退出 1；原数据保存在 `long-attempt-failed`。该轮无长稳结论。

取样限制到远端色块内部后，短测 `run-edx2ya0g` 覆盖完整 91 色、持续 60.112 秒，FD 为 17/44/15，退出回收通过；入口/颜色四项单测通过。摘要、精确测试快照及截图在 `full-palette-short`，全部原始 smaps/结果在 `full-palette-short-raw.tar.gz`，未删减失败。只改测试，产品字节不变。

新 30 分钟运行 `Build/Linux/native-sustained/run-fyslr5yc`（命令会话 `38625`）仍进行中；不将旧运行或短测的结果替代新长测。

结束后分析器和短测核对在 `analysis-checks`：绑定冻结 manifest、二进制与测试源码，并验证完整样本、时序、进程身份与回收；八项原始记录/损坏副本检查通过。只生成了 60 秒图表，不将它计为 30 分钟通过。CLK_TCK 在同一宿主内核实测为 100。
