# FarPane Linux GPU 媒体重构（linux-host）：存活分配调用栈

2026-10-17，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。上一轮已完成 `.8` 双屏修复；本轮增加首页存活分配归因，未改产品或重建二进制。

结果与复现见 [allocation-attribution.md](../../../Linux/docs/allocation-attribution.md)。最终单次 20 秒报告：22,540,535 requested bytes，88,467 个存活块；4,096 组调用栈覆盖 94.42%，34 份 ELF Build ID/哈希匹配。Mesa Gallium 调用处占已列出的 14,219,774 字节；这不是总 PSS 或精确对象所有权。

目录保留 `runtime/` 原始完整/截断报告、smaps 与符号分析，`logs/` 编译/运行/解析失败，`canonical/` 测试与文档快照。`payloads-in-build.json` 记录未复制的诊断 ELF 文件，`product-unchanged.json` 和 `host-state.json` 核对 `.8` 三份交付物、GUI/core、四个 FFmpeg 静态库与现有服务。`SHA256SUMS` 覆盖所有留证文件，`final-check.json` 为本轮范围汇总。

全部工具仅在隔离环境运行。限定 renderD128、静态私有 Weston 窗口、普通用户、无宿主桌面/键鼠/服务/凭据挂载。两次成功探针 170/171 次 FarPane 视频空闲检查均为零；失败轮持续监控但无成功计数汇总。没有打开用户桌面、替换服务、commit/push/deploy、改 Mac/xuanwu 或创建代理/定时任务。

明确限制：ASan 替换私有 GUI 分配器并增加额外内存/CPU；预算判定为 null，不能将其约 200 MiB 量级的诊断 PSS 当成产品回退。应用没有 sanitizer 指令插桩，不能宣称完整内存安全审计。`addr2line` 的无源码位置函数名只作 hint，不当精确函数归属。5.58% requested bytes 未列出，文件映射/GPU/分配器管理成本另计。

60 MiB 首页目标、真实桌面及全部进程配对 A/B、维护窗口、Mac 互操作、真实多屏/GPU/硬件 AV/长稳、公开 CI 与完整发布许可审计仍未验收。新证据不降低原目标，也没有生成 `.9` 或重复打包旧源码归档。
