# FarPane Linux GPU 媒体重构（linux-host）：Exec 冷启动与 `.5` 候选

2026-10-18。原 `.3` 冷 `gio launch` 的激活请求未交付，GUI 约 10 秒后退出。canonical desktop 仅将 `DBusActivatable` 改为 false，使用原 Exec；GTK 单实例、应用 ID、图标、显式 D-Bus 服务与 Host 不变。实现、复现和范围见[桌面冷启动说明](../../../Linux/docs/native-desktop-exec.md)。此前 `.3` 的失败及已否决 `.4` 的缓存刷新实验保留在各自证据目录，本目录没有覆盖它们。

## 实际结果

| 目录 | 实际输入与范围 | 结果 |
| --- | --- | --- |
| `comparison-1` | `disk.3trx7uwp/run.z9ihie2y`；原 `.3`，只在 guest 临时改用户 desktop，最后恢复原字节 | CLI、显式 D-Bus、GIO、已有 GUI 的 CLI、GNOME 菜单五种方式通过 |
| `package-2` | `disk.y5iyeiaf/run.q3_wm5la`；`.5` 实际包 dpkg/stage/activate/bind，desktop 原字节未改 | 同五种方式全部通过，16 秒观察及 GUI owner、原 Host 代际核对 |
| `lifecycle-3` | `disk.jej2433i/run.051ng0aa`；实际 `.5`，首次搜索前等待 7 秒 | 七项单实例、Alt-Tab、关闭/重开检查通过；两个 GUI 完整退出，各约 0.130 秒 |
| `debian` | Ubuntu 24.04，`Build/Linux/native-deb-smoke/20261018T122029Z`，`.3 → .5` | 六组真实 dpkg/保留检查，两次软件视频连接与 Viewer 回收通过 |
| `rpm` | Fedora 44，`Build/Linux/native-rpm-smoke/run-v7vb66vj`，`.3 → .5` | 七组 RPM 事务/显式 stage/保留检查，两次软件视频连接与 Viewer 回收通过 |

上述会话 `10407`、`55620`、`23759`、`36209`、`17242` 均已终态退出 0。Deb 包装 `72230`、RPM 包装 `53055` 也已结束。18 项入口保护见 `desktop-exec-guards-4.log`；早期 `guards-1` 的 profile 校验插入位置错误被新保护用例发现，修正后再运行，失败日志保留。

三组 VM 保存实际源码快照、guest 元数据、完整 serial/result、命令、journal、截图和边界日志。CLI 与菜单的两轮截图已查看：CLI 首页在概览缩略图内，不能称为获得键盘焦点；菜单启动正常显示首页。新包生命周期的 Alt-Tab 品牌图标、关闭后与重开首页也已查看。Wayland 追踪在私有会话诊断环境启用，本轮实际采用精确 GUI PID 的 journal；额外支持的 launcher stderr 切片分支未在本轮走到，不宣称该分支已经集成验收。

容器连接测试只归档日志、结果、图像、分项测量及实际源码，不复制合成用户配置或密钥。默认回环模式不调用文字输入用例，未测试或推进暂停中的中文方案。自带的 PSS 数据不作为本轮内存预算或新旧性能比较，VM 的渲染环境也不是硬件 A/B。

## 候选与来源

新 bundle 为 `farpane-native-dev-ec305482eaacd98258e28587`，manifest SHA-256 `ea282757ad9874d244c84fac80d72ea8ecf66c9c06126e42d3f29e54cb312db3`。父 bundle `.3` 的 ID/manifest、160 份编译源码 receipt、GUI/core/媒体哈希保持可核对。`desktop-exec-repackage.json` 列出唯一四项差异；`desktop-exec-repackage-refusal.log` 证明没有精确模板变化时拒绝生成产物。`package-check.json` 核对解包后的 3,132 条 payload 清单、七份安装工具、包大小及暂停草稿未引入。

| 产物 | SHA-256 |
| --- | --- |
| `farpane-native-candidate_0.1.0~dev.20261018.5_amd64.deb` | `ef1ff54fa554e5d0bbfb1d8e0433bc686f3fabcecd6c99f9712c002461d34448` |
| `farpane-native-candidate-0.1.0~dev.20261018.5-1.fc44.x86_64.rpm` | `075c5bbca66816541a18d2fb45b14f2a9c2c41ac4ef2f1b5020c847abd9b3ab7` |
| `farpane-native-desktop-recipe-20261018.5.tar.gz` | `fea0b91195ffa92f4a75d9bbc3e5a0c91c7f8cba6a7003c0514efcb78bc16529` |

产物位于 Build 下的 debian/rpm/source-bundles。`packaging-source/` 与补充配方固定二十份实际包装文件，记录配合使用的 `.3` 完整应用源码归档及其 SHA。它们是入口/包装补充，不是新做的完整 GUI/core/媒体源码重编；不能把旧归档单独宣称为包含新入口。后续 canonical 文档已更新，不应拿新文档覆盖冻结配方再声称重现了相同包。

RPM 构建和实际安装均核对 payload/控制工具；没有事务 scriptlet。Deb 安装仅 stage，RPM 安装只放置候选，两者均保留显式维护 activate/bind 边界。升级/卸载保留测试中的存活对象为私有 shell 哨兵，不等同于真实 systemd 维护中的远程会话。GNOME VM 则使用真实 guest systemd/logind、普通用户和 root/Host，但没有真实远程连接。

## 仍未完成

冷 CLI 可用，但新安装后的概览缩略图下仍显示通用 GTK 图标；搜索、菜单与延迟 7 秒后的 Alt-Tab 品牌图标正常，不能扩大为全部图标位置已通过。即时索引、其他桌面/焦点、实际宿主、完整硬件/内存/长稳与发布许可门槛继续保留。中文方案继续暂停。

没有在宿主安装、stage 或激活 `.5`，没有重编 FFmpeg、修改 Mac/RustDesk、运行物理 GPU 探针或提交/推送。所有测试均为独立 VM/容器，保留已安装 `.1`。完整 GUI 目标继续进行。
