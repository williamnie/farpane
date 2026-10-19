# FarPane Linux GPU 媒体重构（linux-host）：首次概览图标

最新补充：[主题加载和同窗口概览刷新](native-icon-theme.md)已证明资源可正常加载；在主动主题探针之前，同一 GUI 只关闭/重开概览即恢复 FarPane 图标，进程不重启。首次残留保留为已知 GNOME 限制，未采用产品 workaround；下文调查方向为历史记录。

后续[双路径取帧与可见预览检查](native-desktop-capture.md)已排除本组 VKMS 取旧画面和观察错预览两种解释：两轮 18 次 RGB 比较完全一致，可见预览名称正确时合成器自身仍显示通用图标。首次图标仍未修复，后续调查转到主题查找/加载；本页三组历史数据与冻结证据保持原状。

2026-10-18。继续核对 `.20261018.5` 冷启动后 GNOME 概览窗口缩略图的通用图标。GUI 已设置 `org.farpane.FarPane` 图标、嵌入 SVG，并使用相同应用 ID；这些源码与冻结候选逐字节一致。不能把此现象归因于没有写图标设置，也没有据此增加应用等待、缓存刷新或桌面特判。

## 相同入口对照

`disk.ygvimiwk/run.9k_w2yly` 的会话 `93293` 已退出 0。原始 `.5` 经实际 dpkg/stage/activate/bind 安装到私有 GNOME 50.1 VM，桌面文件未被测试修改。六个场景均有正确 GUI 总线 owner，并在 16 秒观察期末保留窗口；warm CLI 保留同一 GUI 代际，所有场景的 root/Host 代际相同。

| 顺序 | 启动方式 | 概览缩略图图标（人工查看原始 PNG） | 冷启动 Wayland app_id |
| --- | --- | --- | --- |
| 1 | 首次冷 `gio launch` | 通用图标 | `org.farpane.FarPane` |
| 2 | 冷 D-Bus Activate | 通用图标 | `org.farpane.FarPane` |
| 3 | 同一 CLI 稍后冷启动 | FarPane | `org.farpane.FarPane` |
| 4 | 保持事件循环的 GIO | FarPane | `org.farpane.FarPane` |

四次冷启动都向 compositor 发送了 FarPane 标题。CLI 的追踪来自实际继承的启动器日志，D-Bus 的追踪来自确切 GUI PID 的 journal；总线身份与 Wayland 身份分别核对。后续 warm CLI 和菜单仍在同一回归中验证，但不是本轮四张图标对照的替代证据。第一轮总结果 pass 表示启动条件通过，**不表示首次图标已修好**。

该结果排除了“稍后 GIO 成功只是因为换了启动入口”的单一解释：同一 CLI 入口在稍后也显示正确品牌。仍需区分新安装的应用索引、窗口关联和概览预览更新时序，不能把时间相关性直接当作唯一根因。

第二组 `disk.mawias0p/run.iq0clvff`、会话 `28717` 已退出 0，仅将首次启动前的诊断等待设为七秒。六个启动场景仍通过，四次冷启动身份相同；实际查看首次 CLI、随后 D-Bus 和稍后 CLI 的截图，仍为“通用、通用、FarPane”。因此七秒等待没有修复现象，不能直接套用此前首次菜单搜索的五秒索引延迟解释。这次等待没有进入产品。

## 上游依据与推断边界

