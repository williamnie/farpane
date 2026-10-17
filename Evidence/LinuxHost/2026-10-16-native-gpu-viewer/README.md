# FarPane Linux GPU 媒体重构（hermes）：原生 GPU Viewer 检查点

2026-10-16，`codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。源码尚未提交，原生 GUI 尚未安装。原 RustDesk 与现有 FarPane 的服务、配置和宿主桌面没有改变；没有 KMS、显示模式或主节点操作。FFmpeg 9.0.2 静态库继续复用，没有重建。

## 实现

- GtkGLArea 只允许 EGL/GLES3，在实际 context 初始化完成后才向 worker 宣告 DMA-BUF 格式和 modifier；初始化等待在控制线程，GTK 不等待 IPC。无合适能力时明确回退软件。
- R8/GR88 分平面 EGLImage 导入，在 shader 中处理 BT.601/709、limited/full 与 left/center chroma。转换结果写入持久的自有 RGBA 纹理，再绘入 GtkGLArea framebuffer；窗口重绘不再读取已经归还的 decoder surface。输入 texture 对象重用，整帧 RGB 存储仅在尺寸变化时重分配。
- 一次仅提交一个 GPU 租约，并保留一个最新的未导入候选。未导入的旧帧可以直接归还；已导入帧只有同一个有效 EGL context 的 GLsync 非阻塞检查确认完成后才 ACK。450 ms 未完成停止该 Viewer 代；Drop、socket HUP、上下文丢失均不伪造 ACK。
- GDK context、EGLImage、GL 对象、FD 和帧租约有明确 owner；context 保持存活直到原生对象退出。正常关闭继续检查完成，异常情况停止 worker、交驱动清理，不再复用该代池。驱动内部调用可能阻塞，未宣称能可靠恢复真实 GPU hang。
- `native-display-test.Dockerfile` 在既有隔离 builder 上增加仅供测试的 Weston/Xwayland。它们不进入产品依赖，也未安装到宿主。测试镜像因 Weston 包依赖带有发行版 AV 库，FarPane 核心与探针仍链接原有静态 FFmpeg 9.0.2；`native-gpu-needed.txt` 可核对探针动态依赖。

## 实际驱动兼容修复

780M / Mesa 26.0.8 宣告 R8/GR88 可导入，但 modifier 查询返回 0 项；GBM 和 VAAPI 实际返回 `0x00ffffffffffffff`（INVALID）。首版因此正确拒绝 GPU，而不是静默谎报成功；失败记录见 `initial-failures/`。

现在针对这种情况，在当前 EGL display 对应的 render 节点创建 16×16 自有 GBM 缓冲，实际验证 EGLImage 到 2D texture 的导入，宣告验证得到的原始 modifier。没有把 INVALID 改写成 linear，也没有省略布局属性来掩盖不兼容。[Khronos 规范](https://registry.khronos.org/EGL/extensions/EXT/EGL_EXT_image_dma_buf_import_modifiers.txt)规定 INVALID/省略值采用实现定义的布局；显式 0 才是 linear。这一设备上的真实解码图像另经下面的像素测试确认。

## 通过的检查

| 检查 | 结果与记录 |
| --- | --- |
| 软件 GLES shader | 实际 framebuffer 像素检查：601/709、limited/full、chroma 位置、方向、未完成租约拒绝重用、错误 context 拒绝查询；`gui-renderer-reuse-build.log` |
| 真 GPU 独立媒体链 | H.264/HEVC 各 4 帧，256×128、最多 12 FPS、编码器退出后才启动解码器；23 surface 合同、PTS、DMA-BUF 导入、GLsync 后归还；测试色块 RGB 最大误差 0；`native-gpu-reuse-probe.log` |
| 实际 GTK/Wayland 会话 | 私有 Xvfb Host + headless Weston，连续两次真实 TCP 登录/错误密码重试/VAAPI/GLArea/after-paint/断开回收；每次 1 个 GPU 帧和 1 次完成 ACK，无软件帧；`native-wayland-viewer.log`、`wayland/` |
| 实际 GTK/X11 会话 | 私有 Xwayland，经同一 headless compositor；同样两次真实 GPU 会话、无软件帧；`native-xwayland-viewer.log`、`xwayland/` |
| 软件兼容回归 | GLArea 接入后，输入/IME 14 项和文本剪贴板 11 项通过；两份 regression 日志（随后仅补充 GPU 测试计数与驱动能力探针） |
| GUI / Release | 3 项单测通过，最终 Release 10.30s；`gui-renderer-wayland-build.log` |
| canonical / staging | pin、patch、overlay、锁文件匹配；staging 保护 4 项通过 |

所有硬件运行只映射 `/dev/dri/renderD128`，没有宿主显示/桌面/服务 socket。独立探针 1 CPU/1 GiB，GUI 测试 2 CPU/2 GiB，实际桌面内容为 256×128 静态合成窗口；同一时刻只有一个测试连接。外层脚本只读查询已安装 FarPane 的视频连接数，并在出现连接或无法确认空闲时终止自己的测试容器。Wayland / Xwayland 轮次分别检查 62 / 66 次，始终为零，耗时约 12.4 / 13.2 秒。现有服务不会被该脚本启停。

两轮的 `renderer.json` 均明确 `software=false`；`viewer.json` 含 GPU 帧数、完成 ACK 数和 worker 回收状态；GUI 日志无 GTK/GLib 错误。截图为实际 GLArea 画面，方向和文字经查看确认。Xwayland 测试结束时，测试用 Weston 记录退出层清理警告及 Xwayland broken pipe；这发生在外层终止私有 compositor 时，不能描述为所有组件日志零警告。

Wayland 首轮外层日志的 `max_fps:12` 字段名不准确：12 是虚拟输出刷新率，独立媒体探针另有限速；Viewer 当前初始协商仍为 30 FPS。两次会话实际都只传了一帧静态画面，**不是持续 12 FPS 测试**。脚本已改为分开记录这两个含义，Xwayland 轮次使用修正后的报告。

## 内存与未验收项

PSS 为测试截图导出后的相邻采样，单位 MiB：

| 环境 | GUI（两次） | Viewer（两次） | 合成测试 Host（两次） |
| --- | --- | --- | --- |
| Wayland | 196.0 / 196.1 | 31.0 / 30.5 | 60.0 / 60.5 |
| Xwayland | 191.5 / 192.4 | 29.2 / 29.0 | 58.5 / 58.9 |

这里只是静态小画面，不是 1440p、高帧率、峰值或泄漏预算。GUI maps 仍有 LLVM、Gallium 和 Vulkan loader，需继续分解实际分配；不把小尺寸总和当作内存目标已通过。没有放宽首页 60 MiB 或完整 Viewer 的目标。

仍需真实用户桌面/原生 Xorg/最低发行版 ABI，持续画面与20轮同进程生命周期，尺寸/显示代变化、队列/ACK 超时和进程故障，缺失 VUI、完整 primaries/transfer 色彩边界、GPU 内存/CPU/延迟预算。其他完整 GUI 功能（文件传输、富剪贴板、设备/共享管理、后台/SNI/通知、音频与重连、打包/升级）仍未全部完成，`runtime_ready=false` 保留。

复现：

```sh
Scripts/linux/test-native-renderer.sh
Scripts/linux/native-container.sh Scripts/linux/build-native-gpu-test.sh
python3 -B Scripts/linux/run-native-gpu-test.py
python3 -B Scripts/linux/run-native-gpu-test.py --viewer
python3 -B Scripts/linux/run-native-gpu-test.py --viewer --x11
```

GPU 入口自动检查空闲，不能用于现有连接期间的性能对照。测试镜像用 `docker build --iidfile Build/Linux/gui-work/native-display-test-image.id - < Linux/packaging/native-display-test.Dockerfile` 构建，避免传入整个工作区。`source-state.json` 记录两个测试镜像及源码/产物 hash，`SHA256SUMS` 校验归档。此前证据保持原样。
