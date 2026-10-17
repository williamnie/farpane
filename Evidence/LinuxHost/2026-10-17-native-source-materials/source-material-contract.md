# FarPane Linux GPU 媒体重构（linux-host）：依赖源码与许可材料清单

`Scripts/linux/audit-native-sources.sh` 在既有隔离容器中离线读取锁定的 Linux Cargo 依赖图，随后在 `Build/Linux/source-audit/` 生成材料清单。它不编译、不联网、不改变核心/GUI/FFmpeg，也不执行安装。生成逻辑保存在 `Linux/packaging/native_sources.py`，不依赖忽略目录中的临时实现。

范围为 core 的 `farpane-native,linux-gpu-media` 和 GUI 当前 feature。遍历非 dev 依赖边，包括构建依赖；同一 package ID 去重。它不是最终二进制逐对象链接清单，不能把选中数量直接当成运行时组件数。每项记录版本、原始来源、上游仓库、manifest、原始 license/license-file 声明、找到的文本以及可用 `.cargo_vcs_info.json`；没有替作者补写许可声明。源码树内的许可证链接解析到同一个源码根，越界链接拒绝。

清单同时保留本项目锁文件、实际 build receipt、FFmpeg 配置与许可文件、libdrmtap 文本、AMF 头文件中的声明，以及缓存原生 port 的版权/SBOM/ABI 材料。缓存的 FFmpeg 和 amd-amf port 信息不用于代表后来独立替换的 FFmpeg 9.0.2、AMF 1.5.2。FFmpeg/AMF 原始下载归档按 canonical pin 重新核对 SHA-256，记录为本地可用；大源码归档不因此自动包含在本清单内。

2026-10-17 首轮实际清单选中 core 648 项、GUI 71 项，合并后 712 项，保留 2,598 份材料及 13 个缓存 port 信息；report 与所有材料的 2,599 个 SHA-256 均核对通过。FFmpeg 实际 `config.h` 声明 `LGPL version 2.1 or later`，`CONFIG_GPL`、`CONFIG_NONFREE`、`CONFIG_VERSION3` 均为 0；这里报告的是构建记录，不是对整套应用许可兼容性的法律结论。

清单列出 45 个待核对记录：7 项 Cargo manifest 没有 license/license-file 声明，38 项未匹配到包或同仓库上级的独立许可文件。它们可以重叠；“未找到独立文件”不等于没有许可。例如 AMF 的声明在头文件，已按实际位置保留；RustDesk 的 Cargo manifest 没有字段，但项目 `LICENCE` 已收集。其他包可能在源文件头、嵌套子组件或固定版本的上游仓库中提供声明，需按来源继续检查。

完整第三方许可/版权材料、精确对应源码交付、原生 port 重建来源、嵌套第三方代码及发布流程尚未完成，`complete_license_source_audit=false`。本清单不擅自推断授权，不把缓存存在当成已向用户交付对应源码，也不将声明缺失自动判为无许可。暂不用于解除 Release 发布门槛。

实际输出：`Build/Linux/source-audit/native-source-audit-22293a4a6d9d7f14c8ca40b6`。其中 `report.json` 给出来源和具体问题，`materials/` 保存已找到的原文，`SHA256SUMS` 用于核对。证据见[材料清单检查点](../../Evidence/LinuxHost/2026-10-17-native-source-materials/README.md)。再次生成同一内容时拒绝覆盖已保存目录，应先检查原结果。
