# FarPane Linux GPU 媒体重构（hermes）：大图片传输内存与当前候选

2026-10-17，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本轮只在工作区和既有隔离环境构建/测试；未安装到 hermes，未操作两个既有服务、桌面、显示模式或凭据，未 commit/push/deploy。面向测试者的版本与流程见[候选说明](../../../Linux/docs/native-test-candidate.md)。

## 改动及实际收益

canonical `Linux/native/transport.rs`、`Linux/native/mod.rs`、`Linux/patches/0040-native-clipboard-memory.patch` 与 `Linux/dependencies.lock.json`：native Host/Viewer 用收到的 `Bytes` 解析 protobuf，生成的正文可以共享接收存储；TCP 发送完成后，仅对大于 1 MiB 且写缓冲已空的消息释放缓冲所有者。未发送的字节必须保留。未改变加密、协议、权限、图片限额、旧 Flutter 或 WebSocket/WebRTC 路径；不是整条网络链路无复制。

| 轮次 | 修改前 GUI+Viewer+Host 同时峰值 | 修改后同时峰值 | 降幅 |
| --- | ---: | ---: | ---: |
| 0 | 1,095,666 KiB | 826,010 KiB | 24.61% |
| 1 | 1,116,417 KiB | 848,645 KiB | 23.98% |

基线 `native-viewer-smoke/20261017T032240Z`，修改后 `20261017T033007Z`。每轮 22 项实际剪贴板检查通过，发送 134,217,728 字节、接收 134,217,727 字节；对应 SHA-256 在前后两版相同。原始 samples/result、分角色峰值和汇总全部保留。峰值是同一时刻的三进程之和，**不是各自峰值相加**；各角色独立最大值并非都下降。

夹具是有效两像素 PNG 加 ancillary 填充，不是 8K/RGBA；每 0.1 秒采样，每轮约 2.3–2.5 秒。两台私有 Xvfb、loopback、容器禁外网，没有宿主桌面或 GPU。本轮结果不代表日常图片、完整网络加密链路峰值、慢网络、多会话或方案规定的 120 秒/三轮正式 A/B。单独的加密 duplex 单测覆盖了发送缓冲释放后的数据完整性。

## 首页 GL 诊断

`Linux/tests/native_gl_identity.c` 是测试专用 preload，记录 GTK 实际 EGL context 的厂商、renderer 和版本。初版 `20261017T031704Z` 的普通函数拦截没有命中 libepoxy，尽管视频检查通过，不能算身份检查通过。修正版通过 libepoxy 的 dispatch 指针记录，并由驱动强制要求三个有效字段。

`20261017T031800Z` 两轮均报告 AMD Radeon 780M、radeonsi/phoenix/ACO、OpenGL ES 3.2、Mesa 26.0.8。首页 PSS 108,222/101,611 KiB（105.7/99.2 MiB），**60 MiB 目标仍未通过**。不能仅凭 LLVM 映射判定 llvmpipe。此诊断没有改产品 GUI、驱动选择或默认渲染方式；只使用 renderD128、256×128 静态画面、私有 Weston/Xvfb，85 次检查确认已安装 FarPane 视频连接数始终为零。

## 构建和回归

| 检查 | 实际结果 |
| --- | --- |
| canonical source/patch/pin/lock 重建 | 通过；native staging 63 文件 |
| transport 单测 | 2 项通过：正文共享所有者/截断拒绝；加密大消息后小消息完整、未发完字节保留 |
| Release core/GUI 构建 | 通过；core 更新，GUI 未变化，FFmpeg 未重建 |
| 原生无 GPU / 旧 Flutter GPU feature check | 两组通过 |
| Ubuntu 26.04 bundle | `native-package-smoke/20261017T033309Z`，8 项包/私有库检查及两次实际视频连接通过 |
| Ubuntu 24.04 bundle | `native-package-smoke/20261017T033326Z`，相同检查通过 |
| 文件 | `native-viewer-smoke/20261017T033343Z`，12 项通过，含上传下载 SHA-256/批准/取消/回收 |
| 输入/IME | `native-viewer-smoke/20261017T033351Z`，15 项通过，含中文单次提交、预编辑本地保留、失焦与断开松键 |
| 包内实际 GPU | `native-viewer-smoke/20261017T033418Z`，13 项通过，两轮 VAAPI/EGL/呈现/回收，无软件帧回退 |
| Debian `.3` | 完整解包 payload 与 bundle 一致，安装工具/README 的确切版本及当前 receipt 通过；未宿主安装 |

