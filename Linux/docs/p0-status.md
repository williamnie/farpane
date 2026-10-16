# FarPane Linux GPU 媒体重构（linux-host）：P0 状态

记录时间：2026-10-16 UTC。独立 Linux owner；分支 `codex/linux-host-gpu-media`，HEAD/main 基线 `32b06d2d4e7e0962ddb7152b7891d600703c9f81`。没有 worktree、commit、push、merge/rebase、部署或服务切换。

**已完成 B0 核心库及旁路验证；P0 整体尚未通过，P1 产品集成尚未开始。** 原连接保持不动，Mac 仅做源码只读审计。未运行旧实验切换脚本，未打开桌面/改变显示，未安装主机软件或写入主机 `/usr`。

## 具体产物

- B0 Release 核心库：`Build/Linux/artifacts/b0-fe666073a8c9/lib/librustdesk.so`，约 54 MiB。
- SHA-256：`fe666073a8c9df7d0550723737d11917d9a4f0df7515dc4a4995f3ad8634959f`。
- 构建特性：`flutter,hwcodec,drm`；GPU Host 尚未接入，不含 `drm-wake`。这是核心库评审产物，不是完整安装包。
- 依赖锁、补丁、许可证、配置和产物 manifest 一起放在 artifact 目录；完整日志在 `Build/Linux/logs/`，精选原始输出在 `Linux/evidence/p0/`。
- FFmpeg 9.0.2 源码包 SHA 和官方签名再次离线验证成功。没有重做全量 FFmpeg 构建；只因固定 surface 池需求增量编译 libavfilter。

## 已通过检查

| 检查 | 实际结果 | 原始日志 |
|---|---|---|
| hwcodec FFmpeg9 API 适配 | 新增 profile 常量补丁；原 key-frame 兼容补丁保留 | `scrap-check-02.log` |
| Linux 核心库 | Debug、Release 完整核心库链接成功 | `b0-regression-02.log`、`linux-b0-release-01.log` |
| scrap 回归 | 47 passed，0 failed；包括输出缓冲区 3 项 | `b0-regression-02.log` |
| 相关 root 回归 | 88 passed，1 ignored；DRM/光标/输入映射/IPC | `root-tests-03.log` |
| canonical parity | 从 pinned Git 对象/签名 tar 重新构造，10 个被补丁修改的文件及锁文件与 checkout 完全一致 | `source-parity-02.json` |
| 准备脚本回归 | 嵌套 Git 目录中确实应用补丁，重复执行不重打，拒绝覆盖冲突/未知源码 | `prepare-tests-01.log` |
| 原 CPU 上传路径 | H.264/HEVC 各 24 帧；软件和 VAAPI 解码、PTS、关键帧标志、MP4 box/trailer smoke 通过 | `p0-cpu-02.log` |
| 旧/新短 GOP 对照 | 7.1.1 与 9.0.2 均为 24 包、1 个 IDR key 包、2 个解码 I/key 帧 | `p0-legacy-cpu-short-03.log`、`p0-cpu-short-02.log` |
| 官方 GPU graph | DRM PRIME → hwmap read+direct → scale_vaapi NV12 → H264 VAAPI；XR24、AR24 各 60 帧成功解码 | `p0-gpu-10.log`、`p0-argb-02.log` |
| 色彩 | 预先固定平坦色块 NV12 误差≤3、解码≤10；实测两者最大 1；细线 luma PSNR 47.12 dB（门槛35）；SPS VUI SMPTE170M/limited/left 通过 | `p0-gpu-10.log` |
| 序号/混帧 | 动态 8 位序号逐帧匹配，未发现丢失/陈旧序号 | 同上 |
| 源完成点 | 先观察 surface 非 Ready；1ns `vaSyncSurface2` 实际返回 TIMEDOUT，继续保留源 lease，再用有界等待确认完成；之后才释放源、再送 encoder | 同上 |
| 有界池 | 新 pool_size=4；持有4帧时第5次分配返回 ENOMEM；释放后可复用；8代检查通过 | `p0-lifecycle-03.log` |
| 失败释放 | 8代、24/24租约释放；未提交替换、注入零期限、提交后异常；FD 4→4、peak leases=2 | 同上 |
| 一分钟旁路资源趋势 | 720/720帧和租约；PSS/USS 73064→73108 KiB；媒体FD恒10；两DRM client的VRAM/GTT计数稳定；退出FD 4→4 | `p0-steady-01.log`、`p0-steady-summary.json` |
| 最小探针池 | 单路、无B帧、async_depth=1、即时取包时，1个VPP输出surface跑完60帧 | `p0-pool-one-01.log` |
| 加载/自带库 | Release 核心的 ELF 依赖没有系统 libav*/libsw*；空根目录94个ELF文件，不含FFmpeg命令/动态库，RTLD_NOW成功 | `b0-release-link-audit.log`、`clean-load-02.log` |

AR24 补测包含 alpha=0/85/170/255 的色块，保持与CPU忽略alpha的转换结果一致。内存采样中的FD=11包含采样时自身打开的smaps_rollup；媒体循环单独计数为10。GPU计数按client去重，不能与PSS简单相加或据此宣称整机内存下降。一分钟趋势不替代P3长稳。

测试规模为 256×128 / 12 FPS / 单条 GPU 媒体流，均为合成内容。最后一轮60帧 VPP完成等待 P95约0.128ms，37次实测超时，短等待调用最大0.025ms；这是处理段/驱动调用数据，不是端到端延迟保证。输出池取4作为后续保守测试上限；1个surface足够的结论仅适用于上述同步探针，不能外推成产品或其他编码配置的最小池。

