# FarPane Linux GPU 媒体重构（linux-host）：依赖源码与许可材料清单

`Scripts/linux/audit-native-sources.sh` 在既有隔离容器中离线读取锁定的 Linux Cargo 依赖图，随后在 `Build/Linux/source-audit/` 生成材料清单。它不编译、不联网、不改变核心/GUI/FFmpeg，也不执行安装。生成逻辑保存在 `Linux/packaging/native_sources.py`，不依赖忽略目录中的临时实现。

范围为 core 的 `farpane-native,linux-gpu-media` 和 GUI 当前 feature。遍历非 dev 依赖边，包括构建依赖；同一 package ID 去重。它不是最终二进制逐对象链接清单，不能把选中数量直接当成运行时组件数。每项记录版本、原始来源、上游仓库、manifest、原始 license/license-file 声明、找到的文本以及可用 `.cargo_vcs_info.json`；没有替作者补写许可声明。源码树内的许可证链接解析到同一个源码根，越界链接拒绝。

清单同时保留本项目锁文件、实际 build receipt、FFmpeg 配置与许可文件、libdrmtap 文本、AMF 头文件中的声明，以及缓存原生 port 的版权/SBOM/ABI 材料。缓存的 FFmpeg 和 amd-amf port 信息不用于代表后来独立替换的 FFmpeg 9.0.2、AMF 1.5.2。FFmpeg/AMF 原始下载归档按 canonical pin 重新核对 SHA-256，记录为本地可用；大源码归档不因此自动包含在本清单内。

2026-10-17 首轮实际清单选中 core 648 项、GUI 71 项，合并后 712 项，保留 2,598 份材料及 13 个缓存 port 信息；report 与所有材料的 2,599 个 SHA-256 均核对通过。FFmpeg 实际 `config.h` 声明 `LGPL version 2.1 or later`，`CONFIG_GPL`、`CONFIG_NONFREE`、`CONFIG_VERSION3` 均为 0；这里报告的是构建记录，不是对整套应用许可兼容性的法律结论。

清单列出 45 个待核对记录：7 项 Cargo manifest 没有 license/license-file 声明，38 项未匹配到包或同仓库上级的独立许可文件。它们可以重叠；“未找到独立文件”不等于没有许可。例如 AMF 的声明在头文件，已按实际位置保留；RustDesk 的 Cargo manifest 没有字段，但项目 `LICENCE` 已收集。其他包可能在源文件头、嵌套子组件或固定版本的上游仓库中提供声明，需按来源继续检查。

后续[离线源码包](native-source-bundle.md)已经保存固定源码、两个 Cargo 锁文件的 vendor 集合、实际原生 port 配方及源归档，并通过空缓存、断网的完整 GUI 编译。该快照补上源码实体与原生配方来源；全新 native core/媒体重建、完整第三方许可/版权、对应源码义务、嵌套第三方代码及发布流程仍未完成，`complete_license_source_audit=false`。本清单不擅自推断授权，不把缓存存在当成已向用户交付对应源码，也不将声明缺失自动判为无许可。暂不用于解除 Release 发布门槛。

实际输出：`Build/Linux/source-audit/native-source-audit-22293a4a6d9d7f14c8ca40b6`。其中 `report.json` 给出来源和具体问题，`materials/` 保存已找到的原文，`SHA256SUMS` 用于核对。证据见[材料清单检查点](../../Evidence/LinuxHost/2026-10-17-native-source-materials/README.md)。再次生成同一内容时拒绝覆盖已保存目录，应先检查原结果。

## 本地文本定位补充

后续人工核对在 crc-catalog 2.4.0、enum-map 2.7.3、enum-map-derive 0.17.0 的 `LICENSES/` 中找到完整文本，在 qrcodegen 1.8.0 的 `src/lib.rs` 头部找到完整 MIT 文本。enum-map 的许可模板含版权占位符，因此同时保留源码中实际的 SPDX 版权声明；没有用模板替换作者信息。这四项补上文本位置，不等于关闭整套许可审计。

