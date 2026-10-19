# FarPane Linux GPU 媒体重构（linux-host）：会话工具条收起

最新候选（2026-10-19，用户时区）：[Viewer 小窗口与缩放修复](viewer-layout.md)已形成 `.20261018.7` Debian/RPM 与配套完整源码。旧版失败时窗口被撑宽至 865 像素的问题已复现并修复；800×600 / 1020×720 × 1× / 2× 四组通过，2× 额外验证 Tab 导航。Ubuntu 六组、Fedora 七组包事务和共四次软件连接通过；源码 91,491 条目与离线依赖核对通过，没有重复编译核心/FFmpeg。当前 linux-host `.1` 未切换，真实桌面/GPU/分数缩放、中文及完整发布仍待验收。按用户决定，内存/字体优化保持暂停，60 MiB 不再阻塞交付。

最新交付材料（2026-10-18）：[`.6` RPM 与完整应用源码](gui-delivery-20261018-6.md)已同步到同一 `532627a818c8f7d0e65df626` bundle。Fedora 44 七组实际包事务、两次软件视频连接通过；新源码压缩包解出后 91,491 条目与候选构建/编译目录核对通过，core 666 / GUI 71 项离线依赖全部来自归档。独立 17 份包装配方重打 RPM 的 hash 与首次包相同。没有重编或安装，完整许可审计仍有 17 条记录，真实桌面/GPU/Viewer 缩放等验收仍开放；内存与中文特判继续暂停。

2026-10-18。补齐 GUI 方案 §5.2 的可折叠工具条：会话标题栏新增收起/展开按钮，断开、全屏和本机连接入口始终保留。收起共享/显示器/HUD 工具条及自动重连选项后，画面获得更多纵向空间；用户可随时展开。进入认证、非 streaming 状态或本地 Viewer 失败时自动展开，避免错误和重试入口被隐藏。

每次收起/展开先释放远端已按下的键鼠、IME 预编辑和独占键盘，再改变画面布局。没有更改媒体帧、协议、输入提交方式或 Host。中文输入应用特判草稿未进入本候选，相关讨论继续暂停；内存优化也保持暂停。

## 实现与独立构建

产品只修改 `Linux/gui/src/viewer.rs`。`build-native-gui-update.py` 将当前 GUI 与冻结 `.5` 的协议源码复制到新的 Build 目录，要求 GUI 依赖清单/锁文件/C 桥接保持原字节，只编译 Rust GUI；它没有读取或构建活动 `0044` 核心草稿。固定 builder、离线/locked、4 CPU/12 GiB，复用已有 Cargo 缓存。两次 GUI 构建的九项单测均通过，一项既有图形夹具测试按环境要求忽略。

首版 GUI 在实际连接中暴露出问题：Revealer 隐藏了内容，但仍占 85 像素高度。失败截图与几何记录保留，`15a5fe5b5a193789da288c56` 是被否决的实验 bundle。修正为同时隐藏容器后，实际画面控件高度从 541 增至 626 像素，展开恢复原尺寸。首轮打包还因新增来源目录权限错误被拒绝；修正工具统一目录模式后通过，未放宽 bundle 校验。

`repackage-native-gui.py` 验证父包、构建输入、日志、GUI 产物、全部编译源码和非 GUI 二进制。新 build receipt 明确记载 GUI 增量构建及 core/media 复用。依赖材料原文件不变；仅允许已有 GUI Rust 文件差异的 source-map 绑定更新，禁止依赖锁文件、C 或核心变化。旧审计的二进制哈希和未关闭项仍保持原含义，不能将其宣称为新 GUI 全面许可审计。14 项材料测试、4 项增量边界测试通过。

## 实际验证

`test-native-home-layout.py --viewer-toolbar` 使用私有 Xvfb、独立 Host、真实认证与软件视频，外部点击原始 GUI，不启用产品内部 smoke 操作。只读 GTK 观察器记录布局，绝不读取可编辑字段值。九项检查通过：

1. 按住的远端 Control 在收起后释放。
2. 工具条隐藏，画面高度增加，断开入口仍可见。
3. 收起期间新颜色帧仍实际到达并呈现，同一个 Viewer 保留。
4. 展开恢复原布局；收起和展开后的点击均映射到远端预期坐标。
5. 终止确切的私有 Viewer 后，worker 被回收，错误与重试自动恢复可见。
6. 断开返回首页，独立 Host、身份、服务器及权限开关保留。

上面按行为合并说明，原始结果包含九个命名检查。两项显示隔离边界单测通过，覆盖 GUI 动作前拒绝错误模式/宿主显示和设备。

Ubuntu 24.04 中实际 `.5 → .6` dpkg 安装/升级、失败配置恢复、卸载保留六组检查通过；升级后的 GUI 完成两次真实软件视频连接、错误密码重试与 worker 回收。维护保护使用私有进程哨兵，不是本轮真实 systemd 升级测试。

## 产物与剩余范围

| 项目 | 值 |
| --- | --- |
| bundle | `Build/Linux/artifacts/farpane-native-dev-532627a818c8f7d0e65df626` |
| manifest SHA-256 | `75755d20ef5912cbd186f8f502857ea3ec9d9957b05fa5f8170438e718038dce` |
| GUI SHA-256 | `cc8f618215193e31ee87c18e93db7534050c1787bca2dca70a1d154bc9dfeb50` |
| 复用 core SHA-256 | `c57fc5dd5755c2caf6e7780d5bf2cc33459b1629949079d2d9eedb17fcf62f6b` |
| Debian 包 | `Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.6_amd64.deb` |
| Debian SHA-256 | `a38580fef4d74b9a42fe1a57b7b880249853ffa48259debf5949c892548507e9` |

本轮未生成 `.6` RPM，也未更新完整 source tar。新 GUI 全部源码、增量构建配方、来源记录和日志随 bundle 的 `source/` 提供；旧 `.3` 完整源码归档不能单独冒充此 GUI 版本的完整对应源码，使用时必须加上本轮变更。正式发布的统一源码归档与 RPM 同步仍待收尾。

新工具条在 X11 软件会话通过，不替代 GPU/真实 GNOME/KDE、Viewer 小窗口/分数缩放、独占确认对话框和实际跨平台验收。保留当前 linux-host `.1`，没有宿主安装、服务/显示变化、commit 或 push。证据见 [原始记录](../../Evidence/LinuxHost/2026-10-18-native-viewer-toolbar/README.md)。

```sh
python3 -B Scripts/linux/build-native-gui-update.py Build/Linux/artifacts/farpane-native-dev-ec305482eaacd98258e28587
python3 -B Scripts/linux/repackage-native-gui.py Build/Linux/artifacts/farpane-native-dev-ec305482eaacd98258e28587 Build/Linux/gui-updates/run-af0ohuw5
python3 -B Scripts/linux/test-native-home-layout.py Build/Linux/artifacts/farpane-native-dev-532627a818c8f7d0e65df626 --viewer-toolbar
```

第一条会创建新的构建目录；第二条的 run 参数须换为对应输出，不覆盖历史构建。下两条是本轮确切产物的复核入口。
