# FarPane Linux GPU 媒体重构（hermes）：旧 crate 的版本与许可文本核对

2026-10-17。本轮核对没有 `.cargo_vcs_info.json` 的四个旧 crate。两个找到完整版本对应关系；它们的许可原文和全部发布源码已经包含在 `.9` 二进制/源码交付中，因此没有重新打包或改变安装包。

| 包 | 固定上游版本依据 | 核对结果 |
| --- | --- | --- |
| dlopen_derive 0.1.4 | rust-dlopen 的 `v0.1.8` 指向 `26b70292744db1052403378d4a01075b6171e3d1`，其中派生宏包为 0.1.4 | 六个发布源码文件全部匹配；MIT 完整文本与现有 dlopen 0.1.8 材料逐字节相同 |
| serial 0.4.0 | `v0.4.0` 指向 `7ed6540c2789b7c7365cd7a89fcb7bac7c567de8` | 六个发布源码文件全部匹配；MIT 完整文本与现有 serial-core 0.4.0 材料逐字节相同 |
| target_build_utils 0.3.1 | `0.3.1` 指向 `7ccd5c913b65fdc1cab1d96814b2e2c8cb432e91` | 九个发布文件匹配，但该提交未找到独立许可文本，README 仅有 ISC/Apache 声明；继续未确认 |
| repng 0.2.2 | manifest 指向 quadrupleslap/repng | 原仓库页面与公开 tags API 返回 404；没有以其他版本或镜像推断原文，继续未确认 |

完整文本分别来自 [rust-dlopen 固定提交](https://raw.githubusercontent.com/szymonwieloch/rust-dlopen/26b70292744db1052403378d4a01075b6171e3d1/LICENSE)和 [serial-rs 固定提交](https://raw.githubusercontent.com/dcuddeback/serial-rs/7ed6540c2789b7c7365cd7a89fcb7bac7c567de8/LICENSE)。不只比较版本号或 `src/lib.rs`：crate 中所有发布文件均按完整字节与 Git tree 的 blob ID 比较。仅排除 Cargo 缓存标记 `.cargo-ok`；存在 `Cargo.toml.orig` 时，以它对应上游 `Cargo.toml`，同时另行固定实际使用的规范化 manifest 哈希。

`Linux/native-published-notices.json` 和 `Linux/notices/published-sources/` 保存包身份、确切提交、完整文件绑定、原始 Git tree 以及既有材料位置。校验入口如下，离线运行，不修改 crate 缓存、二进制或原报告：

```sh
python3 -B Scripts/linux/verify-published-notices.py \
  Build/Linux/artifacts/farpane-native-dev-e7508f297ef1d671172d7737
```

检查还核对 `.9` 的 bundle 身份与应用源码、包内许可原字节、新配套源码归档哈希，以及归档中对应 vendor 的全部发布文件。两份许可的原始 SHA-256 分别为 `062e40ee707f6ab1ca0955624ccfa78d666250a2e821f892705f455cf70dc28a` 和 `871afd9d691846de71e0b83812ba9c7ff00bc7b3ad102dedcaa109f2246d52ad`。没有新增许可正文或改写第三方声明。

这是对冻结报告的补充定位。原 `.9` 材料清单仍保留当时的 26/19 记录；加上本轮两个不重复的定位，总计 28 条完整文本位置跟进，17 条仍无此类跟进。17 条包含七项 manifest 未声明字段和十项完整文本未补齐记录，不等于 17 个包无许可。RustDesk 同仓库的四项 manifest 字段记录已有根 LICENCE 原文；独立的 default_net、hwcodec、hbb_common 不由此推定许可。完整源码/许可发布审核仍为 false。

验证器使用复制到私有临时目录的真实 crate 检查正常来源，以及 manifest 变化、源文件变化、删除/新增文件、符号链接和错误上游 tree 身份的拒绝；七种情况符合预期，原缓存不改动。初次调查脚本命名为 `inspect.py`，与 Python 标准库冲突导致退出；重命名后使用已下载缓存完成检查，初次失败保留。原始 API/tree、匹配报告、拒绝检查和候选未变化证据见[本轮记录](../../Evidence/LinuxHost/2026-10-17-native-published-notices/README.md)。

新增验证器和定位 pin 尚未加入冻结的 `.9` 源码归档，后续实际打包时再纳入；被核对的全部源码与许可正文已经在当前交付中。真实桌面、维护切换和性能验收状态不变。