`Linux/native-notice-supplements.json` 固定 15 个组件、58 个原始材料引用的路径、SHA-256、范围和发现；收集入口如下。它绑定原始 report 的哈希及产品 build receipt，逐项验证版本、manifest 和文本，不修改上游声明或此前的报告。完整文件复制保留原字节，不用概括代替许可原文。

```sh
python3 -B Scripts/linux/supplement-native-notices.py \
  Build/Linux/source-audit/native-source-audit-22293a4a6d9d7f14c8ca40b6/report.json
```

生成目录 `Build/Linux/source-audit/native-notice-supplements-99382245be2b4faeafdd843e` 的 60 个文件校验通过。58 个材料引用中，56 个原字节已存在于首份源码包；另外两项引用同一份 libwebm `LICENSE.TXT`，被上游 webm-sys 的 Cargo `include` 列表遗漏。这份文本现已保留，修正版源码包 `f50df7b05089029e0781590a` 自动加入了补充集合，完成 88,601 项解包校验与空缓存 GUI 编译；没有修改旧归档。原报告的 45 条记录完整保留，41 条尚无本轮“完整文本位置”补充。计数包含“manifest 未声明”，不是 41 个无许可组件。

fon、yasna、zune-inflate 的文件头及部分组件 README 只是声明/引用；没有据此填造缺失的完整许可文件。fon 的流处理 BSD 文本、rust-webm 的 libwebm BSD 文本和 hwcodec 的 Intel 头部仅按其嵌套组件范围记录，不能替代外层 Rust 包的许可。default_net、hwcodec、独立 pin 的 hbb_common 等仍需固定版本上游核对，不借 RustDesk 根许可证推断它们全部适用相同授权。原始扫描和材料见[定位补充证据](../../Evidence/LinuxHost/2026-10-17-native-notice-supplements/README.md)。

## 固定上游提交补充

2026-10-17 后续检查从 crate 自带 `.cargo_vcs_info.json` 出发，读取对应上游 Git 提交的许可文件，并比较原始 `Cargo.toml` 与 `src/lib.rs`。23 个包的两份文件均逐字节一致，包括旧 manifest 仍指向 `rustaudio/sample` 的 dasp_sample：实际匹配来源为同一 VCS 提交下的 dasp 仓库。每份下载还与该提交 Git tree 的 blob ID 和大小一致。没有以默认分支或最新版文本替代历史版本。

新保存 22 个独立上游原文，覆盖 42 个包级材料引用。asn1-rs-impl、async-compression/compression-codecs/compression-core、11 个 dasp 包、fon、4 个 phf 包、v4l2-sys-mit 和 yasna 共 22 项补齐完整文本位置；zune-inflate 仅找到完整 Zlib 文本与 MIT/Apache 引用，保持未完成。fon 文本中的版权信息仍由此前收集的实际源码声明补充，不填造作者。

Canonical 文本放在 [Linux/notices/](../notices/README.md)，pin 仍为 `Linux/native-notice-supplements.json`。收集器新增离线校验：crate VCS 提交、两份源码绑定、许可 SHA-256/Git blob、确切路径和 URL；拒绝脏 VCS 标记、内容变化、路径越界、符号链接、只有引用却声明已补齐等情况。14 项针对性检查通过。

当前补充集合为 `native-notice-supplements-903acbd37dd87bce3d1a121e`，32 个组件、100 个材料引用、102 个索引文件。加上先前四项，45 条原始记录中 26 条有完整文本位置补充，19 条仍无此类补充；原始报告及全部问题不改写，`complete_license_source_audit=false`。这关闭的是文件定位缺口，不替代嵌套代码范围、对应源码或正式发布审核。

本次生成新的配套源码归档，包含上述文本、校验工具及后续独立测试。实际名称、SHA-256 与逐条归档核对结果见[上游文本证据](../../Evidence/LinuxHost/2026-10-17-native-upstream-notices/README.md)。原 `.8` GUI/core、bundle、Deb 和旧源码归档保留不变；未重编 FFmpeg、安装或发布，新材料尚不在旧 `.8` 二进制 bundle 中。
