# FarPane Linux GPU 媒体重构（linux-host）：实连修复检查点

2026-10-16 UTC。独立 FarPane 已连接 linux-host 自建服务器，保留用户设置的固定密码。
用户确认 Mac mini 显示桌面；修复隐式 DMA-BUF 布局后再次确认画面正常，并重连保持连接供采样。
当前 ID `1000000000`，安装版本 `farpane-p1-445515cfa1ec-90876510-551585f0`，
核心 SHA256 `445515cfa1ece3579afc3834f8c6be500c19babc85afcc4c9d381281b7802099`。

## 实际结果

- 首次启用开关后仍为旧 CPU/HWRAM 路径：采集描述符的 modifier 为 INVALID，被新 capturer 拒绝。
- 普通用户查询同一 DMA-BUF 的 AMD 元数据，发现实际是隐式分块布局。KMS state 的 0 并非线性证明。
- 现将实际 modifier 传给 VAAPI PRIME 导入；未将未知布局强改为线性。原设备/显示/格式范围和失败回退保留。
- 冷截图复用既有 RenderConverter 解块；原始 mmap 截图拒绝隐式布局。
- 实连日志实际选择 LinuxGpu，2560×1440、H.264、4 Mbps；QoS 配置 15→32→36 FPS。
  这是服务端配置值，未测量 Viewer 呈现 FPS。启动两次 SWITCH 是 FPS 协商重建。
- 有效 20 秒采样每秒均为一条已认证连接、GPU 后端、generation=3；进程集合稳定。

| 当前桌面短采样 | 五个 FarPane 进程 CPU | 媒体 server CPU |
|---|---:|---:|
| 修复前旧媒体路径 | 22.12% | 18.68% |
| 修复后新 GPU 管线 | 7.87% | 4.03% |

CPU 以一个逻辑核为 100%，仅统计 FarPane。各采样约 20 秒，未控制桌面负载、协商 FPS 和编码参数，
不是正式性能 A/B，不据此宣称产品固定降幅。旧路径采样期间存在本项目构建任务，属于附加干扰。

## 检查

- 四组产品 C ABI 测试：线性/真实 GBM tiled、XR24/AR24，每组36帧，256×128/12FPS逐路执行。
  驱动元数据验证合成 tiled 源的 swizzle 非零；编码/解码、色卡最大误差1、PTS/IDR、编码前复用源、FD回收通过。
- Rust 实际 GBM 隐式帧截图逐像素通过；两项 scrap 租约/初始化失败单测通过；一项 root 持久回退测试通过。
- GPU Release 与 Flutter bundle 构建通过；94个ELF的无系统FFmpeg隔离加载通过；源码parity/prepare重入通过。
- 已安装 root-owned `/opt/farpane` 版本，独立服务 active，未开机自启；运行进程加载当前核心。
- 旧两轮实验140项文件哈希全部未变。源码、patch、pin在Linux；生成内容在Build。FFmpeg静态库未重建。

## 排除与限制

- `implicit-cpu-after.json` 是客户端主动关闭后取得的空闲样本（2.74%），已标记排除；不能拿来计算传输降幅。
- `implicit-runtime-active-01.json` 未归档，因为它实际记录的是 idle，不是有效GPU采样。
- `implicit-root-test-01.log` 的过滤词未匹配测试（0项），不计通过；02更正后实际运行1项通过。
- 最初中继探针未等待首端注册就启动第二端，存在配对竞态；02加入间隔后 LAN/LAN 通过、LAN/域名超时。
- 初次同步打开服务/GUI产生 FarPane IPC 占用，恢复为单 server 后实连成功；后续启动应先等服务IPC就绪，再开 --no-server GUI。
- 精确 Mac 颜色、动态scanout同步/撕裂、截图/录像完整交互、质量/FPS对齐CPU及端到端延迟A/B、30分钟/24小时长稳尚未验收。
- 原 RustDesk 服务/客户端配置未改，未切显示模式；未修改 Mac/xuanwu，没有commit/push。

详细实现与重现入口见 `Linux/docs/implicit-layout.md`。`logs/`只收录构建/探针、数值采样与媒体日志摘录，
不含密码、密钥或桌面图像。`canonical-files.json`记录工作区源码哈希，`manifest.json`记录实际安装包。
