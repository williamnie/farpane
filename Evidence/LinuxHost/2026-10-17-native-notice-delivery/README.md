# FarPane Linux GPU 媒体重构（linux-host）：二进制依赖材料交付

2026-10-17，`codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。新增打包材料，不修改应用行为、构建缓存或服务。完整方案和发布审核仍未通过。

新 bundle 为 `farpane-native-dev-e7508f297ef1d671172d7737`，3095 个文件。tar SHA-256 为 `24ccdd08794dadb88e1af3c0849a85aeda43c4455076318bd7b1504f2da72e54`。

新 Debian 包为 `farpane-native-candidate_0.1.0~dev.20261017.9_amd64.deb`，18,712,024 字节；SHA-256 为 `be0d0fe79b54f5bdda65133824562ce88445d881d80fd4c2856e833019039ad7`。GUI/core/libdrmtap 的输入与打包后字节全部和 `.8` 相同。Deb 完整解包 payload 与 bundle 清单一致；仅解包到 Build，没有执行安装器或产品。

`licenses/dependencies/` 含 2703 个原始清单、许可/版权、补充文本及说明文件，另有顶层 manifest；manifest SHA-256 为 `576d5cc83dbd3db6146ffed7fce11dd1422bd8661a4a4f66dbac0806a7ae86b9`。材料覆盖清单选中的 712 个 Cargo 包和原生依赖，包括构建或非运行组件。原 45 条记录、26 条文本补充及 19 条未补齐记录保持原范围，不修改或推断授权。

新模块 `Linux/packaging/native_notice_delivery.py` 将材料绑定到应用源码 map 与 notice pin，明确原始审计的二进制哈希仅代表原构建。源包内冻结副本可直接用于独立重建后的打包；无需原工作区的 Cargo/审计缓存。Linux CI 打包容器新增相应只读挂载，未运行云 CI。

12 项针对性测试通过。独立源包检查只挂载新源码快照与输出，在断网、普通用户、无原 Git/Cargo 缓存环境中实际导出同一份材料并运行源包自带测试；不代表完整独立编译或整套打包流水线重跑。

- `canonical/`：本轮模块、入口、测试及文档快照。
- `logs/`：单测、打包和导出日志；`runtime/`：独立源码材料导出结果及测试输出。
- `notice-manifest.json`、`notice-report-summary.json`：材料身份和范围。完整原材料此前证据已有，本轮二进制/源码产物也实际携带，不在 Evidence 中重复复制 2703 份。
- `source-archive-check.json`、`deliverables.json`：新源码归档及三个交付文件的完整哈希；旧 `.8` 和上轮源码包保留。
- `final-check.json`、`host-state.json`：逐条归档、源码/二进制不变和宿主状态检查；`SHA256SUMS` 覆盖本目录其他文件。

二进制包中的 `source/` 是打包时快照，配套源码归档另包含随后的测试夹具路径检查和新候选索引；应用源码完全相同。README 明确由根 `manifest.json`/`build.json` 标识包身份，不用嵌入文档中的历史版本代替。

本轮未执行 GUI、Host/Viewer、GPU、安装器或服务操作，没有重复既有视频/输入/DPKG 事务矩阵；程序字节不变不能冒充新一次真实桌面测试。真实维护切换、跨平台/硬件/内存目标、完整许可/源码审核及公开 CI 仍未验收。