GNOME 50.1 的 [ShellWindowTracker](https://raw.githubusercontent.com/GNOME/gnome-shell/50.1/src/shell-window-tracker.c) 尝试按窗口属性和应用索引建立关联，未匹配时创建窗口代表的临时应用；[ShellApp](https://raw.githubusercontent.com/GNOME/gnome-shell/50.1/src/shell-app.c) 对没有 desktop 信息的应用使用通用图标。[ShellAppSystem](https://raw.githubusercontent.com/GNOME/gnome-shell/50.1/src/shell-app-system.c) 在安装索引变化后重新关联部分窗口；[WindowPreview](https://raw.githubusercontent.com/GNOME/gnome-shell/50.1/js/ui/windowPreview.js) 则在构造预览时取得应用并创建图标。

这些源码支持“桌面关联与预览创建存在时序差异”的调查方向。下述第三组随后取得了 Shell 实际关联记录，但没有覆盖内部图标纹理缓存和全部绘制过程，不能据此宣称找到唯一根因。

## Shell 实际关联记录

第三组 `disk.azy2vyef/run.5epbzr6a`、会话 `38273` 已退出 0，显式启用私有观察器，六个启动场景通过。未改变产品、desktop、图标文件或启动次序。39 条事件记录中的 guest 单调时间如下：

- 30.304 秒：首个 GUI PID 839 的窗口 ID 已正确，但 Shell 仍将其作为 `window:1` 临时应用；应用图标与预览图标均为 `application-x-executable`。
- 32.519 秒：同一窗口已关联 `org.farpane.FarPane.desktop`，应用图标变为 `org.farpane.FarPane`，预览仍引用 `application-x-executable`。32.522 秒的 installed 事件记录保留相同差异；46.186 秒截图仍显示通用图标。
- 46.393 秒：后续 D-Bus 窗口 PID 1435 的应用关联与预览 GIcon 名称均正确，但 62.261 秒截屏仍显示通用图标。这不能被前一项旧预览引用单独解释，**GIcon 名称正确不是最终纹理已正确的证据**。
- 62.412 秒：稍后同一 CLI 入口的新窗口 PID 1917 的关联与预览名称正确；78.311 秒截图实际显示 FarPane。

首项已直接观察到“Shell 关联更新后，旧概览预览仍引用通用图标”。后续窗口还存在图标名称与截屏结果不一致的情况，需要用独立的合成器截图/图标加载信息区分主题纹理刷新、呈现及 VKMS 取帧，不能先认定取帧或渲染的某一层有错。本轮没有加入等待、重建窗口、刷新缓存或修改系统 Shell 的产品方案。七秒等待仍属失败对照，不能写成修复。

## 复现与范围

```sh
python3 -B Scripts/linux/prepare-native-input-vm.py \
  Build/Linux/artifacts/farpane-native-dev-ec305482eaacd98258e28587 \
  --stage desktop --maintenance-debs \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.1_amd64.deb' \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.5_amd64.deb' \
  --desktop-launch-probe
python3 -B Scripts/linux/run-native-input-vm.py PREPARED_DISK_DIRECTORY
```

增加 `--desktop-index-settle-seconds 7` 仅让本诊断在首次启动前等待七秒；默认仍为零。该选项现在允许 launch/lifecycle 两个隔离 profile，其余 profile 拒绝；没有进入应用或安装器。本页三组每组最多八张原始 PNG；后续显式 observer profile 为双路径对照扩展到十四张，普通 launch 仍为八张。测试只访问独立 guest 的 VKMS、uinput 和用户总线，宿主只开放 `/dev/kvm`，无网卡或宿主桌面/GPU/输入节点。

`--desktop-shell-observer` 是单独的 launch 诊断选项，在 guest 中安装并启用测试扩展，记录 Shell 当前窗口关联及预览引用的图标。扩展启动前检查独立内核标记、systemd、maintenance/desktop/launch 与显式 observer 标志，日志只写 guest 测试目录；不刷新缓存或重新关联窗口。它使用事件通知和合并后的 idle 采样，最多保存 128 条变化，不安装到宿主或产品包。

原包完整 3,132 项 manifest 已复核。19 项入口保护通过，三组共 18 个启动场景通过，24 张 PNG 和 65 份逐轮实际测试源码哈希核对完成；其中前两组各四次、第三组四次冷启动的 Wayland 身份均正确。图标是人工查看原始图片并结合 Shell 记录作出的诊断，不是启动测试自动验收。应用、核心、FFmpeg、Deb/RPM 和当前安装未改，未执行中文输入方案。原始结果、截图、追踪及每轮实际测试源码见[本轮证据](../../Evidence/LinuxHost/2026-10-18-native-desktop-icon/README.md)。完整 GUI、首次图标、内存与实机验收仍未完成。
