# FarPane Linux GPU 媒体重构（hermes）：RGBA 保留量修复与 `.4` 候选

2026-10-17，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本轮补齐最大像素 RGBA 的一个真实资源边界，完成新 core/GUI、Debian 和对应源码。未安装、未切服务/桌面/显示，未修改身份/凭据，未 commit/push/deploy。维护窗口仍待用户确认。[测试者说明](../../../Linux/docs/native-test-candidate.md)列明实际文件、支持范围和回退版本。

## 复现与改动

旧 `viewer_clipboard::provider` 直接用 GdkMemoryTexture/for_value 处理 RGBA，绕过字节 provider 的 256 MiB 保留登记与四路输出额度。新增私有 Xvfb 复现：三个 7680×4320、每份 132,710,400 字节的 RGBA provider 均被接受，第三份应拒绝的断言失败。见 `logs/native-rgba-budget-before.log` 和完整当时源码 `native-rgba-budget-before-tests.rs`。该结果证明保留量遗漏，不代表普通首页泄漏。

canonical 改动为 `Linux/native/viewer_clipboard.rs`、`Linux/gui/src/viewer_clipboard.rs`、对应 overlay pin 和测试驱动。Viewer 在已有剪贴板 owner 中复用 Host 既有纯 PNG 编码函数，按行检查取消，PNG 输出最多 128 MiB，实际处理期限三秒；授权、revision、停止状态在耗时操作前后复核。GUI 统一使用已有分块字节 provider，并拒绝未转换的 RGBA offer。没有新增依赖/线程，没有修改网络协议、权限或图片限额；原 PNG 不重编码，RGBA 网络能力仍由 worker 转换保留。

RGBA 输入、PNG 输出和封印通道各有存储成本；256 MiB 限的是当前/旧 GUI provider 正文，不是整个应用或外部粘贴消费者。未宣称整体内存达标，也没有把数据移动到 worker 后漏算成内存消失。

## 实际测试

| 测试 | 证据与范围 |
| --- | --- |
| 初次复现 | 日志断言失败：第三份最大 RGBA 被接受；私有 Xvfb，无宿主剪贴板/GPU |
| Release 转换 | `rgba-runs/20261017T035316Z` 和 `035826Z`：两项核心测试通过，含透明像素无损、实际封印通道、中途取消和畸形长度拒绝 |
| 最大像素 | 7680×4320，RGBA 132,710,400 字节→PNG 4,172,903 字节，转换/准备/通道交付约 0.626/0.624 秒；三秒期限启用，解码后的全部像素一致 |
| 普通 GTK 图片消费者 | `035826Z` 使用实际 `Clipboard::read_texture_future`，小图和最大图逐像素一致；未依赖直接 Texture 值 provider |
| 限额和恢复 | 实际四路卡住的 GIO 管道、第五路拒绝、超时与恢复；第三份 128 MiB PNG 保留拒绝，释放旧 provider 后再次成功；SVG 优先行为通过 |
| 产品 Release | 当前 core 与 GUI 均构建通过；canonical 重建、pin/patch/lock、staging 63 文件和构建 receipt 通过 |
| 实际双向网络剪贴板 | `native-viewer-smoke/20261017T040719Z`，两轮各 22 项通过，含真实 128 MiB PNG 双向字节/SHA-256 与权限行为 |
| Ubuntu 26.04 包 | `native-package-smoke/20261017T040808Z`，8 组包/私有库检查与两次真实软件视频连接通过 |
| Ubuntu 24.04 包 | `native-package-smoke/20261017T040825Z`，相同检查通过 |
| 包内 GPU | `native-viewer-smoke/20261017T040842Z`，13 项通过，VAAPI/EGL/GTK 呈现与归还，无软件帧回退 |
| Debian `.4` | 解包后的完整 payload、安装工具、README 确切版本及构建记录一致；未宿主安装 |
| 全新 GUI 源码构建 | `native-source-smoke/20261017T041112Z`，88,608 条归档核验、core/GUI 离线图、38 项协议测试、完整 GUI Release 和组件探测通过 |

首次修复编译因 `Part::new` 只支持 Vec 报错，改为 Part<Bytes> 结构体构造，保留所有者且不新增正文副本；`035210Z` 和失败日志保留。普通 GTK 消费者测试扩展后重新验证，没有用仅编译通过替代实际图片读取。

最大像素夹具是确定颜色图案，不是不可压缩噪声或整条远端 RGBA 会话；转换测试、GTK/provider 测试与真实 PNG 网络回归分开记录。真实桌面、Mac RGBA 互操作及整体峰值仍待验收。没有把本轮结果解释为 `.4` 的正式性能 A/B 或首页 60 MiB 已通过。

