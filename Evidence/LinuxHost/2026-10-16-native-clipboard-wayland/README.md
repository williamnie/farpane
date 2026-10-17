# FarPane Linux GPU 媒体重构（linux-host）：Wayland 后台剪贴板

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40b`。这是原生 GUI 开发检查点；完整目标仍在进行，`runtime_ready=false`，没有安装这个原型或替换现有服务。

新增 `clipboard_wayland.rs` 和显式平台选择层，Host 既有单工作线程可使用 ext-data-control，缺失时选择 wlr-data-control。无 GTK、隐藏窗口、surface、焦点操作或 Xwayland 回退。复用三类、双方向授权和现有网络额度；原字节共享、有界 RGBA 编码、四路管道输出、256 MiB 独立 selection 存储、3 秒不活动/30 秒总期限。选择被替换后已开始的传输可完成，关闭读者/超时释放。完整约束见 `contract-snapshot.md`。

| 检查 | 实际结果 |
| --- | --- |
| 私有 Sway，两种协议 | `wayland/20261016T221445Z`，ext/wlr 各 24 项：UTF-8、富文本、SVG、透明 RGBA、128 MiB PNG 收发、四路/第五路拒绝、旧 source 替换后完成、保留额度、关闭/超时/恢复、无多余线程等 |
| 初始化与继承 FD | 实际沉默 Unix socket 分别约 3002/3001 ms 后退出初始化；继承的 WAYLAND_SOCKET FD 和环境保持原样，明确拒绝使用该模式 |
| 能力缺失 | `wayland/20261016T221606Z`，私有 Weston 未提供 data-control，Reader/Writer 都返回 `Wayland compositor does not grant data-control`，没有 Xwayland 回退 |
| X11 实际连接回归 | `source-state.json` 指定最终两轮 clipboard-large，仍通过各 22 项和最大字节 PNG 双向校验，画面持续，Viewer 回收、Host 保留；输入模式两轮通过失焦/断开松键和中文输入 |
| 构建 | Host 3 项测试、旧 Flutter/GPU feature check、native core Release 通过；GUI 未修改、沿用此前验收二进制；pin/patch/overlay/lock 和 62 文件 staging 核对通过 |

最终核心 SHA-256：`c1462b4fb6b9cf2238274d322586b59bea8f97790af733f2dc42e6df389b5307`；GUI：`bca3ec7370662bc413190b41965bf5d77f12c5ffc764abeb3d2b5620304592ff`。原始命令日志在 `logs/`，各次协议报告、合成器和工具日志在 `wayland/`。

Sway 测试镜像固定为 `sha256:817c9fd770763d2fd4a0b03fc646f43c33e92a907b887fbb9662b3daf4ad3a73`，包版本清单随最终运行归档。仅测试构建允许屏蔽 ext manager，以覆盖 wlr 分支；生产构建按真实协议协商。源码依赖使用缓存里已有的 wayland-client 0.31.11、wayland-protocols 0.32.9、wayland-protocols-wlr 0.3.9，没有重建 FFmpeg。

保留的失败和修复：`20261016T220704Z` 的测试误认为 wl-copy 对 HTML 只提供一个格式；实际工具还提供纯文本 fallback，修正夹具断言并核对相同字节后通过。`source-check-2.log` 是一次 canonical Host 状态提示尚未同步到生成目录的检查失败；同步后最终 source check 通过。初次 Weston 缺失能力检查报 no-seat；之后调整检查顺序，最终明确报告缺失 data-control。原始日志不删除或覆盖。

这批测试使用私有 Sway/pixman、Weston 和 Xvfb，容器无宿主显示、服务 socket、音频、密钥或 GPU 节点。没有改变宿主剪贴板、显示模式、服务、配置或已安装的 FarPane/RustDesk。

限制：仅支持单个明确 seat 与具名 Wayland socket；不支持继承 WAYLAND_SOCKET 的连接环境。平台能力失败会更新本地状态，尚未增加远端专用动态能力字段。实际 compositor 重启/撤销、多个 seat、GNOME/KDE、安全上下文、完整 Wayland Host 网络媒体会话仍未验收。128 MiB PNG 是有填充的两像素图片，不能替代最大像素 RGBA/解码验收。X11 回归的完整链路内存样本保存在 `x11-memory-summary.json`，仍未通过低内存目标；局部 Wayland provider 成功不等于整个应用低内存验收。

其余未验收项包括 Mac/旧版互操作、慢网络/多连接/动态媒体并发、后台/睡眠/网络恢复、音频硬件、1440p GPU/长稳/同条件 A/B、发行版 ABI、原生安装包及回退。继续推进这些工作，不能据此把 U4/U5 或完整产品标为完成。

复现：`Scripts/linux/test-native-wayland-clipboard.sh supported`、`unavailable`；X11 使用 `Scripts/linux/test-native-viewer.sh clipboard-large`、`input`。生成的大图片与测试可执行文件留在 Build/，`excluded-generated-files.json` 记录长度、哈希和未复制原因。`source-state.json` 固定 canonical/二进制，`evidence-sha256.json` 固定本归档；此前证据目录保持原样。