最终 GPU 回归只用 renderD128、256×128 单路静态夹具，86 次检查中既有视频连接数为零，总计约 17.2 秒。所有构建和软件夹具遵守隔离网络、约 4 核/12 GiB；GPU 驱动使用既有限流入口。不把受控提供者或合成画面当作真实桌面验收。

## 冻结的产物

- 原始 core SHA-256：`6af506c96c99e166b66621818927a6f67b91ed1f4d51cd17aeb48281dbb147e2`；打包移除构建期 RPATH 后：`f92a053365ca6c2e27600854d39eb66cb0d934b782b402cf168eaa691b271e97`。
- GUI SHA-256：`084241464d065df9df864c9828c46d866b530e99acaf2d239d499505eacb495e`，与本轮之前相同。
- bundle `farpane-native-dev-90b070cf48653dfd5e5c4e24`，304 条清单；tar SHA-256 `a9312362aeca7cae656ac0f3e3baaebf43746489db77356ecdceda47f7dddcbe`。
- Debian `farpane-native-candidate_0.1.0~dev.20261017.3_amd64.deb`，17,170,724 字节，SHA-256 `220fa3fe1dd072e9b5e6524c3a7389aa279ba8c88d437026e5895acde2dad549`。
- source `farpane-native-source-3cfe49a30f85dc07724d4c67.tar.gz`，760,975,881 字节，SHA-256 `1a10d5a7990f56098d0b7e284f14a24e46774a022b3cf64ed89cd30b040bc252`；88,606 条归档逐项通过。

源码归档重新核对当前 canonical 重建、原生 port 原料和 60,731 个 vendor 文件。对比旧快照，vendor、GUI、协议库和文件库的条目逐项不变；prepared core 仅 `client/io_loop.rs`、`server/connection.rs`、`farpane_native/mod.rs`、`transport.rs` 四项变化。首次分析脚本错误要求日期生成文件也必须变化，导致断言失败；实际该文件未变化，修正为允许它不变后完整归档核验通过，首次失败日志保留。没有重跑未变化 GUI 的冷编译；其此前真实冷构建证据为 `native-source-smoke/20261017T031026Z`。全新媒体/core 依赖构建仍未验证。

材料清单已重新绑定新二进制，report SHA-256 `16d0d04b8be557b3ef2f84fa11d766dc9614b07edf88e7e93b3ba17931d649f7`；712 个包记录、45 个机械定位问题与旧报告一致。canonical notice pins 只更新 baseline hash，材料原文、包/文件 pin 和范围不变；源码归档已包含核验后的补充集合。完整许可审计仍为 false，没有把机械问题解释成未获授权。旧二进制、Debian、源码和证据不覆盖。

## 证据与边界

`logs/` 为命令日志、前后内存汇总、Debian/源码核验与最终宿主状态；`runs/` 保留指定轮次的原始 JSON、日志、maps 和 smaps。`excluded-payloads.json` 记录未复制的大夹具图片、二进制、截图的大小/哈希；不复制测试配置或凭据。`bundle/`、`native-build.json`、`source-manifest.json` 绑定实际产物；`canonical-sha256.json` 绑定本阶段结束时源码，晚于产物冻结的文档更新不冒充已打包内容。`SHA256SUMS` 校验本目录所有其他文件。

最终宿主检查与之前基线一致：FarPane PID 3212867，RustDesk PID 1880443，current 仍指向 `farpane-p1-445515cfa1ec-90876510-551585f0`；四份 FFmpeg 静态库的大小/mtime/SHA-256 均未变化。维护窗口请求尚待用户确认。

未关闭：首页与整体内存预算、最大像素 RGBA、真实 GNOME/KDE/Wayland/systemd/logind/锁屏/休眠、Mac/旧版互操作、硬件音频/音画同步、1440p/颜色/故障/20 轮/长稳、正式配对 A/B、RPM、公开 Linux CI 和完整发布审计。`runtime_ready=false`，本轮是可检查的开发候选和内存改进，不是全部 GUI/发布验收完成。
