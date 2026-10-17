# FarPane Linux GPU 媒体重构（linux-host）：许可文本定位与修正版源码包

分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本轮仅补源码打包工具、文本定位 pin、说明与材料，没有改变已测产品二进制或启停服务。完整发布审计仍未完成。

人工核对在 crc-catalog 2.4.0、enum-map 2.7.3、enum-map-derive 0.17.0 的 `LICENSES/` 及 qrcodegen 1.8.0 的源码头部找到完整许可文本。enum-map 的 SPDX 版权行和原始许可模板一起保留；没有把占位符当成作者信息。另保留声明、上下文及嵌套第三方原文，合计 15 个组件、58 个材料引用。`collection/` 的 60 个原文件（含报告/pin）逐项校验通过。

canonical 实现为 `Linux/packaging/native_notice_supplements.py`、`Linux/native-notice-supplements.json` 和 `Scripts/linux/supplement-native-notices.py`。pin 绑定原始材料报告 SHA-256、确切包 ID/版本、manifest、文件内容与范围。原报告的 45 条记录保留，4 项有完整文本位置补充，其他 41 条没有本轮此类补充；不把计数解释为“无许可”组件。fon/Intel/libwebm 的嵌套文本不替代外层 Rust 包许可，声明/链接也不冒充完整原文。

材料原始生成目录：`Build/Linux/source-audit/native-notice-supplements-99382245be2b4faeafdd843e`，report SHA-256 `99382245be2b4faeafdd843e75b3587722a025f74c47b13deeca04c3273f2d5e`。第一次“所有材料原字节已在旧源码包”的断言失败，定位到 webm/webm-sys 两项引用同一份 `libwebm/LICENSE.TXT`。上游 Cargo `include` 清单未包含该文件；此前 vendor 校验和通过不代表完整许可材料已经交付。该范围和原始检查记录明确保留，没有把初次检查写成通过。

源码生成入口现在将核对后的补充集合放在 `native-dependencies/notice-supplements/`，不改 vendor 的内容或校验和。单独入口检查及实际重新打包均通过。修正版：

`Build/Linux/source-bundles/farpane-native-source-f50df7b05089029e0781590a.tar.gz`

大小 760,973,800 字节；SHA-256 `2d5ea561e6baa96cff73dbae8fa9696e2e5a3323ab0ceaa5121f834d32ebb31c`。包含 88,601 个文件条目、1,082 个 vendor 目录。prepared 产品源码与 vendor 的逐项清单和旧包完全相同；旧归档不修改。

`smoke-run/` 保存 `Build/Linux/native-source-smoke/20261017T031026Z` 原始输出：完整解包校验、core/GUI 离线依赖图、38 项协议测试和完整 GUI Release 编译/组件探测共五项通过。网络关闭，空 Cargo/target，无原工作区或缓存挂载，仅源码包、测试驱动、只读 Rust 1.89.0 SDK 和输出目录；约 4 核/12 GiB。新编译 GUI SHA-256 `18e35ba0926187a7295dd124e5644a146d477eb8ab073e19701ab21ddfccf4de`；没有拿它替换既有候选，也未主张二进制逐字节可重现。

完整 core/原生媒体依赖的全新构建、公共 CI、剩余文本/嵌套代码/对应源码审计、真实桌面/性能验收仍待完成。`complete_license_source_audit=false`、`full_native_media_build=false` 和产品 `runtime_ready=false` 保持不变。FFmpeg 静态库与现有安装、服务 PID 的最终只读状态见 `host-state-final.json`。
