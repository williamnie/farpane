# P1 前置审计：CPU 像素消费者与现有控制路径

审计对象为 RustDesk `fada664df7a294d1d1a9ca3e7cd3637069122f17` + Linux 输出缓冲区补丁。以下相对路径均指 `Build/Linux/src/rustdesk/`。这是 P1 的实现清单，**尚未改动主循环、增加 GPU enum/运行开关或连接生产服务**。P0 未关闭前不把这些建议写成已集成能力。

| 消费者/位置 | 当前行为 | GPU 集成必须保持的行为 |
|---|---|---|
| `libs/scrap/src/common/mod.rs: Frame::valid` | PixelBuffer 通过 data 非空判断 | GPU 用已验证描述符、有效 owned lease、当前 generation 判断；不能访问 CPU 像素来判空 |
| 同文件 `Frame::to` / `common/convert.rs` | libyuv 把 BGRA/RGBA 转成 NV12/I420 | Linux+feature 新 variant 直接交 owned GPU input；旧分支逐行保持；不让 CPU encoder 接受 GPU 帧 |
| `src/server/drm_capturer.rs: recv_thread` | 每帧转换到 Vec 后发布并 ACK | GPU 接收只保留描述符/OwnedFd 和 cursor 元数据；credit=2；已提交源的 ACK 必须等目标 VPP surface 完成 |
| 同文件 `IpcDrmCapturer::frame` | 回收 Vec、校验首帧/后续尺寸、按 plane/output transform 转像素 | 当前 GPU 支持仅无旋转；首帧、布局 generation、尺寸检查继续使用元数据；不能只用 width/height 绕过布局变化 |
| 同文件 `unrotate_bgra` | 真正读取 CPU 像素并旋转 | 有旋转/反射/不确定 transform 时，capturer/encoder 成对选择 CPU；不得静默忽略 |
| `video_service.rs:803` 截图 | 从 PixelBuffer 转 RGBA 后 PNG；Texture 触发 SWITCH 重试 | GPU 增加受控的一次 readback，并正确归还/保留租约；失败返回截图错误；不能把热路径所有帧读回，也不能套用 Texture 分支丢失 Linux 截图 |
| `video_service.rs:1467 get_rgba_from_pixelbuf` | 读取 data 与 stride，处理 padding | 保留 CPU helper；GPU 截图另走冷路径；颜色/尺寸/stride 与编码图像一致 |
| `video_service.rs:915` 重复编码旧 YUV | 非 latency-free encoder 在 WouldBlock 时重复旧缓冲 | GPU encoder 明确 latency-free；不能把上个 generation 的 yuv 向 GPU encoder 发送 |
| `video_service.rs:1237 handle_one_frame` | 编码后 VideoFrame 同时送 Recorder 与订阅者 | 复用这一函数和原发送循环；录像消费压缩包，毋须原始像素 |
| `drm_capturer.rs: on_cursor_plane/on_cursor_shape` | 标定用 plane 位置与独立 cursor sprite，不读取整帧 | 保持元数据、hotspot、epoch/generation；独立 cursor sprite 仍是 CPU 数据，不属于整帧热读回 |
| `video_service.rs` 隐私/UAC | 控制状态变化导致 SWITCH；Windows mag 是独立实现 | 不绕过 privacy gate；Linux 状态变化继续触发重建。审计范围未找到 DRM 整帧黑色/变化检测，不能把 Windows/PipeWire 的检测迁到 GPU 热路径 |
| `common/wayland.rs` / PipeWire | 另一套 CPU PixelProvider | 不改；不符合 GPU 条件时保留原回退路径 |
| `common/hwcodec.rs: HwRamDecoderImage::to_fmt` | Viewer 解码图像用 libyuv NV12/I420 → RGB | 不改 Viewer 路径；依赖升级单独回归，不能只验证新 Host |

## 控制及所有权约束

- 新订阅者在 `handle_one_frame` 内触发原 `SWITCH`；新 generation 必须先发有效参数集和 IDR。QoS、Refresh、码率/FPS 改变继续复用既有控制，不能另写发送循环。
- `(device, crtc_id)`、connector identity、Wayland snapshot generation 都参与资格判断。AMD vendor、匹配 render node、Wayland 单屏/SDR/无旋转、H.264、XR24/AR24、modifier=0 和每帧布局验证全部满足后才能配对选择 GPU。
- `DmabufDesc` 虽保留 `has_fd=false` 的旧注释，但 pinned producer 的实际发送路径已经给每个导出帧附带 FD（`ipc/drm.rs:1068`），避免 fb_id 重用导致旧导入命中。首版 GPU 可拒绝缺少 FD 的帧并回退；不要把 fb_id 当成资源所有权，也不要为了新路径改 root IPC schema。
- 每个 DMA-BUF 所属对象大小从内核取得，校验 plane/object/layer 数量、fourcc、pitch/offset、尺寸、溢出、modifier、HDR/rotation 与设备身份。每代 pending ≤2，NV12 池显式固定，包队列有界。
- 未提交被替换的帧可以立即释放/还 credit。提交后的源 lease 由同一媒体线程持有到目标 surface 完成。完成发生在 encoder send 之前。IPC 已关闭时不再写 ACK。
- `vaSyncSurface2` 真超时在 P0 已出现；这不允许释放 lease。失败或 timeout 后停止提交，保留 owner；若没有可证明完成点，不能以 Drop/线程强杀假装清理成功。P0 harness 对无法解决的挂死选择保留到独立测试进程退出，这**不是**可移植到 RustDesk 的恢复实现。
- GPU 失败禁用状态必须跨 `SWITCH` 保持；仅新连接/显示设备变化/显式重试清除。不能复用只覆盖 CPU EGL converter 的 `prefer_cpu` 而丢失 GPU generation 语义。
- 同一媒体线程拥有 device/graph/encoder；不能在 Tokio 或全局锁内等待。销毁顺序为停止提交、完成/安全隔离工作、释放应用/graph/encoder 帧、最后 frames/device；不手动 `vaTerminate` FFmpeg 拥有的 display。

## 颜色及 Viewer 解释

Linux CPU 路径 `ARGBToNV12` 与 hwcodec `set_av_codec_ctx` 为 BT.601/SMPTE170M limited；原版 Viewer 的 libyuv 反转换与它一致。GPU harness 显式设置同一矩阵、range、primaries、transfer 和 left chroma，并检查解码后的 SPS VUI。

只读检查当前 Mac `Sources/VideoPipeline/VideoToolboxDecoder.swift` 请求 NV12 video range，而 `MetalVideoRenderer.swift:238` 固定按 BT.709 计算，未在 shader 路径按帧切换矩阵。`viewer_color_contract.py` 仅计算这种系数应用到已测 NV12 的结果；没有测量 VT 输出附件或最终显示像素，不能代替 Mac 验收。此发现是前置兼容缺口，不在本任务中修改 Mac，也不通过把 Linux 输出改成 BT.709 来掩盖它。
