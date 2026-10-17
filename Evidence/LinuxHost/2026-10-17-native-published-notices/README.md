# FarPane Linux GPU 媒体重构（linux-host）：旧 crate 来源补充

2026-10-17，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本轮只增加来源检查和定位证据，不改二进制、候选包、服务或原材料报告。

dlopen_derive 0.1.4 与 serial 0.4.0 各六个发布文件完整匹配固定上游提交，两份 MIT 文本与已收集、已随 `.9` 交付的原文一致。两个包的全部发布源码也在 `.9` 配套源码归档中。没有依据 tag 名称单独推断版本，没有补写版权行或换用其他版本文本。方法、完整提交和原文链接见[核对说明](../../../Linux/docs/published-crate-notices.md)。

target_build_utils 0.3.1 的九个文件匹配固定版本，但其 tree 没有完整许可文本，README 只有声明；repng 原仓库/公开 tags API 返回 404。两项继续未确认。加入本轮只读补充后，累计 28 条完整文本位置跟进，17 条保留（七项 manifest 字段及十项完整文本记录）；不修改冻结的 26/19 报告，不标完整审计通过。

- `canonical/`：只读验证器、pin、原始 Git tree 和说明文档。
- `raw/`：tags/tree、下载的原始许可、匹配绑定、成功输出和第一次失败日志。初次脚本 `inspect.py` 名称遮蔽 Python 标准库；重命名后复用已下载文件完成核对，不计第一次为成功。
- `verification.json`：完整来源、候选中的原许可及配套源码均已交付的核对。
- `rejection-checks.json`：真实 crate 私有副本中的正常与六种错误情况，均符合预期，原缓存未变。
- `deliverables-unchanged.json`、`host-state.json`、`final-check.json`：`.9` 的 tar/Deb/配套源码、程序与服务/FFmpeg 的未变化证据。
- `SHA256SUMS`：本目录其余文件校验和。

没有重新打包、编译、启动 GUI 或安装；完整许可/源码审核、真实桌面、维护窗口和性能门槛仍待完成。新增只读工具不在冻结 `.9` 源码归档中；其检查对象的源码/许可原文已在交付中，后续打包再纳入工具。
