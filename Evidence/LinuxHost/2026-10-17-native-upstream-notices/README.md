# FarPane Linux GPU 媒体重构（hermes）：固定上游许可文本

2026-10-17。基线 `b01c40bd7da588f0ec2add2947a9368289006792`，分支 `codex/linux-host-gpu-media`。本轮补齐源码交付材料，不修改应用或原 `.8` 测试包，不编译、安装或发布。

23 个依赖的原始 Cargo 清单和 `src/lib.rs` 与 crate 自带 VCS 提交的上游文件逐字节相同，下载文件还匹配该提交 Git tree 中的 blob ID。22 个独立许可文件保存在 `Linux/notices/upstream/`；canonical pin 记录来源 URL、提交、SHA-256、Git blob、字节数、源码绑定及适用范围。所有来源固定提交，没有用当前默认分支推断旧版本许可。

其中 22 项补齐完整文本位置，zune-inflate 仅找到 Zlib 完整文本及 MIT/Apache 引用，保持未完成。连同先前四项，原报告 45 条记录中 26 条有完整文本位置补充，19 条尚无；原始报告和问题不改写，不将该计数解释为无许可组件数。fon 原始源码版权行和许可模板同时保留。完整审计仍为 false。

补充集合 `native-notice-supplements-903acbd37dd87bce3d1a121e` 含 32 个组件、100 个材料引用、102 个索引文件。校验器在离线条件核对 VCS 提交、manifest 和源码、许可字节、原 URL 与路径；14 项针对性测试覆盖有效收集、内容变更、错误提交/路径/blob、符号链接和只有声明的误判。检查入口已接入 Linux CI，未声称云端 CI 已运行。

- `collection/`：完整材料、pin、原始问题及新定位报告。
- `upstream/`：原始 Git tree、下载文件、版本绑定及读取日志。来源均为公开上游，不包含浏览器配置或本机凭据。
- `canonical/`：修改的工具、pin、文档、测试及上游文本快照。
- `source-archive-check.json`、`deliverables.json`：新配套源码归档名称/大小/SHA-256和逐项验证范围；旧 `.8` 归档不覆盖。
- `host-state.json`、`final-check.json`：既有程序、服务、FFmpeg 与候选文件未变化及检查结果。
- `SHA256SUMS`：本目录全部其他文件的校验和。

chrome-use 首次只读 URL 成功，另一读取报 `profile_not_open`；没有打开用户浏览器，后续使用公开 HTTP/GitHub 接口。初次 fon 文件名 `LICENSE_MIT` 返回 404，随后依据确切提交的 Git tree 找到 `LICENSE_MIT.txt`，没有把失败响应当文本收集。

新源码包包含本轮材料及后续测试，GUI/core/媒体二进制仍是 `.8`，本轮没有重新冷构建应用。新材料不在旧 `.8` 二进制 bundle 内；完整许可/源码发布审计、真实桌面及内存性能目标仍未完成。详情见[源码材料说明](../../../Linux/docs/native-source-materials.md#固定上游提交补充)。
