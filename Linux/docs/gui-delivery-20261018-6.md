# FarPane Linux GPU 媒体重构（linux-host）：`.6` 配套交付材料

2026-10-18。带可折叠会话工具条的 `.20261018.6` 现在同时有 Debian、RPM、完整应用源码归档和独立 RPM 包装配方。全部绑定同一个 `farpane-native-dev-532627a818c8f7d0e65df626` bundle，本轮没有重编 GUI、core 或 FFmpeg，也没有安装到 linux-host。

| 文件 | SHA-256 |
| --- | --- |
| `Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.6_amd64.deb` | `a38580fef4d74b9a42fe1a57b7b880249853ffa48259debf5949c892548507e9` |
| `Build/Linux/rpm/farpane-native-candidate-0.1.0~dev.20261018.6-1.fc44.x86_64.rpm` | `11ab42c5f7ce62dc015fdc7d6861e1afd8d14509b9e8bcbc0fe4b96a3062bbe7` |
| `Build/Linux/source-bundles/farpane-native-source-5eeb539adb09e93b49857674.tar.gz` | `33aafd43ed154c8c2436c6c80fe35ec1fb715492ecc4c5dd76b2ad60c97c8cbe` |
| `Build/Linux/source-bundles/farpane-native-rpm-recipe-0.1.0~dev.20261018.6.tar.gz` | `9ce4cb2e7fd80d58a3488889a35a3b294c50e7bddf4c015b26c980e48a6bbd3e` |

应用源码归档为 763,145,746 字节，包含 91,491 个文件/符号链接条目、1,082 个 Cargo vendor 目录和原生依赖源码。源码 manifest SHA-256 为 `5eeb539adb09e93b4985767462a65e4f43a1af44a63f494239eabca7621effb7`。

## 源码同步与检查

`package-native-gui-source.py` 先完整验证冻结 `.3` 源码父归档的目录清单，再用已验证 `.6` bundle 的 GUI 更新 canonical 和 `Build/Linux/gui` 两份源码、native source map、编译记录和配套许可材料。来源记录列出全部 25 个变动路径；其余 core、媒体、vendor 和原生依赖保持原字节。只接受已有 GUI Rust 文件差异，core 二进制、功能清单、协议声明和依赖输入变化均拒绝；四项边界单测通过。

没有读取活动工作区的 `0044`/`paste_target.rs` 来构建归档，并实际核对两者及对应 pin 均不在新快照中。旧完整归档保持原样，新快照有独立身份。GUI 的构建配方、实际日志和增量 receipt 位于 `gui-update/`。

从新压缩包解出后，全部 91,491 条目和源码 hash 通过；候选编译记录、canonical/编译目录逐字节一致。在无网络、无原工作区/编译缓存挂载和空 Cargo home 中，core 666 项与 GUI 71 项依赖全部解析到归档内部。新增 `--metadata-only` 明确跳过编译，默认入口仍执行原有完整 GUI 编译流程。本次不把依赖解析称为全新应用或媒体构建。

既有两项 crate 发布来源/许可文本证明也重新绑定 `.6` 和新快照并通过；原始报告未修改，累计仍为 28 条位置跟进、17 条未关闭记录。该验证器只检查解出的目录；压缩包字节与解包完整性由另一个 source test 验证，两个结果的范围分别保留。

## RPM 与包装配方

Fedora 44 隔离运行环境完成 `.5 → .6` 的七组实际 RPM 安装、显式暂存、升级、维护事务拒绝和移除保留检查；包内 GUI 完成两次真实软件视频连接、错误密码重试与 Viewer 回收。包不会自动启动服务。过程使用私有 Xvfb/D-Bus 与进程哨兵，没有宿主桌面或服务挂载；不是 Fedora 实际内核、SELinux、登录会话或 systemd 激活验收。

RPM 构建入口、spec、README、依赖映射、安装器和固定镜像记录另外保存为 17 份源码的包装配方。`test-native-rpm-recipe.py` 从配方压缩包重新解出，只放入确切冻结 bundle；其容器没有挂载原工作区。在该独立目录重打包的 RPM 与本轮 `.6` SHA-256 一致，证明这份配方足以复现包装步骤。没有据此宣称从源码编译的应用二进制按位复现。

本轮原始证据见 [GUI 交付材料](../../Evidence/LinuxHost/2026-10-18-native-gui-delivery/README.md)。以下入口均只作用于 Build 与隔离容器：

```sh
python3 -B Scripts/linux/package-native-gui-source.py \
  Build/Linux/artifacts/farpane-native-dev-532627a818c8f7d0e65df626 \
  Build/Linux/source-bundles/farpane-native-source-704f37fe999ad9f837832f79 \
  --parent-manifest-sha256 704f37fe999ad9f837832f79b31e242b51e8322651136c0ee6f82b68785b4bc0
Scripts/linux/test-native-source.sh \
  Build/Linux/source-bundles/farpane-native-source-5eeb539adb09e93b49857674.tar.gz \
  33aafd43ed154c8c2436c6c80fe35ec1fb715492ecc4c5dd76b2ad60c97c8cbe --metadata-only
python3 -B Scripts/linux/test-native-rpm-recipe.py \
  'Build/Linux/source-bundles/farpane-native-rpm-recipe-0.1.0~dev.20261018.6.tar.gz' \
  9ce4cb2e7fd80d58a3488889a35a3b294c50e7bddf4c015b26c980e48a6bbd3e
```

生成入口不会覆盖既有同身份快照。重验已有归档使用后两条即可；本轮已通过的检查不需无理由重复。

## 保留的验收范围

Debian 上轮 Ubuntu 24.04 的结果与本轮 RPM/source 检查共同组成此候选的交付材料。新工具条的真实桌面/GPU、Viewer 小窗口与分数缩放、跨平台完整功能、长稳和完整许可发布审计仍未因此通过；没有发布 GitHub Release 或执行云端 workflow。内存优化与应用特判中文输入方案继续暂停。当前安装仍为 `.1`，需以后在获授权的维护窗口切换用户测试包。