## 发现并修复的问题

1. 交接中的 `FF_PROFILE_H264_HIGH/HEVC_MAIN` 在 FFmpeg9 被移除：`0005` 改为 `AV_PROFILE_*`，仅 Linux 专用 hwcodec checkout 使用。
2. `prepare.py` 在没有 `.git` 的源码导出目录执行 `git apply`，会找到外层 FarPane 仓库并把标准 `diff --git` 补丁静默跳过（exit 0）。所以初次44项测试不能作为输出缓冲区回归。修正 Git ceiling、实际应用补丁、重跑47项与核心库，再用原始对象独立复算源码。
3. 9.0.2 `scale_vaapi` 默认输出池可增长。`0006` 给 scale 增加 `pool_size`，在 frames init 前指定固定池，默认0保持上游行为；未修改 encoder/CPU 路径。实际池耗尽测试证明不会靠继续分配掩盖背压。
4. 旧/新短GOP结果排除了测试断言误判：encoder把随机访问IDR标为key，decoder也标记非IDR intra帧。未修改产品的既有标志语义。
5. 复用vcpkg缓存中的旧FFmpeg debug/lib（avutil59.39.100）未被当前入口使用，但会留下误链接风险；已移至Build/Linux/retired/cached-ffmpeg-debug原样保留。准备脚本重复执行通过，当前搜索根只保留新版FFmpeg。
6. 初次GPU探针遇到Docker不继承节点ACL、GBM不能提供明确linear modifier、buffer初始化缺少hw_frames_ctx。分别限制容器内节点组、用AMD GTT显式线性测试BO、先设置buffersrc参数后init解决。未放宽导入条件。

## 尚未关闭的 P0 门槛

- **FarPane Mac颜色解释。** 源码 shader 固定BT.709，Linux CPU和GPU均BT.601。把已测GPU NV12代入当前shader，彩色色块推算最大通道偏差39；这依赖“VT保留原矩阵”的假设，**没有**在Mac测VT附件或显示像素。不能称作实测Mac色差，也不能称作已兼容。原版Viewer的libyuv反转换已审计，两个真实Viewer仍待验收。
- **真实DMA-BUF隐式同步/撕裂。** 合成源只有本探针写入，且源复用等到VPP读取完成；没有验证compositor持续写scanout时的撕裂/混帧。OwnedFd延长对象寿命不等于不可变快照。
- **实际权限/显示资格。** render-node用户权限已验证；未连接生产root DRM IPC，未重新抓真实首帧核验设备、显示、HDR/rotation/modifier资格。本轮未接收用户桌面画面。
- **端到端测量与原版基线。** 未测“源实际呈现→Viewer实际呈现”；不能用帧龄或上述VPP耗时替代。序号/时间码方案及仪器误差预算须在真实窗口校准并冻结，再做A/B；目前没有声称门槛已关闭。
- **B0连接回归/短A/B。** CPU编解码和录像是隔离接口smoke，不是完整连接。未测认证、重连、QoS、Refresh、新订阅者、真实截图/录像、协商切换。P2的A0/A1/B0/C归因收益尚不存在。
- **故障/资源完整性。** 已测正常驱动超时和注入应用期限，但未使GPU挂死。若无法证明完成，harness保留到自身进程退出；这不是RustDesk内的恢复策略。真实IPC credit、连接关闭后不ACK、跨generation异步结果隔离须在P1设计/测试，不可据此probe宣称已集成。
- **发布范围。** 干净加载仅核心库动态加载；没有完整UI安装包/干净系统连接验收、从零重建全部非FFmpeg依赖、其他发行版/GPU、Mac/Windows跨平台构建。本轮不扩大支持范围。

因此依照“P0真正通过再进P1”的要求，本轮只完成P1前置消费者/控制点审计，未把GPU原型接入 `video_service`。

## 下一维护窗口的具体内容

产物已备齐。后续窗口应先：核对原版、保留原核心哈希和回退路径；用可控色卡/序号画面校准两个Viewer和端到端测量；验证真实linear scanout导入及同步；再短暂替换B0核心，测试原CPU路径和同参数短A/B，结束恢复原版。替换会需要短暂重连，显示测试会改变当前可见内容，**均未执行**。锁屏/显示模式变化、P2/P3长稳属于后续窗口，不能以当前授权自行运行。

Mac矩阵缺口若实测确认需要代码修复，应在获准的Mac任务中解决；本Linux线程不越界修改Mac，也不默改Linux矩阵去适配某一个Viewer。

## 回归面最小化复核

- `hwcodec/cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp`、`cpp/common/util.cpp`：必要的已移除API兼容；不改变既有编码profile、解码关键帧含义。
- `hwcodec/build.rs`、RustDesk `Cargo.toml`、Linux锁文件：统一Linux新FFmpeg头文件/ABI、静态链接和本地hwcodec来源。
- RustDesk `drm_render.rs`、`drmtap_dl.rs`、`drm_capturer.rs`：保留已有B2输出缓冲区优化；没有增加GPU接收/编码/发送逻辑。
- FFmpeg `vaapi_vpp.h/.c`、`vf_scale_vaapi.c`：只增加显式固定池选项，默认0不改变旧行为。
- 新增独立P0测试和构建/审计脚本；未改网络协议、root服务、认证、配置/ID/密钥、Mac和xuanwu。
