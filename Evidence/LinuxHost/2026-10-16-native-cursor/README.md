# FarPane Linux GPU 媒体重构（hermes）：原生光标检查点

2026-10-16。新 GUI 将远端 RGBA 形状转换为 GdkCursor，仅设置在远程画布。形状与位置事件分开，位置事件不会错误地切成 ID 0；退出/失败清除指针。缓存最多 32 项、单形状最多 96×96、严格检查字节数与热点，缺失/无效形状回到本地默认指针。没有扩大 64 KiB 控制报文上限。

## 实际检查

- `20261016T133646Z`：两个私有 Xvfb，实际 TCP 认证和画面。远端创建红/蓝、绿/蓝两种 32×32 cursor；本地 XFixes 读取最终硬件指针像素和热点。两次 GUI 会话中，颜色、(5,7)/(9,11) 热点、切换后选回缓存形状、本地工具栏不使用远端形状均通过。
- `20261016T133823Z`：新增半透明检查发现真实错误。远端 premultiplied ARGB `0x80800000` 到本地变成 `0x80400000`，因 GUI 误当 straight alpha 再次预乘。原始失败日志保留。
- `20261016T134530Z`：核心根据 PeerInfo 标记 Linux 光标的预乘语义，控制事件显式携带格式，GUI 使用匹配的 GDK MemoryFormat。最终 XFixes 读回 `0x80800000`，不透明色、热点、缓存重选、工具栏边界一起通过，两次会话都验证。读取的是实际 X 指针像素，未用 GTK 截图冒充指针验收。
- `20261016T134634Z`：私有 headless Wayland 两次 GPU 会话回归，VAAPI、共享 GLES、DMA-BUF 呈现、完成 ACK、历史记录、worker 回收、Host 保留通过。
- 轻量协议 21 项、GUI 3 项测试通过；核心/GUI Release 通过，canonical/source/lock 校验 PASS。没有重建 FFmpeg。

透明度判断依据是 pinned RustDesk 的 Linux XFixes/DRM 通道保留颜色值，而 macOS 的 get_cursor_data 逐个导出 NSColor 色彩和 alpha 分量。Mac 路径暂按 straight alpha 保留；未据此宣称 Mac/Windows/Wayland Host 等所有来源的光标均已验收。仅 Linux X11 来源做了上述透明像素实验。

剩余：真实桌面/HiDPI、其他来源与大尺寸、远端位置覆盖层；超过缓存上限的形状可能回到默认指针，不能宣称任意数量形状完整保留。GPU 回归仅 renderD128、256×128 静态单路、私有 12 Hz 输出；现有 FarPane 连接持续为零，原 RustDesk/已安装 FarPane/宿主桌面和音频都未改动。
