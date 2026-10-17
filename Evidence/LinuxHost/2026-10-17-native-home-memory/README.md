# FarPane Linux GPU 媒体重构（linux-host）：首页资源归因

本轮使用同一 `.5` 候选，完成文件页共享对照、分配器诊断和独立首页 30 秒采样。产品源码、二进制、默认 GPU/分配器行为没有改变。结果补充了原隔离内存测量的边界；**不将它记录为产品内存优化或 60 MiB 目标通过**。

## 实际问题与实现

原首页的主要映射包括 LLVM/Gallium、GTK/libadwaita 及 Noto CJK 字体。逐文件核对发现六份镜像文件与宿主 SHA-256 一致，inode 不同。新测试 `native_shared_runtime.py` 只读挂载这六份内容相同的系统文件，运行前比较镜像与宿主哈希/大小，运行后核对宿主未变；`analysis/analysis.json` 还验证了每份实际 smaps 中的设备/inode。既不修改系统库，也不挂载宿主显示、服务、用户配置或凭据。

`run-native-gpu-test.py` 新增显式诊断选项 `--shared-runtime-pages`、`--home-memory` 和 `--memory-probe mmap128k`。后者只给合成 GUI 进程设置 `MALLOC_MMAP_THRESHOLD_=131072`、`MALLOC_TRIM_THRESHOLD_=131072`，没有写入产品启动设置。仍沿用 GPU 独占测试锁、限定 renderD128、连续已安装 FarPane 视频数检测和运行期限。

`native_home_memory.py` 不设置自动 Viewer 测试开关，运行真实首页，在 3/10/30 秒读取 smaps、CPU ticks、FD、线程、子进程和去重 DRM client fdinfo。没有截图导出或测试强制 trim，应用原有一次后台 trim 正常运行。测量结束后只终止本次私有 GUI；它不是用户点击关闭或真实 systemd 生命周期验收。

## 原始运行

全部运行使用 `.5` bundle `farpane-native-dev-5ad72a016972fad57d895c5e`：GUI `482a3d8d69a31199de48b2d4a368c21101d79a1bb902404223282990f6221cc0`，核心 `4e0ac6b78fcc2e630aa52fe2485dc727bd1a5f45c3597e8b3daf970264cf3ced`。每次实际可执行文件均逐项匹配。

| 目录 | 模式 | 结果 |
| --- | --- | --- |
| `20261017T053425Z` | 同内容系统文件页、identity | 两次短 GPU 会话通过，首页 78.96 / 78.12 MiB |
| `20261017T053456Z` | 原镜像文件、identity | 两次短 GPU 会话通过，首页 104.80 / 98.83 MiB |
| `20261017T053603Z` | 同内容系统文件页、mmap128k | 两次短 GPU 会话通过，首页 75.58 / 74.77 MiB |
| `20261017T053834Z` | 同内容系统文件页、默认分配器、首页保持 | 30 秒 PSS 78.42 MiB、USS 60.44 MiB、CPU 单核 0.074% |
| `20261017T053958Z` | 同内容系统文件页、mmap128k、首页保持 | 30 秒 PSS 75.45 MiB、USS 57.69 MiB、CPU 单核 0.037% |

三个连接模式均验证实际 AMD Radeon 780M/radeonsi/ACO、OpenGL ES 3.2、Mesa 26.0.8，以及 VAAPI/DMA-BUF/GTK 呈现和 Viewer 回收；没有软件帧回退。最初 mmap 连接运行已经输出 GL identity，汇总器对其日志补做三个非空字段检查；随后 harness 也将 mmap 纳入自动 identity 检查，不为这个检查重复连接。

连接使用 256×128 静态源；私有 Weston 和 GUI 窗口为 1020×720，虚拟输出 12 Hz。首页保持模式不启动 Viewer，原 runner 日志里的 `dimensions=256x128` 仅来自未使用的合成 Host 夹具；最终代码在此模式明确输出 null，并另列窗口尺寸，不改写原记录。不能将虚拟刷新率或短时出图当成持续 12 FPS 实测。

五个 handle87130/90198/75964/52828/58151 均 exit0；595 次已安装 FarPane 空闲检测全为零。每次运行约 17 或 34 秒，测试全部结束，没有后台遗留。

## 归因与决定

`analysis/attribution.json` 显示同一轮的六文件 PSS 从 51,604/45,754 KiB 变为 25,430/24,310 KiB；堆与匿名页仍约 32 MiB。这解释了镜像口径与共享页口径的大部分差额，没有把它描述成应用减掉了相同数量的私有分配。

默认首页 3 秒 78.52 MiB，30 秒 78.42 MiB，延长等待没有明显下降。两组首页 FD 均稳定为 12，子进程为 0、SwapPss 为 0，最终线程数 20。默认条件在这次隔离采样中达到 GUI 空闲 CPU ≤0.5% 的目标；两条件 CPU 仅相差一个 tick，不推断分配策略带来 CPU 优化。

两个首页条件的 DRM 驻留报告均为 GTT 34,836 KiB、VRAM 47,852 KiB；3–30 秒引擎计数未继续增加。GPU 数据单列，不能直接与 PSS 相加或忽略潜在映射重叠。该结果不是整体 FarPane/合成器预算验收。

固定分配阈值仅使本次首页稳态少约 3 MiB，60 MiB 目标仍失败；图片传输、软件回退、长期 UI、最低环境和完整性能矩阵未验证。因此本轮没有修改产品分配器或关闭图形能力。真实桌面共享还受其他运行进程影响，六文件页诊断不能替代 GNOME/KDE 实际安装与配对 A/B。

## 保持与后续

`analysis/host-state.json` 与上一阶段一致：当前旧 FarPane release、FarPane/RustDesk PID/状态、旧四份 FFmpeg `.a` 的大小/mtime/hash 未变。原产品 receipt 和 `.5` bundle/Deb/源码归档哈希核对通过。无编译、宿主安装、服务/桌面切换、commit/push/deploy。维护窗口确认仍待回复。

canonical 变更仅测试/诊断及文档；截图和 preload `.so` 只留哈希/大小，原文件在 Build。60 MiB、真实桌面/组合预算、20 轮与长期媒体、公开 CI/完整许可等原范围保持未完成。本阶段提供新的测量证据，不关闭整个开发目标。

`SHA256SUMS` 是本地证据索引，不是发布者签名。
