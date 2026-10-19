# FarPane Linux GPU 媒体重构（linux-host）：Viewer 小窗口与缩放

2026-10-19 更新（用户时区；产物沿用 `20261018` 版本序列）。用户接受现有内存水平，继续暂停内存及字体优化，首页 60 MiB 不再作为交付门槛。本轮收尾的是会话窗口布局缺陷，不是内存优化或中文输入修复。

## 缺陷与修改

此前 `.6` 的工具栏采用单行排列。800×600 窗口正常连接时能够容纳，但 Viewer 失败后显示“重新连接”按钮，GTK 将整个窗口自动撑宽到 865 像素；返回首页仍保留这个意外尺寸。

`Linux/gui/src/viewer.rs` 改用 GTK FlowBox，让工具栏随可用宽度换行。常用断开、全屏和工具栏收起入口仍在标题栏；失败时展开工具栏、释放远端按键等原有行为保留。包装控件不额外占用 Tab 焦点，实际按钮保持键盘导航。

只增量编译 GUI Rust 源码，复用冻结 `.5` 的 core、协议和媒体依赖。没有构建活动工作区暂停中的 `0044` / `paste_target.rs` 草稿，也没有重建 FFmpeg。GUI 构建 `run-iq97mg_l` 的九项单测通过，一项既有图形夹具测试按环境要求忽略。

## 回归证据

私有 Xvfb 中，原始 GUI 经认证连接到独立 Host，以真实软件视频和外部输入检查布局；没有挂载宿主桌面、GPU 或输入设备。每个阶段都核对实际窗口尺寸，覆盖认证、出图、收起、展开、Viewer 失败与返回首页。

| 逻辑尺寸 | 缩放 | 实际物理尺寸 | 结果 |
| --- | --- | --- | --- |
| 800×600 | 1× | 800×600 | 九项通过 |
| 1020×720 | 1× | 1020×720 | 九项通过 |
| 800×600 | 2× | 1600×1200 | 十项通过，含 Tab / Shift+Tab |
| 1020×720 | 2× | 2040×1440 | 十项通过，含 Tab / Shift+Tab |

检查包括新帧持续呈现、远端按键释放、布局变化后的鼠标坐标、错误与重试可见、Viewer 回收，以及独立 Host 和身份保留。800×600 收起后画面控件由 369 增至 506 逻辑像素高；1020×720 由 535 增至 626。相关截图已查看。两项隔离入口保护测试、Python 语法和 `git diff --check` 通过。

第一组旧版实验 `run-c1hcptc3` 虽退出 0，但仅记录尺寸，未断言各阶段保持尺寸，不能算布局通过。加强检查后，旧版 `run-oypo2gv2` 在失败阶段以 865×600 明确退出 1；新 GUI 四组均通过。原始失败、精确测试源码、PNG 与几何数据保留在 [本轮证据](../../Evidence/LinuxHost/2026-10-18-native-viewer-layout/README.md)。

## 交付与范围

候选 bundle 为 `Build/Linux/artifacts/farpane-native-dev-58e533b081afae50b9c8e8a5`，manifest SHA-256 为 `fa046ecbdaa03f8af2a458e8d95f5acfc4f839b59653f94ca599e4d575e940f9`。GUI SHA-256 为 `b85f695a5005d9362403d8c074943d99fbfe299e06ff093d73c30e0e647c6661`，复用 core SHA-256 为 `c57fc5dd5755c2caf6e7780d5bf2cc33459b1629949079d2d9eedb17fcf62f6b`。

Debian/RPM 版本为 `0.1.0~dev.20261018.7`，只作为测试候选。

| 产物（均位于 `Build/Linux/`） | SHA-256 |
| --- | --- |
| `debian/farpane-native-candidate_0.1.0~dev.20261018.7_amd64.deb` | `484d93e748b2955dbc01752d92d9390d84754efc97557ebd8c21e841f7da0ff0` |
| `rpm/farpane-native-candidate-0.1.0~dev.20261018.7-1.fc44.x86_64.rpm` | `fa16b542a6a59a3b5a4b24786019081a45364dcb50a3ba7575d077d3d7147f57` |
| `source-bundles/farpane-native-source-d013ab8e2fa2bb25564b0c91.tar.gz` | `dbe0e861a6f1fa966d2b4476a7424be0ad0e6c2acdbe1cc67ea927f37bc9e119` |
| `source-bundles/farpane-native-rpm-recipe-0.1.0~dev.20261018.7.tar.gz` | `b70f5512dd67521de6135260cd19996ec2a84e830125bdc9d6d780bd1279af27` |

Ubuntu 24.04 的六组 dpkg 检查、Fedora 44 的七组 RPM 检查，以及两类安装包各两次软件视频连接通过。升级范围为 `.6 → .7`，维护保护仍使用私有进程哨兵，不是实际 systemd、Fedora 内核或 SELinux 桌面验收。

完整应用源码归档解出后的 91,491 条目、候选编译记录和两份 GUI 源码一致；空 Cargo home、离线且不挂载原仓库/编译缓存时，core 666 项和 GUI 71 项依赖全部来自归档。仅执行 metadata 验证，未重复全新编译。源码 manifest 为 `d013ab8e2fa2bb25564b0c910cc01deae3162d17725c088a25e227f922f337fd`，实际核对不包含暂停的 `0044`、`paste_target.rs` 或对应 pin。

17 份 RPM 包装配方已绑定这次应用归档。包装工具未改，本轮未重复独立配方重打包；此前 `.6` 的按位复现结果不冒充 `.7` 的结果。完整许可来源审计仍有 17 条未关闭记录，候选保持 `runtime_ready=false`。

本轮未安装到 linux-host，没有服务、桌面、显示、ID 或密码变化，也没有 commit/push。当前 `.1` 保留。真实 GNOME/KDE、分数缩放、GPU 与 Mac 互操作不能由这些软件 X11 检查替代；实际中文缺陷及应用特判设计仍待讨论。完整 GUI/发布验收尚未完成。

复核入口（本轮已通过，无需仅为恢复上下文而重跑）：

```sh
python3 -B Scripts/linux/test-native-home-layout.py \
  Build/Linux/artifacts/farpane-native-dev-58e533b081afae50b9c8e8a5 \
  --viewer-toolbar --viewer-size 800x600 --viewer-scale 2
```
