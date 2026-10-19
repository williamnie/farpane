# FarPane Linux GPU 媒体重构（linux-host）：概览图标与双路径取帧

后续[图标主题与概览刷新](native-icon-theme.md)已取得资源加载成功和同窗口重开概览恢复品牌的证据。当前显式 observer profile 导出上限为十八张，增加一次有界概览关闭/重开；本页两组原始十四张数据不变。

2026-10-18。[上一轮图标诊断](native-desktop-icon.md)发现某个预览的 GIcon 名称正确，但 VKMS 截图仍显示通用图标。本轮使用 GNOME 合成器自身截图交叉验证，保持 `.20261018.5` 应用、desktop 和图标文件不变。

## 先核对实际像素

第一组 `disk.azbp8xfq/run.75k7e1yf`、会话 `84995` 已退出 0。六个启动场景通过，在首次 CLI、随后 D-Bus、稍后相同 CLI 三个场景分别执行：

1. 原 `libdrmtap` 从 guest VKMS 取得画面。
2. 同一 guest 的 `Shell.Screenshot` 直接输出整个合成器画面，不含鼠标、不闪屏。
3. 再次从 VKMS 取得画面。

三组三张图片解码为 RGB 后，每组两两逐像素一致，九次比较的差异像素数均为零，分辨率均为 1024×768。VKMS 前后 framebuffer ID 分别保持 55、55、57。实际查看合成器截图，前三个场景的窗口图标依次是“通用、通用、FarPane”。这排除了本组现象由 VKMS/映射取帧单独返回旧画面造成的解释；不扩大为所有驱动、动态帧或硬件捕获验收。

比较入口为 `Scripts/linux/analyze-native-desktop-captures.py`。它先校验独立内核/无宿主桌面/断网结果、选定三个场景及 PNG 原始 SHA，再比较有界图片的解码像素；不以 PNG 文件字节相同为前提。输出明确保留 `icon_correctness_evaluated=false` 和 `product_acceptance=false`，图像一致不代表图标正确。

## 再核对可见预览

第二组 `disk.qa88xtq_/run.jj0_veaw`、会话 `20984` 已退出 0。新增 stage 树的有界遍历，记录同一窗口的所有预览，避免只依赖 `MetaWindow._delegate`。遍历仅观察现有 actor，不创建、替换或重画图标；最多访问 10,000 个节点，观察日志最多导出 200,000 字节。

42 条观察记录中，三次截图时均只有一个可见、mapped、完全不透明的 FarPane 预览图标，位置 `[480,596]`、尺寸 `[64,65]`，对应实际截图的图标区域：

| 场景 / guest 单调时间 | Shell 应用图标 | 可见预览 GIcon | 合成器与 VKMS 实际像素 |
| --- | --- | --- | --- |
| CLI / 46.469 秒 | FarPane | 通用图标 | 通用图标，两路径一致 |
| D-Bus / 62.685 秒 | FarPane | FarPane | 通用图标，两路径一致 |
| 稍后 CLI / 78.917 秒 | FarPane | FarPane | FarPane，两路径一致 |

第二组九次比较也均为零差异，六个启动场景通过。至此，本组现象既不是 VKMS 单独取旧画面，也不是前轮仅观察到了另一个不可见预览；没有理由据此修改 FarPane app_id 或媒体捕获实现。

GNOME 50.1 的 [StIcon 实现](https://raw.githubusercontent.com/GNOME/gnome-shell/50.1/src/st/st-icon.c) 在目标 GIcon 加载失败时会加载 fallback，GIcon 属性本身仍保留原值。这为“名称正确、显示通用图标”提供了明确可检查的路径，但尚未记录本次具体查找/加载失败的调用，不能声称已定位唯一缓存缺陷。下一步应检查实际主题查找和加载结果，再决定是否需要包装修正；不能将等待、刷新或绝对图标路径直接作为已验证修复。

## 诊断边界

测试扩展只在明确的 private desktop/maintenance/launch/observer 标记和独立内核下启用。截图方法只允许 `cli`、`dbus`、`cli-late` 各一次，拒绝并发或任意文件名，以独占创建方式写 guest 测试目录；通过当前 guest 的用户总线调用。没有宿主总线或桌面访问，没有产品扩展、缓存刷新、窗口重建或服务切换。

Shell API 来自固定运行镜像的 `Shell-18.typelib`，实际 `screenshot(include_cursor, stream, callback)` / `screenshot_finish` 已在 GNOME 中执行。最初只读接口查询使用了错误 typelib 路径，后按镜像实际 `/usr/lib/gnome-shell` 和 `mutter-18` 路径查询成功；没有安装任何宿主依赖。

普通 launch profile 仍最多导出八张 PNG；显式 observer profile 增加三个有界 Shell/VKMS 对照，最多十四张，每张仍限 1 MiB。全组维持 4 vCPU、6 GiB guest、无网卡、仅开放 `/dev/kvm`，没有物理 GPU 或中文输入测试。19 项隔离入口检查通过。

## 复现

```sh
python3 -B Scripts/linux/prepare-native-input-vm.py \
  Build/Linux/artifacts/farpane-native-dev-ec305482eaacd98258e28587 \
  --stage desktop --maintenance-debs \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.1_amd64.deb' \
  'Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.5_amd64.deb' \
  --desktop-launch-probe --desktop-shell-observer
python3 -B Scripts/linux/run-native-input-vm.py PREPARED_DISK_DIRECTORY
python3 -B Scripts/linux/analyze-native-desktop-captures.py RUN_DIRECTORY
```

两轮共 28 张 PNG、18 次逐像素比较、46 份逐轮测试源码和独立比较脚本均已留存核对。原始截图、配对比较、测试源码、Shell 关联日志和结果在[本轮证据](../../Evidence/LinuxHost/2026-10-18-native-desktop-capture/README.md)。当前 `.5` 包未改变，首次概览图标仍未修复，内存与完整 GUI/实机门槛不因此通过；按 Warp 应用名特判的中文方案继续暂停。
