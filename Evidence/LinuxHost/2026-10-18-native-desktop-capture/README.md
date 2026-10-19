# FarPane Linux GPU 媒体重构（linux-host）：双路径截图与可见图标

2026-10-18。原始 `.20261018.5`、固定 GNOME 50.1/VKMS 私有 VM。无网卡，宿主只开放 `/dev/kvm`，4 vCPU、6 GiB guest；没有宿主桌面、GPU、输入设备或用户总线。

| 目录 | 磁盘 / 运行 | 终态 | 本组增加的证据 |
| --- | --- | --- | --- |
| `paired-1` | `disk.azbp8xfq` / `run.75k7e1yf` | 会话 84995，0 | VKMS → Shell.Screenshot → VKMS 三组交叉取帧 |
| `visible-2` | `disk.qa88xtq_` / `run.jj0_veaw` | 会话 20984，0 | 同样取帧，并遍历实际 stage 的全部 FarPane 预览 |

两轮各六个启动场景通过，均完成 19 项隔离保护检查。每轮十四张 PNG 的原始哈希与 guest 结果相同；三个场景每组两两比较，共九次 RGB 像素比较全部零差异。合计 28 PNG / 18 比较 / 46 份逐轮实际源码记录核对。`analysis/analyze-native-desktop-captures.py` 是产生 `capture-comparison.json` 的独立分析源码；它不判断图标是否正确，也不将比较通过视为产品验收。

合成器截图已人工查看：首次 CLI、随后 D-Bus、稍后 CLI 图标依次为“通用、通用、FarPane”。第二轮三个截图时刻都只有一个可见且完全不透明的预览，位于 `[480,596]`、大小 `[64,65]`。其中 D-Bus 窗口预览的 GIcon 名称为 FarPane，但两路径都实际画出通用图标。因此不能再把本组现象归因于 VKMS 单独抓到旧图，或把另一个不可见预览当作当前图标；具体主题查找/加载原因仍待查证。

各目录保留原始 serial、命令、result/disk 元数据、Shell/Wayland/启动器日志、PNG、保护检查日志和实际测试源码。`validation.json` 保存限定通过范围和可见预览采样。没有保存大体积 guest 磁盘或运行配置/密钥。测试扩展的截图调用只允许三个固定场景各一次，输出范围和图片数量受限；它没有进入产品包或宿主桌面。

应用、desktop、图标资产及 `.5` Deb/RPM 均未改，没有重新编译或安装。当前宿主指针复查仍为 `farpane-native-dev-bfc1befc221061266d5f50da`。本轮不测中文/GPU/内存，不关闭首次图标或完整 GUI 验收，不提交或推送。详见[结论与复现](../../../Linux/docs/native-desktop-capture.md)。

`SHA256SUMS` 覆盖本目录全部文件（清单自身除外）；上一轮 `2026-10-18-native-desktop-icon` 冻结证据未改。
