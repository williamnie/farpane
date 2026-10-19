# FarPane Linux GPU 媒体重构（linux-host）：字体内存实验原始证据

2026-10-18，分支 `codex/linux-host-gpu-media`，HEAD `0b7381291f84637cb5eea557a498aced16ed5dd4`。产品二进制、安装和字体默认未改。解释、边界和复现入口见 [字体内存对照](../../../Linux/docs/home-font-memory.md)。

## 运行记录

| 证据目录 | 原始 Build 目录 | 命令会话 / 退出码 | 含义 |
| --- | --- | --- | --- |
| cold-incomplete | run-7aztrmdl | 66274 / 0 | 初始 CJK-only；无预热/真实排版检查，不作为最终收益或正确性结论 |
| python-bindings-failure | run-157ftur2 | 26112 / 1 | 固定镜像缺少 Python GI 绑定 |
| pango-first-failure | run-_37d9s4u | 31596 / 1 | 实际 Pango 检查发现混排缺字，尚未保存完整排版输出 |
| pango-space-evidence | run-ey3hfkvu | 50997 / 1 | 完整输出确认子集两个字重都缺 U+0020；字形为 0x10000020 |
| warm-1 | run-lkkbg99m | 10486 / 0 | 补齐空格，预热两条件；四个首页、12 次采样、16 项排版检查通过 |
| warm-2 | run-lgsl8vih | 48148 / 0 | 相同方法独立复测通过 |

六轮均使用相同 GUI/core，实际 SHA 在 `validation.json` 和各轮 `run/test-binaries.json`。bundle manifest SHA 为 `ea282757ad9874d244c84fac80d72ea8ecf66c9c06126e42d3f29e54cb312db3`。65 份归档测试源码逐项核对来源哈希；每轮完整命令、固定镜像、只读挂载和限制在 `inputs.json`。全部命令已终态，没有遗留字体测试容器。

## 结果和文件

正式两轮按 A/B/B/A 测量，相邻配对 PSS 减少 11.96/11.16 与 12.89/10.78 MiB；字体映射分别减少 10.98/10.81 与 10.85/10.79 MiB。原字体 PSS 159.61–161.25 MiB，子集 148.36–149.57 MiB。这是软件 GL，不能当作硬件预算或在历史硬件样本上直接相减。

- `warm-*/analysis.json`：最终数值、字体排版宽高、预热记录与明确的验收范围。
- `warm-*/run/home-font-result.json`：原始逐时间点 PSS/USS/字体 PSS/FD/SwapPss。八个正式测量 GUI 均无子进程，FD 10，SwapPss 0。
- `*/run/home-*/`：原始 smaps、rollup、映射汇总及外部 XGetImage 截图；含前序不合格样本。归档共 12 张 PNG，不是用户桌面。
- `warm-*/run/font-shapes.json`：真实 Pango 的字形、文本段、字体哈希和布局。每轮 16 项均无缺字，回退样本序列化排版完全一致。没有发送任何远程中文输入。
- `warm-1/pixel-comparison.json`：同轮首页原字体/子集仍有 20,629 个 RGB 像素不同，不声称产品 UI 逐像素等价。该轮两张首页已目视核对。
- `font-inputs/`：两版 fontconfig/probe/版权原件；字体二进制和原始 TTC 留在 Build，未混入 canonical 源码。生成器与 pin 在各轮 `source/`。
- `glyph-sources/`：提取字形集合时的 GUI 源码，逐项匹配 `probe.json` 哈希，包含注释和测试文本；不是应用新编译的证据。
- `prepare-*.log`、`reproduction.json`：最终 465 码点子集的两次生成逐字节一致；只有 `prepare-1` 属于旧 CJK-only 版本。
- `guard-check.log`：两项单测、12 个拒绝场景及配置/启动前的拒绝检查通过。
- `host-activity-after.json`：只读观察当前 Host 仍有入站；本轮未运行物理 GPU。

本轮没有采用测试用 fontconfig 全局 prepend，也没有新建应用包或修改已安装 `.1`。硬件收益、动态文字/用户字体偏好/缩放、完整页面布局与 60 MiB 目标继续未验收。中文输入的应用特判方案保持暂停。

`SHA256SUMS` 覆盖本目录全部普通文件（除自身）；验证：

```sh
cd Evidence/LinuxHost/2026-10-18-native-home-fonts
sha256sum -c SHA256SUMS
```
