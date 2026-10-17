# FarPane Linux GPU 媒体重构（linux-host）：纹理共享、资源构建与内存检查点

2026-10-16。本目录紧接 GPU Viewer 检查点，尚不是完整 GUI 或性能验收。

## 实际修正

- 补回 GUI build.rs 的 GResource 编译步骤。新增 C renderer 时曾覆盖旧步骤，增量缓存掩盖了缺失；已用全新临时 OUT_DIR 独立执行 build.rs，确认生成资源与 C 静态库，再跑 GUI 单测/Release 和实际连接。未声称完整 GTK 依赖 clean rebuild。
- 未指定 GSK_RENDERER 时使用 GL。Viewer 验证实际 GTK renderer 为 GL，并创建同 display 的默认已 realize context，检查 GL API 一致及 `is_shared`。不兼容则协商软件模式。私有 Wayland 实测两者都是 GLES，sharing=true；这是 GDK 的共享合同与实际画面检查，不是 GPU 指令跟踪。
- 首页显示两秒后、仍未进入 Viewer 时，独立短线程调用一次 glibc malloc_trim。返回首页亦可触发；无周期回收、不释放存活帧、不改 Host。后续要测反复连接和真实桌面延迟。

[GDK 官方共享合同](https://docs.gtk.org/gdk4/method.GLContext.is_shared.html)说明兼容 context 可以使用彼此纹理 ID；[GTK 4.14.5 EGL 实现](https://raw.githubusercontent.com/GNOME/gtk/4.14.5/gdk/gdkglcontext.c)使用 display 的共享 context。主线程不等待 IPC、GPU fence 或本次分配器回收。

## 原始测量（PSS MiB）

| 运行 | 首页两次 | Viewer 截图前两次 | 说明 |
| --- | --- | --- | --- |
| 124843 基线 | 180.9 / 175.4 | 178.7 / 177.5 | 首次细分；首页还没有解码器 |
| 125311 显式 trim 诊断 | 105.2 / 98.0 | 101.9 / 101.1 | 首页前约 182.1 / 175.4；Viewer 也单独 trim，不是产品行为 |
| 125438 cache 环境对照 | 181.3 / 175.3 | 178.0 / 177.3 | 未验证 shader cache 实际命中，不能据此断言缓存无效 |
| 125714 arena2 对照 | 177.6 / 172.7 | 172.4 / 173.1 | GUI 环境设 MALLOC_ARENA_MAX=2，未采用为产品默认 |
| 130634 首页单次后台回收 | 101.9 / 97.8 | 118.2 / 119.3 | 实际产品路径；Viewer 没有显式 trim，截图后约 137.2 / 138.2 |

首页主要成本包括匿名分配、LLVM/Gallium、GTK、字体；显式 trim 释放约 77 MiB，说明相当部分为分配器保留页。截图导出本身增加约 19 MiB，必须和截图前分开。60 MiB 首页目标仍未达到，没有上调预算。

所有 GPU 运行仅私有 headless Weston + 私有 Xvfb、256×128 静态桌面、renderD128。Virtual output 为 12 Hz，不能当成持续视频 12 FPS 的实测。两次独立 GUI 会话均完成真实网络登录、错密码重试、VAAPI/GLArea 呈现、fence ACK 和 worker 回收；同一 Host 保留。已安装 FarPane 的连接数在测试期间持续为零；无真实桌面或服务修改。

source-state.json 记录本检查点已构建 GUI 的 staging 文件映射和二进制哈希。此后设备管理的 canonical 源码可能继续修改；不以当前工作区冒充本次已测试快照。保留每次输出与采样 JSON，未改写上一个 GPU 检查点。