GPU 只用 renderD128、256×128 单路静态内容和私有 Weston/Xvfb；约 17.25 秒、86 次检查中已安装 FarPane 视频连接数始终为零。构建/测试使用既有隔离镜像，network none，约 4 核/12 GiB；GPU 沿用已有更低资源入口。没有宿主显示、KMS、音频、密码库或服务 socket。

## 冻结产物与源码

- 原始 core：`b9c87fe3fb1279a186ad3560ccc9d29bf671b512675ce648efa2b51b69b9acdb`；打包移除构建期 RPATH 后：`7c363f0e24fa7f71f0e6e16fb012b4a7c2942c646993025b4e3cc23dcb1c48b3`。
- 产品 GUI：`ad09133606585f70d1983d765f4c7f3923cdd95867d9ad47677c12812774eb49`。
- bundle `farpane-native-dev-5449206e830476baad6031d4`，307 条清单；tar SHA-256 `2f790fda6619cc7b212f143e87a3fe96303a2554740e9f08c8ea455c3acb6e97`。
- `farpane-native-candidate_0.1.0~dev.20261017.4_amd64.deb`，17,175,344 字节，SHA-256 `c73ff4c5167a06f1fbe73c6ab0adfe37aae925655bfce4121d72da553abc7bda`。
- `farpane-native-source-6464d1ae0ddf72e154ec4431.tar.gz`，761,002,170 字节，SHA-256 `6570f087109378d1b17286f7afb73ebe7d991a7386ad8138f20581a0bff35e94`。

新源码归档绑定产品 receipt；与此前 `3cfe49a3…` 比较，vendor 逐项不变，prepared core 仅 `src/farpane_native/viewer_clipboard.rs`、GUI 仅 `src/viewer_clipboard.rs` 变化。当前生成的 version.rs 未变化。全部 native 来源/配方和补充许可文本仍由生成器核对。材料报告重新绑定当前二进制，SHA-256 `922c135abe0f176e0d2fb25fd22e1220c32953c5046a2067d13b3ebe865ac183`；712 个包记录、45 个机械定位问题与前版相同，不能当作已完成法律/发布审计。

源码冷构建使用只读 Rust 1.89 SDK、空 Cargo/target 和独立输出，无工作区/编译缓存/网络挂载。得到证明用 GUI `3ffb9f4e42f63016eeb43a2b6ddda63ab8bb0ab05b23d2e67a6fa2075fb8338e`；没有替换产品 GUI，也未证明逐字节重现。全新 native media/core 依赖构建仍未执行，已有 FFmpeg 不重建。source manifest 冻结时的 `fresh_full_build_verified=false` 不事后修改；外部记录补充 GUI 冷构建结果，完整 core/media 仍未验收。

`.1`/`.2` 的实际 dpkg 安装器矩阵以及 `.3` 的文件/输入/feature 检查保留各自版本。本轮不重复未改变的矩阵，也不将旧结果重新标为 `.4` 实测。旧包、源码和证据不覆盖。

## 记录和剩余边界

`logs/` 保存失败、构建、回归及包/源码/宿主核验；`rgba-runs/` 保存 core/GDK 原始日志和转换结果；`runs/` 保存实际产品会话和包的输出；`source-smoke/` 保存冷构建原始材料。`excluded-payloads.json` 记录未复制的图片/测试载荷大小与哈希，不复制测试配置/凭据或编译输出。`native-rgba-budget-test-binaries.json` 记录最后一次实际运行的 core/GUI 测试可执行文件哈希，并确认文件没有晚于结果被修改。清单/receipt 与 `canonical-sha256.json` 区分产物冻结和后续文档更新；`SHA256SUMS` 校验本目录其他全部文件。

最终宿主检查与既有基线相同：current 为 `farpane-p1-445515cfa1ec-90876510-551585f0`，FarPane PID3212867，RustDesk PID1880443；四份 FFmpeg 静态库大小/mtime/SHA-256 不变。没有收到维护窗口确认，尚未切换。

首页/组合内存预算、真实 GNOME/KDE/Wayland/systemd/logind/锁屏/睡眠、Mac/旧版互操作、硬件音频/音画同步、1440p/多显示器/颜色/故障与长稳、配对 A/B、RPM、公开 Linux CI 和完整发布审计仍未关闭。最大像素转换这一局部通过，不代表整个 GUI/产品验收完成；`runtime_ready=false`。
