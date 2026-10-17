# FarPane Linux GPU 媒体重构（hermes）：反复连接与回收

2026-10-17，使用 `.5` 测试候选的原始 GUI/core，完成同一 GUI 与 Host 的两轮预热和二十轮实际连接、断开。Viewer、软件帧映射和 FD 回收通过，最大空闲 PSS 增量低于 10 MiB。**GUI 末段仍缓慢增长，不能将这个结果解释为已排除持续增长；完整生命周期与内存验收仍未关闭。**

## 实际运行与测量

测试在断网容器中建立两个私有 Xvfb，Host 桌面 640×480，GUI 1020×720、GTK Cairo 软件兼容模式。外部 XTest 点击真实首页、密码验证、断开返回及窗口关闭控件，不启用产品内的 GUI smoke 驱动，不通过内部函数代替用户操作。

每轮连接前更换合成桌面的绿色/紫色色块；通过 GUI 实际 X11 像素检查确认本轮新画面显示，并核对授权连接和独立 Viewer 身份。断开后等待 Viewer 从 `/proc` 消失、Host 入站清空，按同一五秒空闲间隔采样。GUI、Host PID 和窗口一直保持，所有新 Viewer PID 各不相同；没有用重启 GUI 来消除保留状态。

同时采集 PSS、USS、RSS、SwapPss、FD、线程、子进程、完整 smaps/rollup。实际播放时 GUI 存在 `memfd:farpane-frame` 映射，返回首页后该映射归零。最后点击真实窗口关闭按钮，GUI 退出且 Host 保留。未改变产品分配器参数或手工触发 trim；产品原有首页两秒后回收逻辑照常执行。

普通运行 `20261017T061205Z`，约 173.74 秒：

| 项目 | 结果 |
| --- | --- |
| 同一 GUI / Host | PID 66 / 20（容器内 PID） |
| Viewer 创建与回收 | 22 / 22，包含两轮预热 |
| 空闲 FD | GUI 12、Host 40，全部轮次稳定 |
| 预热后最大 GUI PSS 增量 | 1,702 KiB，约 1.66 MiB |
| 预热后最大 Host PSS 增量 | 728 KiB，约 0.71 MiB |
| 最大合计空闲 PSS 增量 | 2,430 KiB，约 2.37 MiB，低于 10 MiB |
| 最后十个采样间的继续增长 | GUI 598 KiB，Host 16 KiB |

GUI PSS 从预热后的 123,190 KiB 到 124,892 KiB，Host 从 181,511 KiB 到 182,239 KiB。它们属于软件兼容夹具；不用于替代 GPU 路径、首页 60 MiB 或完整产品总预算。没有 root 媒体服务、真实合成器增量或硬件缓冲测量，不能将本轮当作方案中的全部进程/显示模式验收。

![普通运行的内存增量与 FD](../../Evidence/LinuxHost/2026-10-17-native-lifecycle/trend.png)

## 未释放对象排查

额外运行 `20261017T061853Z` 使用同一 `.5` 程序，通过单独的测试 preload 库观察公共 GObject 创建接口。观察库只添加弱通知，不额外持有对象引用；只对私有普通用户 GUI 生效，不对 Viewer/core 开启统计。诊断线程和私有 socket 带来额外开销，因此该轮内存不作为产品预算或优化对比。

该轮同样完成两轮预热和二十轮连接。预热后的观察对象为 2,682 个，最后为 2,677 个；最终累计观察 96,840 次创建、94,163 次销毁，计数相符，无容量溢出。没有类型出现净增长，`GdkMemoryTexture` 减少 1、`GtkIconPaintable` 减少 4。GUI FD 固定 13（比普通运行多一个观察 socket），Host 固定 40。

这说明本次公共构造器覆盖范围内，没有看到界面对象随轮次累积；它不是完整堆清单，不能排除非 GObject 分配、未截获构造器、字体/渲染缓存或分配器保留。普通运行 GUI 的 1,702 KiB 增量分解为匿名页 820、堆 816、Noto 粗体文件页 64、X11 共享映射 2 KiB；Host 增量为匿名页。下一步需要实际分配与分配器保留的证据，不能直接断言是缓存，也不为这点增量随意改变分配器默认值。

## 复现

```sh
bash Scripts/linux/test-native-lifecycle.sh \
  Build/Linux/artifacts/farpane-native-dev-5ad72a016972fad57d895c5e 20

# 仅用于对象生命周期诊断，结果不能作为正常产品内存预算
bash Scripts/linux/test-native-lifecycle.sh \
  Build/Linux/artifacts/farpane-native-dev-5ad72a016972fad57d895c5e 20 objects

python3 -B Scripts/linux/analyze-native-lifecycle.py \
  Build/Linux/native-lifecycle-smoke/ORDINARY_RUN \
  --objects Build/Linux/native-lifecycle-smoke/OBJECT_RUN --plot
```

分析图需要 matplotlib；测试容器不依赖它。入口只接受已校验的开发 artifact 和 1/20 个测量轮次，另有两轮预热。布局文件绑定私有 1020×720 夹具；布局变化可先用 `1 calibrate`，检查私有截图后提供坐标。校准不操作用户桌面。代码保留明确超时、失败截图和所有已完成轮次，不自动重试失败的实际连接。

初次观察库编译因 GObject API 返回类型声明错误失败，未启动 GUI；修正为本地头文件定义的 `GObject *` 后，`-Wall -Wextra -Werror` 编译与完整运行通过。该失败是诊断工具问题，没有修改产品二进制。

本轮仅增加测试与分析入口，未重新构建 FFmpeg、core 或 GUI；`.5` bundle/Deb、旧源码归档和现有安装保持不变。新测试入口生成于 `8295fb93…` 源码归档之后，不能声称旧归档已包含它们。

完整证据见[生命周期检查记录](../../Evidence/LinuxHost/2026-10-17-native-lifecycle/README.md)。GPU 租约/fence、真实桌面、30 分钟/24 小时长稳、多种功能并发及持续内存增长排查仍未完成；首页 60 MiB 门槛保持不变。
