# hermes FFmpeg GPU 直通编码实验

2026-10-16，Asia/Shanghai。结论：**值得继续做 Linux Host 采集→转换→编码的接入原型**。当前 hermes 显示环境下 GPU 通路可行，CPU 成本很低。尚未实现 RustDesk 内部接入，不能把本次降幅作为完整客户端的降幅。

现有连接保持运行；独立 FFmpeg 抓取同一个 2560×1440 scanout，目标 30 FPS、H.264 Main VAAPI、CBR 4 Mbps、GOP 60、无 B 帧、async_depth=1。编码结果丢弃，不落盘桌面画面。没有重启或更换 RustDesk、改变显示模式、切换窗口或打开测试画布。

## 结果

CPU 的 100% 表示一个逻辑核。三轮正式测试各预热 8 秒、采样约 60 秒，顺序为 GPU→RAM、RAM→GPU、GPU→RAM；每个进程退出后才开始下一项，使用同一实验锁。

| FFmpeg 数据路径 | 三轮 CPU | 中位数 |
|---|---:|---:|
| GPU 直接映射、GPU 转 NV12、VAAPI 编码 | 3.52% / 3.86% / 3.94% | 3.86% |
| 读回 BGR0、CPU 转 NV12、上传、VAAPI 编码 | 40.30% / 40.75% / 40.75% | 40.75% |

**同一个 FFmpeg 中，GPU 路径相对 RAM 路径 CPU 下降 90.5%。** 这是约 0.37 个核的差异，不是整机百分比。对照组采用 FFmpeg 的 CPU 转换实现，并不是 RustDesk 的精确复刻，不能将 90.5% 套用到 RustDesk。

正式运行各编码 2120～2121 帧，按输出媒体时间约为 29.86 FPS；六项均无重复或丢弃帧、无编码/时间戳错误。基于一秒粒度 progress 的墙钟回归估计为 GPU 29.78 FPS、RAM 29.82 FPS，细小差异受 progress 更新量化影响。另通过只在管道内传递的独立 H.264 码流验证：90 帧全部成功解码、0 解码错误。该管道测试不作为画质或时延验收。

未运行 FFmpeg 的前后短基线中，五个 RustDesk 进程合计为 33.43% / 34.38% CPU，单独 drm-recv 为 18.53% / 18.76%。GPU 版 FFmpeg 整段采集、转换、编码的约 3.9%，已明显低于现有仅采集接收线程的成本，所以有理由继续投入接入原型。

测试路径与原 RustDesk 同时运行。GPU 测试期间原 RustDesk CPU 中位约 35.58%，RAM 测试期间约 31.59%；现场内容、调频及资源争用未严格控制，不从这两个数字推导 RustDesk 自身的性能变化。GNOME Shell CPU 两组中位约 0.16% / 0.11%。FD GPU 计数显示 FFmpeg 使用 compute/VPP 和硬件编码引擎；没有测量插座功耗。

FFmpeg 进程 PSS 中位为 GPU 46.8 MiB、RAM 93.4 MiB，仅作诊断数据。PSS 不完整覆盖 GPU surface，不能据此声称系统内存减少一半，也不代表 RustDesk GUI/CM 的内存收益。

## 现有连接的保护与实测

本机控制器每秒读取已有 Viewer 数值日志。状态/代际变化、错误计数增加、持续低帧率或帧龄超限，都会要求远端停止本次 FFmpeg 子进程。远端另有心跳超时和独立时长上限，只终止自己创建的子进程组。

从首次短探针到最终验证，08:37:27～08:52:51，共保存 924 条全窗口 Viewer 记录：

- 全部 streaming，同一 coreGeneration=17，未出现重连。
- decodeErrors、decoderResets、referenceFrameDrops、packetSequenceGaps 增量均为 0。
- 接收帧率平均 29.86 FPS、最低 29.78 FPS；呈现平均 29.48 FPS。
- 最大接收帧龄 43.66 ms、最大呈现帧龄 66.16 ms。这是帧新鲜度指标，不是端到端显示延迟。

实验进程已全部退出，RustDesk 五个 PID/start_ticks 与测试前一致，service MainPID=1880443 未变，显示仍为 2560×1440。实际加载的 `/usr/share/rustdesk/lib/librustdesk.so` SHA-256 与上轮恢复的原版一致。首次环境采集误用了没有 `lib/` 的路径，未取得本轮起始哈希；错误输出保留，最终按 `/proc/1880508/maps` 修正路径核验，没有冒充前后哈希比较。

## 方法与边界

AMD Radeon 780M / Mesa 26.0.8 / FFmpeg 8.0.1，`/dev/dri/card1` 与 renderD128 对应同一 GPU。当前 connector 为 Virtual-1，plane 42、XR24/BGR0、**linear modifier=0**。这次没有触及 AMD tiled/DCC 导入难题，不代表其他显示器、modifier、GPU 或驱动都能直接使用。

GPU 滤镜：

```text
hwmap=derive_device=vaapi:mode=read+direct,scale_vaapi=format=nv12
```

RAM 对照滤镜：

```text
hwmap=derive_device=vaapi:mode=read+direct,hwdownload,format=bgr0,format=nv12,hwupload
```

两者其余参数相同。`direct` 要求映射阶段不通过复制降级；GPU 转换仍产生 NV12 输出 surface。因此这里的 GPU 直通指避免 CPU 原始整帧读回、转换和再上传，不宣称 GPU 内完全没有搬运。参照 [FFmpeg kmsgrab 官方文档](https://ffmpeg.org/ffmpeg-devices.html#kmsgrab) 与 [hwmap 官方文档](https://ffmpeg.org/ffmpeg-filters.html#hwmap)。

为保护当前连接，保持用户原有桌面，未施加标准滚动/视频负载。没有验收完整 RustDesk 集成后的画质、颜色范围、光标合成、旋转/HDR、多屏、重连、锁屏恢复和端到端延迟。编码数据未上网发送，也未保存图像或码流。低 CPU 不等于低 GPU 或整机功耗。

## 后续决策

建议继续限定范围的 Host 媒体路径接入原型：保留现有协议、认证、输入、连接生命周期和权限边界，引入 DMA-BUF/VAAPI 编码适配层，向原传输层交付编码后的 access unit，并保留旧 CPU 路径作为能力不足时的回退。GUI 框架迁移不在这一结论中。

建议下一轮以完整 RustDesk 进程组 CPU 降低至少 50% 为继续投入目标，同时保持分辨率、FPS、编码参数、可比较画质及延迟，并补动态画面和生命周期回归。这是建议验收目标，不是本次已达到的结果；集成开销、同步和兼容性仍需原型验证。

## 证据与复算

- `summary.json`：六个正式样本、两次基线和中位数。
- `*-r*.jsonl`、`*-viewer.jsonl`：原始计数与连接守护记录。
- `ffmpeg-logs/`、`encoding-audit.json`：参数、硬件路径、编码进度及解码验证。
- `viewer-full-window.jsonl.gz` 与摘要：脱敏的全窗口数值日志。
- `environment-*.txt`、`clock-*.json`、`cleanup.json`：环境及收尾状态。
- `exclusions.json`：参数失败、时间戳修正前试跑及短时试跑重叠全部排除；正式样本没有重叠。
- Python 文件：实际运行工具，内含本次固定主机路径，不是通用部署脚本。

复算：`python3 analyze.py`。没有修改产品代码、安装包或系统配置，没有 commit/push/deploy。
