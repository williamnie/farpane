# FarPane Linux GPU 媒体重构（linux-host）：P1 实现与验收边界

用户已明确允许先完成默认关闭的 GPU 集成，由用户执行真实连接验收。
本文件描述产品代码和隔离验证，不把 synthetic DMA-BUF 测试称为真实 scanout/端到端验收。

首次用户连接发现同机 ID 冲突，已补充独立随机 ID 与网络 UUID 命名空间，并安装修复版。
根因、必要改动面及新增验证见 [网络身份修复](network-identity.md)。之前的配置路径隔离检查不能证明网络身份隔离。

## 实现

- `linux-gpu-media` 构建特性依赖独立 FarPane 身份、DRM 和 hwcodec；运行选项 `linux-gpu-media=Y` 才启用，空值默认关闭。
- `LinuxGpuFrame` / `EncodeInput::LinuxGpu` / `EncoderCfg::LinuxGpu` 全部限定 Linux + feature。
  `TraitCapturer`、`TraitPixelBuffer`、`EncoderApi` 的签名未改变。
- 有类型 OwnedFd/Arc 租约；一个源只允许提交一次。未提交帧被替换时可归还 credit；已提交源由媒体线程保留。
- 媒体线程独占新 graph/device/encoder；官方 `buffer → hwmap(read+direct) → scale_vaapi → buffersink → h264_vaapi`。
  固定 4 个 NV12 surface、无 B 帧、async_depth=1、CBR；颜色为原 CPU 路径的 BT.601/SMPTE170M limited。
- VPP 目标 surface 完成后才归还源租约，随后编码 NV12。用户态等待有期限；驱动调用本身不能强杀。
  超时后停止新提交；无法证明完成的上下文与源由唯一旧 owner 保留。新 GPU-media 上下文最多一个，旧 owner 未退出时拒绝重试。
  不承诺 GPU/内核整体挂死时原 CPU/EGL/hwcodec 路径仍能正常工作。
- 新 capturer 使用原 root DRM IPC schema、身份认证、credit=2。只保留一个待取最新帧，ACK 通道容量 2。
  只有 socket readiness 等待参与 select；开始读取消息后保留原完整消息/SCM_RIGHTS 超时语义，不取消半包读取。
- 实际 root 显示身份和 Wayland 单屏 snapshot 匹配；限定 linux-host 的 `Virtual-1`、renderD128、实测 AMD PCI vendor/device `1002:1900`。
  每帧检查单 plane、linear modifier=0 或驱动推断的 implicit modifier、SDR、无旋转、XR24/AR24、尺寸/stride/offset/内核对象大小。
  实际 linux-host 帧含隐式分块布局；新增支持及先前线性判断的纠正见 [隐式布局修正](implicit-layout.md)。
  root 进程拒绝选择新 GPU-media 后端。
- 捕获与编码成对选择。初始化失败、编码失败、变化后的不支持配置均重建旧路径；普通 SWITCH 保留禁用原因。
  仅实际显示身份/几何变化、手动重试或旧连接全部退出后清除；snapshot 缓存计数本身不清除失败。
- 复用原 `handle_one_frame`、发送、Recorder、QoS、Refresh、codec 协商、新订阅者及隐私控制。
  帧率/质量需要改变时沿用 SWITCH。GPU 截图只在显式请求时做冷读回；隐式布局先由原驱动转换器解块。
  光标图像、位置及标定沿用原函数；显示拓扑变化时停止当前 GPU 流并重建。
- Flutter 设置中增加默认关闭的开关、后端/原因和手动重试；状态通过已有受保护 Config IPC 查询，不落盘每帧状态。

## 已取得的检查结果

原始日志位于 `Build/Linux/logs/`，最终交付时另归档到 `Evidence/LinuxHost/`。

