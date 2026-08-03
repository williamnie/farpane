# 文档索引

本目录集中保存 FarPane 的跨模块设计、调研与验收总结。
仓库根目录只保留项目入口 `README.md`、许可证和分发所需的第三方声明；
模块内 README、Fixture 说明和 Evidence 说明继续与对应代码或原始证据放在一起。

| 文档 | 状态 | 用途 |
| --- | --- | --- |
| [`brand.md`](brand.md) | 已实现规范 | FarPane 命名、Logo、App Icon、透明边缘和内部身份兼容边界 |
| [`architecture.md`](architecture.md) | 已实现基线 | Phase 0–3 的 Core Bridge、VideoToolbox、Metal、输入和打包架构 |
| [`product-ui-design.md`](product-ui-design.md) | 已实现设计 | 连接首页、Keychain 快速连接和全屏悬浮控制器的页面设计 |
| [`research.md`](research.md) | 调研快照 | SlopDesk、RustDesk 原生 Core 接入和第三方 wrapper 的复用边界 |
| [`benchmark-results.md`](benchmark-results.md) | 已验证结果 | Intel MBP Phase 0–3、独占键盘与产品化组合验收的性能、稳定性与限制 |

权威的逐次原始证据、日志、采样和校验清单位于 `../Evidence/`；本文档目录只做
设计说明和结果汇总，不复制或替代原始 Evidence。
