# FarPane Linux GPU 媒体重构（linux-host）：真实连接与隐式布局修正

2026-10-16 UTC。用户已确认固定密码连接后显示桌面，又报告 CPU 仍高。
服务端实际状态为 `enabled=true/backend=cpu`；H.264 使用旧 HWRAM VAAPI 编码器。
开关开启不代表采集、转换已在新 GPU 管线运行。

## 连接修正

Mac mini 使用 linux-host 自建服务器。FarPane 现使用局域网 ID/Relay 地址
`192.0.2.10:21116`、`192.0.2.10:21117` 和该服务器公钥。
主机对公网域名的代理解析使混合地址中继配对超时；顺序注册的 LAN/LAN 探针成功。
首个未加注册间隔的探针存在竞态，不能作为 LAN 路径失败证据。

新 ID 为 `1000000000`。用户明确选择自己设置的固定密码；保持
`verification-method=use-permanent-password`，不修改固定密码，不启用临时密码。
此前临时密码 API 返回了一个值，但此模式不接受该值，先前把它给用户使用是错误的。
用户已确认收到桌面，服务端确认一条已认证视频连接；这不是只有 ID 注册在线。

## 根因及支持边界修正

新 capturer 原先只允许显式 `modifier=0`。实际 libdrmtap 描述符为
`DRM_FORMAT_MOD_INVALID=0x00ffffffffffffff`：KMS 没有声明显式 modifier，库不能将字段里的 0 当作线性证明。
只读元数据探针得到 2560×1440、XR24、单 plane、pitch 10240、SDR、无旋转；
普通用户在限定 renderD128 查询同一 DMA-BUF，得到 AMD `tiling_info=0x8000313fe000001b`。
它含非零 swizzle，实际为隐式分块布局。未读取、保存桌面像素。

旧实验的 KMS state 显示 `modifier=0`，但没有验证 FB modifier 有效标志或 BO 布局；
旧日志和性能原始数值保留不变，不能继续由此推导“当前 scanout 一定为线性”。

修复仅在现有 linux-host AMD `1002:1900`、同一导出/渲染设备、Virtual-1、单屏、SDR、
无旋转、XR24/AR24 范围内，增加 **驱动推断的隐式布局**。不是把未知 modifier 改写成 0：

- 描述符把实际 modifier 传到 FFmpeg。9.0.2 的 `hwcontext_vaapi.c` 对 INVALID 使用 PRIME 导入，
  由同一 GPU 的驱动解释缓冲区；`hwmap=read+direct`、NV12 转换、源完成点和固定池保持原样。
- 显式非线性 modifier、多 plane、HDR、旋转或其他设备继续拒绝；导入/转换失败仍成对回退。
- 原始 CPU mmap 截图拒绝隐式布局。显式截图请求在持有源租约期间使用既有用户态
  `RenderConverter` 解块并返回 RGBA；正常视频帧不触发该读回。
- 拒绝日志现在包含尺寸、plane、modifier、HDR、rotation、FD 字段，避免笼统报错。

## 验证与改动面

产品 C ABI 的线性和 GBM 隐式布局、XR24/AR24 共四组，各 36 帧，256×128/12 FPS，逐路执行。
编码后解码、BT.601 色块、PTS/IDR、编码前覆盖源和 FD 回收通过；色块最大误差 1。
无效显式 modifier 被拒绝，隐式布局不能误入原始 mmap 截图。
Rust 实际隐式 GBM 帧通过 `LinuxGpuFrame::rgba()`，逐像素截图检查通过。
两项既有 GPU 租约/初始化失败单测通过。仅映射 renderD128，无宿主桌面、服务 socket 或网络。

本次运行时代码仅改 `gpu_capture.rs`、`linux_gpu.rs`、`gpu_media.h/cpp` 四个自有模块，
增加自有 C ABI 的 modifier 字段；不改变上游共享 trait、root DRM IPC、认证、旧媒体实现或 Mac。
build 使用已有 FFmpeg 静态库；没有重建 FFmpeg。

真实连接后的最终运行状态、安装版本和短 CPU 采样另记于 application-status 与本轮 Evidence。
短采样不是受控 CPU/画质/延迟 A/B；动态 scanout 同步、撕裂、Mac 颜色解释、长稳仍待验收。

实际安装版：`farpane-p1-445515cfa1ec-90876510-551585f0`。用户确认画面正常，并再次重连保持连接；
该次 20 秒采样每秒均为一条已认证连接、`backend=gpu/generation=3`，无 CPU 回退。
GPU 采样总 CPU 7.87%、server 4.03%，前一旧路径短采样为 22.12%/18.68%（一个逻辑核=100%）。
一次采样开始前客户端已经关闭连接，得到的 2.74% 空闲数值明确排除。

截图测试重现：先以 GPU/FarPane/DRM/hwcodec features 编译 scrap 单测，把实际 test executable
复制为 `Build/Linux/bin/gpu-screenshot`，同目录 `lib/libdrmtap.so.0` 放置本项目已构建的库；
执行 `Scripts/linux/run-p0.sh screenshot`，只运行显式 ignored 的合成帧截图测试。
普通单测不会自动访问 GPU。实际 CPU 只读采样用
`sudo python3 -B Scripts/linux/sample-runtime.py --seconds 20`；此 linux-host 专用脚本每秒检查视频后端/代际，
若 `video_active_throughout=false` 或 `stable_pids=false`，不得作为稳定传输样本。
