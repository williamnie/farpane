# FarPane Linux GUI 重构方案的 Claude 评审与采纳记录

用户明确要求通过 ocs 请可见 Claude 会话评估方案可行性。本次审阅者为 `claude-288b5f14`，2026-10-16 15:36:58（Asia/Shanghai）返回完整意见。审阅者报告全程只读；Linux owner 随后核对了关键源码并修订方案，没有运行构建、探针或服务操作。

- [原始评审](claude-review.txt)：ocs seq 2 的原文，不是最终实施决定。
- [被审阅的 v1](reviewed-plan.txt)：逐字保存原文，SHA256 为 `9c8be4aa9e2322041f8c640c68b40f08cabbb601e65da148d83c3ff5440cc74a`。
- [来源元数据](provenance.json)与 [校验和](SHA256SUMS)。
- [修订后的实施方案 v2](../../../Linux/docs/gui-rewrite-plan.md)。

结论：技术方向可行，但旧监管、角色识别与 Cargo 依赖需要先改造，新增 Linux Viewer 硬件帧导出路径需要原型验证。v2 将这些列为 U0 门槛；评审通过方向不代表代码、性能或完整产品验收通过。

## 采纳决定

| 意见 | 核对与决定 |
| --- | --- |
| B1 CM 消失导致监管重启 | 已核实 `should_start_server/get_cm` 的 60/3600 秒判断；以经身份验证的活动快照替代 CM 进程存在性，未知状态不能当空闲，增加虚拟时钟与真实长连接检查 |
| B2 改名/argv 影响角色识别 | 已核实 `IS_SERVER`、`running_server_uids_for_current_exe` 和 shell 停止正则；保留 `--server`，停止目标改为精确可执行身份/角色/UID/进程起始标识 |
| B3 Host 与 Viewer 生命周期冲突 | 选择独立 `--viewer` worker；不由 root Host 监管，不访问 DRM/服务 IPC；合并使用时四个角色全部计入内存 |
| B4 headless 依赖边界 | 已核实 GTK3、tao/tray-icon、Sciter、winit/softbuffer 依赖；增加 optional 依赖与 cfg 拆分、递归 ELF/实际加载检查；GUI 不链接 rustdesk crate |
| H1 CM 实际承载业务与 runtime | 已核实 CM listener、`#[tokio::main]` 和退出函数；保留 `_cm` 协议、提前就绪、取消拉起旧 CM，明确线程/runtime 和组件停止语义 |
| H2 托盘和自启动 | 已核实 `core_main --server` 自动拉起 tray；改纯 D-Bus SNI，关闭旧自动拉起并幂等迁移本产品管理的 autostart |
| H3 原生硬解输出尚不存在 | 已核实 `av_hwframe_transfer_data`；改为新增 VAAPI→DRM_PRIME 解码适配，出借 AVFrame 引用与 `extra_hw_frames` 一起预算 |
| H4 codec 与颜色 | 补 codec 实际能力宣告、软件兼容模式、缺失 VUI 的显式 SDR 默认、颜色和帧代际测试 |
| H5 EGL/fence 与故障 | 接受 EGL/X11 验证、native fence、原型比较与故障注入；不接受仅凭 HUP 即回收复用帧，详见下文 |
| M1 预算与统计 | 拆成 150 MiB 后台 + 60 MiB GUI = 210 MiB；U0 检查可达性；补进程枚举、USS/SwapPss/GPU/合成器成本，不用简单减法冒充关闭窗口实测 |
| M2 Wayland 与身份 | Viewer GdkClipboard 放 GUI；Host 后台能力按桌面探测；GUI/agent D-Bus 分名；补通知失败与 greeter 边界 |
| M3 Mac 功能遗漏 | 补睡眠/网络恢复、音频设备选择、后台注册、窗口适配、高精度滚轮与实时日志 |
| M4 打包与阶段 | Debian 候选限定 13+；依赖/监管/导出探针前置 U0；协调同 release 升级，保留可幂等回退的 Flutter 版本直到功能验收 |

## 需要修正的评审建议

1. **HUP 不等于 GPU 完成。** socket 关闭只能表明连接结束，不能直接让仍可能被 GPU 读取的 AVFrame 返回可复用池。正常路径等待完成 fence；异常路径作废当前 Viewer 代、停止提交并安全清理/隔离，无法证明完成时不复用旧池，也不无限生成新 worker。该要求与当前 Host 租约原则一致。
2. **GLsync 等待需要合法 GL context。** 不直接采用“任意独立线程调用 glClientWaitSync”。首选可跨线程/进程等待的 native sync_file；回退检查须在拥有有效同/共享 GL context 的位置非阻塞执行。
3. **210 MiB 是更严格的联合目标，不是从当前窗口 PSS 精确推算的节省。** v1 的分项上限不够清楚，v2 显式拆分并把原型预算验证前置。原始采样只做规划基线。
4. **已锁定 FFmpeg 的 READ 映射已有同步步骤，但可能阻塞。** 本地 `hwcontext_vaapi.c::vaapi_map_to_drm_esh` 先 `vaSyncSurface` 后导出，不能把此路径说成完全没有同步，也不能承诺超时一定打断驱动调用。v2 要求验证有界同步策略并隔离 Viewer 故障。
5. **新控制 IPC 与原 root DRM IPC 的身份要求不同。** 新 GUI/core 文件不同，用 UID、允许角色、同一受管理 release 等做控制接口校验；原 root DRM 仍要求同一 core executable，不放宽成仅 UID 检查。

核心核对对象为 `Build/Linux/src/rustdesk` 的 `platform/linux.rs`、`ipc.rs`、`ipc/auth.rs`、`common.rs`、`core_main.rs`、`ui_cm_interface.rs`、`server/dbus.rs`、`server/connection.rs` 与 Cargo.toml，以及 hwcodec 的 `ffmpeg_ram_decode.cpp`、固定 FFmpeg 9.0.2 的 `hwcontext_vaapi.c`/`avcodec.h`。这些是可由 Linux canonical pin/patch 重建的源码；本轮没有修改生成 checkout。

未完成项：headless 构建、监管 patch、GTK4/Viewer 原型、内存目标、各桌面能力、实际同步与故障恢复、完整安装/发布。本轮只修订文档，没有把这些项目标为通过。

## v2 最终核对与开发启动

[Claude 的 v2 核对原文](claude-v2-review.txt)于 2026-10-16 15:59:47（Asia/Shanghai）返回，结论为可实施、没有新的阻断点。用户随后授权完整 GUI 开发、后端对接与打包，Linux owner 开始 U0。新增接口约束已写入 v2.1：分平面 EGL 导入、多 FD 元数据、Viewer 配置只读/禁用核心保存密码、首次配置加载前加锁、未知活动与故障恢复分开。未采纳“仅因未知持续超过时间就可杀进程”的简化规则；显示变化集成单列验证，并不因此宣称完成。
