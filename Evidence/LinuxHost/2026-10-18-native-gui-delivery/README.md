# FarPane Linux GPU 媒体重构（linux-host）：`.6` 交付材料原始记录

2026-10-18。结果和产物哈希见 [交付说明](../../../Linux/docs/gui-delivery-20261018-6.md)。

- `source-packaging/`：完整应用源码派生的命令、日志、结果，压缩包验证和许可来源复核；原运行 `gui-source-packaging/run-gc0gq9o8`。
- `source-snapshot/`：新快照完整 manifest、二进制构建绑定和 GUI 来源说明，不复制 3.2 GB 的解压源码或生成二进制到证据目录。
- `source-check/`：压缩包解出后全部条目检查、candidate/canonical/prepared 一致性，以及空 Cargo home 离线 metadata 的原始 stdout/stderr；`native-source-smoke/20261018T144451Z`。
- `rpm-package.json`：`.6` RPM 实际包装输出及精确 installer 源码哈希。首次包装 stdout 在工具记录中，没有伪造日志。
- `rpm-check/`：`native-rpm-smoke/run-qlqz0o5o`，七组包事务及两次实际软件连接通过，exit 0。D-Bus 的容器 UID 查询警告原样保留。
- `rpm-recipe/`：17 份包装输入、配方和说明，与配方压缩包对应。
- `recipe-check/`：`rpm-recipe-check/run-un_i8hhs` 的命令、完整重复包装日志及结果；生成 RPM 与首次包 hash 一致，原工作区未挂载。
- `canonical/`：本轮归档、验证入口和四项来源边界测试；Python 单测 stdout 只在工具记录中。
- `validation.json`：所有产物和主要结果的索引。

本轮没有编译应用或 FFmpeg，没有运行硬件 GPU/用户桌面测试，也没有安装、切换服务、提交、推送或发布。完整来源核对不意味着许可审计已完成，17 条记录仍开放；中文与内存暂停范围保持不变。所有本轮命令已终态，无待续句柄。
