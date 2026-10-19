# FarPane Linux GPU 媒体重构（linux-host）：冻结候选的许可来源复核

2026-10-18。已有 dlopen_derive 0.1.4 和 serial 0.4.0 的完整发布源码与许可原文证明，但旧验证入口绑定 `.9` 候选、当时的补充 pin 和活动构建 receipt。对当前 `.20261018.5` 调用会在 `Existing followup baseline differs` 处退出。这是验证工具的适用范围不足，不代表包内原文丢失，也不能通过删除旧身份检查来解决。

新增显式冻结输入模式，以候选包、完整提取源码快照和预期 manifest SHA-256 为输入。它读取快照中已经保存的两项历史来源证明，再逐项建立与所选候选的对应关系，不读取活动 Cargo 缓存或 `Build/Linux/native-build.json`，不编译暂停中的输入草稿。旧模式及旧 pin/报告仍保留原字节和约束。

## 实际通过的范围

- 候选：`farpane-native-dev-ec305482eaacd98258e28587`，manifest `ea282757ad9874d244c84fac80d72ea8ecf66c9c06126e42d3f29e54cb312db3`。完整 bundle 索引通过原校验器核对。
- 源码：`farpane-native-source-704f37fe999ad9f837832f79`，manifest SHA-256 `704f37fe999ad9f837832f79b31e242b51e8322651136c0ee6f82b68785b4bc0`。全部 **91,478** 个源码条目的内容、大小、可执行位和受限内部符号链接均已核对。
- 快照的编译源码 receipt 与候选 `build.json` 的源码映射一致，映射所列 canonical 文件逐项与快照相符。候选内 notice delivery 原有来源/文件清单验证通过。
- 两个 crate 各六个发布文件均与归档 Git tree 的原始 blob、大小和 SHA-256 一致；Cargo 生成的规范化 manifest 和完整 vendor checksum 也核对。包名、版本、声明与当前候选的依赖清单一致。
- 两份完整 MIT 原文都已在当前候选中，字节、上游 tree 节点和来源 URL 与历史证明一致，无需为这两份正文重打包。

实际运行目录 `Build/Linux/published-notice-checks/run.lh9ntbzr`，命令会话 `81232` 已退出 0。历史模式的失败与冻结模式的成功输出均保留；没有将旧报告的 26/19 改写为新结果。加上两个既有补充后仍是 **28 条文本位置跟进、17 条未跟进记录**，本轮没有新增许可定位或授权结论。17 条包括七项 manifest 字段记录、十项完整文本记录，不等于 17 个组件都没有许可。

## 使用方法

```sh
python3 -B Scripts/linux/verify-published-notices.py \
  Build/Linux/artifacts/farpane-native-dev-ec305482eaacd98258e28587 \
  --source-snapshot Build/Linux/source-bundles/farpane-native-source-704f37fe999ad9f837832f79 \
  --source-manifest-sha256 704f37fe999ad9f837832f79b31e242b51e8322651136c0ee6f82b68785b4bc0
```

两个新增参数必须一起提供。预期 SHA 应取自相应的已记录来源，而不是遇到不一致后重算并当作通过。验证器检查整个提取目录，因此有额外文件、内容变化或编译来源不一致都会拒绝。

```sh
FARPANE_NOTICE_TEST_SNAPSHOT=Build/Linux/source-bundles/farpane-native-source-704f37fe999ad9f837832f79 \
python3 -B -m unittest discover -s Linux/tests -p test_native_published_notices.py -v
```

14 项测试通过、无跳过：包含真实两份 vendor 的原始通过情况，以及修改源文件/manifest、增加/删除源码后重新生成 Cargo 校验值仍被拒绝，缺少 checksum、符号链接和快照 identity/receipt 不一致的拒绝。原始输入只读，变体在 Build 内的临时目录中执行并清理。

本检查不重新核对压缩源码归档字节，不重建程序，不证明 `.5` 桌面包装补充也在原 `.3` 编译快照内；对应的[包装来源链](native-desktop-exec.md)仍单独保留。输出明确为 `source_archive_bytes_verified=false`、`fresh_full_build_verified=false`、`complete_license_source_audit=false`。不能用这两项证明关闭其他依赖、完整许可证/来源审计或 Release 门槛。

新增工具代码和测试仍在 canonical 工作区，尚未加入旧冻结归档；旧归档、候选、已安装 `.1`、ID/密码/服务及 FFmpeg 不变。没有新安装包、提交、推送或发布。原始结果、精确测试源码和验证记录见[本轮证据](../../Evidence/LinuxHost/2026-10-18-native-frozen-notices/README.md)。