| 检查 | 结果与范围 |
|---|---|
| 产品 C ABI、真实 renderD128 合成源 | XR24/AR24 各 36 帧解码通过；12 FPS、256×128、逐路运行；每种 3 个关键帧；PTS 与帧序号正确 |
| 颜色与源复用 | 编码前立即覆盖已完成的源，解码仍正确；BT.601 色块最大误差 1；SPS VUI 与约定一致 |
| 截图与失败销毁 | RGBA 冷读回逐像素通过；无效设备/offset/对象大小拒绝；包消费者失败返回错误并可销毁；FD 回到基线 |
| scrap feature-on | 49 项通过，包含恰好一次租约归还、无效设备初始化失败原因及 owner 释放 |
| 完整核心测试 | 414 项通过，4 项上游忽略；1 项因无显示失败，在无宿主挂载的 Xvfb 中单独补测通过 |
| 新回退状态测试 | 1 项通过：普通重建保持失败、显式重试/几何变化重置、旧代迟到错误不污染新代 |
| GPU feature-off | 完整核心编译通过；原 DRM capturer 66 项通过、1 项人工调查忽略 |
| Flutter | 132 项通过；新增 settings 文件静态分析无问题 |
| 准备/安装 | 6 项通过；保存旧产物、拒绝篡改和非本项目文件、安装不启动/启用服务 |
| 新核心干净加载 | 仅 94 个所需 ELF 的隔离根目录，无系统 FFmpeg 库/CLI，`RTLD_NOW` 通过 |
| 来源一致性 | pinned 上游重建 + canonical patch/overlay 字节比较通过；prepare 重入通过 |
| 实际 GUI 与系统安装 | Xvfb 内检查 General 的 GPU 面板和默认关闭状态；14 个 bundle ELF 依赖解析通过；root-owned 安装、单元语法、菜单路径和无副作用诊断通过 |

## 原有代码路径改动范围

- scrap `common/mod.rs`、`codec.rs`：新 enum 和编码工厂分支；旧 PixelBuffer/Texture/encoder 分支不改写。
- scrap `build.rs`、root/scrap Cargo：仅特性开启时编译/链接新 C++ 适配器。
- `server/drm_capturer.rs`：仅声明相邻新模块，旧 CPU receiver/capturer 保持原实现。
- `server/video_service.rs`：每服务的失败状态、成对选择、FPS/开关切换、GPU 截图；原发送、录像、QoS 流程保留。
- `ipc.rs`、`flutter_ffi.rs`：新增只读 GPU 状态键和编译能力键；没有改变 root DRM schema 或认证。
- Linux `platform/linux.rs`：模块声明和 `/opt/farpane` 安装识别。
- Flutter settings 页面：挂载独立组件；其他平台不显示，feature-off 查询能力为空。
- B0 身份、私有 libdrmtap 路径和 FFmpeg 兼容补丁继续保留，详见 application-status 与 P0 记录。

## 用户验收与维护窗口

安装器只放置 root-owned `/opt/farpane` 版本、独立 `farpane.service` 单元和菜单入口。
不启动/enable/daemon-reload 服务，不打开宿主 GUI，不接入现在的 RustDesk ID/配置。
GUI 和 root 服务必须使用同一 `/opt/farpane/farpane`，以保持原可执行文件身份认证；不放宽认证来接受用户可写副本。

2026-10-16 UTC 用户进一步明确授权“现在启动并开启 GPU”。已加载并启动独立 FarPane 服务、打开系统安装版 GUI、
启用并持久化 GPU 选项；服务运行、ID 注册在线，GPU 状态为 idle（尚无兼容连接），未设置开机自启。
这不改变安装器的默认行为，也不代表真实媒体管线已验收。记录见 application-status 和独立 activation Evidence。
需要回退时关闭该开关；异常原因可在同一位置查看。旧安装版本保留。

后续真实连接检查点：自建服务器与固定密码修正后用户确认收到桌面；隐式布局修复版
`farpane-p1-445515cfa1ec-90876510-551585f0` 实际选择 `LinuxGpu`，用户再次确认画面正常。
同一客户端重连再次成功进入 GPU 后端；H.264/2560×1440/4 Mbps，QoS 最后设置 36 FPS。
该帧率是服务端配置，不是测得的 Viewer 呈现帧率。首次连接的两次 SWITCH 是 FPS 协商重建，未回退 CPU。

以下仍未验收，不能称为 P0/P1/P2/P3 全部通过：

- 真实 scanout 的隐式同步、撕裂/混帧、动态桌面正确性。
- 原版 RustDesk Viewer 的实际协商，以及精确颜色、截图/录像、QoS/Refresh 和音频/输入。
  FarPane Mac Viewer 的 H.264 协商、出画面及用户重连已通过基本检查，尚未覆盖所有运行场景。
  Mac 固定 BT.709 shader 与 Linux BT.601 的既有解释差异仍需实机确认；本任务没有修改 Mac。
- 实际总 CPU、质量及端到端延迟 A/B；不能用合成适配器或前轮 FFmpeg CLI 的数字宣称产品降幅。
- 30–60 分钟及 24 小时长稳、锁屏/显示模式/设备变化。此类操作须维护窗口，不在本轮自动执行。
- Windows/macOS 原生编译：本机没有相应 SDK；仅完成 cfg 边界及变更面审查。

旧实验目录与两轮原始 Evidence 保持只读。分支保持 `codex/linux-host-gpu-media`；没有 commit/push/deploy 或启动现有服务。
