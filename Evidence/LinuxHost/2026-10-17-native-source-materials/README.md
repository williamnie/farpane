# FarPane Linux GPU 媒体重构（hermes）：依赖材料归集检查点

分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本阶段实现并执行材料归集，**完整许可/对应源码审计仍未完成**。没有编译、安装、发布或修改服务。

canonical 实现为 `Linux/packaging/native_sources.py` 和 `Scripts/linux/audit-native-sources.{sh,py}`。既有容器离线、locked、按 x86_64 Linux 解析 core/GUI 依赖；实际 build receipt 核对确保当前 canonical 编译源码和二进制未变。只遍历非 dev 依赖边，包含构建依赖，不把这个图冒充精确链接清单。

实际结果：core 648 项、GUI 71 项，合并 712 个 package ID；收集 2,598 份 manifest、声明、文本、VCS/锁文件/构建记录与原生材料，另有 report，共 2,599 个 SHA-256 逐项核对通过。13 个缓存原生 port 的版权/SBOM/ABI 文件一并保留。生成目录：

`Build/Linux/source-audit/native-source-audit-22293a4a6d9d7f14c8ca40b6`

report SHA-256：`22293a4a6d9d7f14c8ca40b60b24bef1983652fe8877dd79a47102f64b5cf1a8`。

FFmpeg 实际配置声明为 LGPL 2.1 or later，GPL/nonfree/version3 为 0；9.0.2 和 AMF 1.5.2 原始归档哈希与 canonical pin 一致。旧缓存的 FFmpeg/amd-amf port 材料被排除，以免代表后来独立替换的版本。AMF 原文位于 Factory.h 头部，已保存该文件，未编造不存在的顶层许可证。

45 个待检查记录分为 7 项缺少 Cargo manifest 许可字段、38 项未匹配独立文本；可重叠。这不是 45 个“无许可组件”。RustDesk 本身虽无 manifest 字段但有项目 LICENCE；其他包的头部、嵌套子组件和固定版本上游仍需核对。没有推断新的 SPDX 声明或法律许可结论。

第一次归集遇到 x11-rs 同仓库内的 LICENSE-MIT 符号链接，被最初实现拒绝。修正为解析后严格限制在同一源码根，最终所有材料核对通过。中间一次完整报告保留在 Build，仍包含错误预期的 AMF 顶层 LICENSE.txt 查找；最终实现改为保留真实头部文本，最终报告不再有该记录。

本归档保存最终 report、其完整文件校验索引、运行日志、合同和 319 个 canonical 文件哈希；材料原文保留在 Build 的生成目录，生成入口与 pin 在仓库内。尚未交付完整第三方源码归档、所有嵌套版权文本、原生 port 对应重建材料或可发布许可证集合；`complete_license_source_audit=false` 保持不变。独立 Debian 候选包及此前媒体/GUI 二进制未因此重打包或改变。
