# FarPane Linux GPU 媒体重构（linux-host）：图标加载与概览刷新

2026-10-18。冻结 `.20261018.5` 的新增隔离检查确认：包内图标可被 GNOME 的 St 主题接口找到并成功加载；在首次概览保留通用图标时，**同一个 GUI 不退出，只关闭再打开概览，预览便显示 FarPane 标志**。这是已复现问题的影响范围和恢复条件，不是已完成所有桌面的产品修复。

## 两组实际检查

第一组 `disk.kgoombvw/run.f6h9ci2t`（准备会话 `94454`、运行 `2993`）均退出 0。在显式私有 Shell 观察器中增加主题查找/加载诊断：一个主题在安装前初始化，另一个每次截图后创建。两种条件、三次检查都选中用户目录里的 `hicolor/scalable/apps/org.farpane.FarPane.svg`，成功得到 64×51 像素的图像。首次 CLI 概览仍为通用图标，后续 D-Bus 与 CLI 为 FarPane。三个 Shell/VKMS 截图组三组三次比较，共九次 RGB 比较均相同。

该结果验证资源可读、可查找、可解码，但独立主题查找也可能影响共享缓存或加载器状态。因此不能将后续 D-Bus 图标恢复称为修复，也不能声称没有干预 Shell 的所有内部状态。诊断没有访问 Shell 私有主题指针、强制 rescan、改图标路径或修改应用 ID。

第二组 `disk.88dsfh_m/run.pop6p4ka`（准备 `50989`、运行 `12050`）均退出 0。移除安装前的独立主题初始化，并把所有主题查找延后到概览重开截图完成之后。流程为首次 CLI 截图→Escape 关闭概览→Super 重开概览→第二次截图→主题加载诊断；使用的只是独立 guest 的虚拟键盘。

| guest 单调时间 | 同一 GUI PID | 当前应用关联 | 可见预览 GIcon | 实际截图 |
| --- | ---: | --- | --- | --- |
| 45.892 秒，首次概览 | 855 | `org.farpane.FarPane.desktop` | `application-x-executable` | 通用图标 |
| 47.491 秒，重开概览 | 855 | `org.farpane.FarPane.desktop` | `org.farpane.FarPane` | FarPane 标志 |

GUI PID/start ticks、root/Host 代际均未变；包、desktop 与图标字节没有改写。四个截图组共十二次 Shell/VKMS RGB 比较全部一致，原始首次/重开合成器截图已目视核对。主题查找在重开截图之后才执行，随后仍成功读取相同 SVG。因此本组恢复不依赖后加的图标加载探针，也不需要重建应用窗口。

两组各六种启动场景均通过，共 32 张 PNG、21 次 RGB 比较、46 份实际测试源码哈希核对；六项入口保护测试通过。第二组明确保持首次 CLI 窗口，而非把稍后另一个窗口冒充恢复。普通 launch profile 的图片导出上限仍为八张，显式 observer profile 为这组有限检查扩到十八张，每张仍限 1 MiB。

## 结论与下一步边界

已有[应用关联记录](native-desktop-icon.md)表明首个预览在临时应用阶段建立，之后 Shell 关联更新为 FarPane，但预览仍保留通用 GIcon。本轮又证明正常重开概览后，该窗口的预览和实际像素都恢复品牌。无需再把这个样本当作安装包遗漏图标或错误 app_id 的证据。

上游 [StTextureCache](https://raw.githubusercontent.com/GNOME/gnome-shell/50.1/src/st/st-texture-cache.c) 持有自己的主题和纹理缓存；独立 `St.IconTheme` 成功并不能证明此前那次内部查找已成功。本轮没有截获原始内部 lookup/load 调用，因此先前“名称正确、像素仍通用”的第二窗口现象仍不能唯一归因于某项内部缓存。未为此引入绝对图标路径、安装器刷新、等待或 GNOME 特判。

此前 CLI 测试从无交互启动 token 的后台进程启动，GNOME 初始概览始终打开；正常搜索菜单启动、Alt-Tab 与首页品牌已有独立通过记录。这一首次概览残留作为已知桌面限制保留，后续按真实桌面验收复核；不反复修改应用身份或为它扩大无依据的缓存实验。不能把恢复条件当成适用于全部 GNOME/KDE 的产品保证，也不能在用户桌面自动发送按键。

canonical 变更仅为 `desktop-observer.js`、`native_desktop_launch_vm.py`、有界图片导出和截图分析器。没有应用构建、新包、宿主操作或部署。全部会话已终态，无遗留测试容器，linux-host 当前 `.1` 指针未变。内存优化仍暂停；中文按应用快捷键方案仍待讨论，本轮未执行中文/GPU/真实远程连接测试。

原始输入、安装/启动日志、截图、JSON、源码与分析器见[本轮证据](../../Evidence/LinuxHost/2026-10-18-native-icon-theme/README.md)。复现沿用[私有桌面入口](native-desktop-capture.md#复现)，当前 observer profile 会包含上述一次概览关闭/重开；不要将它用于宿主桌面。
