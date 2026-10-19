# FarPane Linux GPU 媒体重构（linux-host）：首次概览图标证据

2026-10-18。复用原始 `.20261018.5` Deb 和 bundle，在无网卡、无宿主桌面/输入/GPU 的独立内核 GNOME 50.1/VKMS 中检查首次概览图标。只开放 `/dev/kvm`，4 vCPU / 6 GiB guest；没有重新编译、打包或安装到宿主。

| 目录 | 磁盘 / 运行目录 | 会话终态 | 对照 |
| --- | --- | --- | --- |
| `immediate-1` | `disk.ygvimiwk` / `run.9k_w2yly` | 93293，0 | 原始入口，首次不额外等待 |
| `settled-2` | `disk.mawias0p` / `run.iq0clvff` | 28717，0 | 首次启动前只等待七秒 |
| `observed-3` | `disk.azy2vyef` / `run.5epbzr6a` | 38273，0 | 不额外等待，启用私有 Shell 观察器 |

三轮各六个启动场景通过，原 desktop SHA 始终为 `11c96d5d77788b6b9304a47a5d6f74f1723cb1117b1179804dafb98d224e2438`，测试没有改入口。共 24 张 PNG 的哈希与 guest 结果匹配，65 份逐轮实际测试源码哈希已核对；第二、三轮 19 项入口保护通过。第一轮是新增等待选项保护前的 18 项。每组保留 command/disk/result、serial、journal、独立启动追踪、实际源码与截图；不复制大体积 guest 磁盘或运行配置/密钥。

图标诊断仍未通过：三组首次 CLI 和随后 D-Bus 的截图均为通用图标，稍后相同 CLI 为 FarPane。四种冷启动均向 Wayland 发送正确 app_id/title。等待七秒没有改善现象。

第三组 `desktop-shell-observer.log` 中，首个窗口先被识别为 `window:1`；32.519 秒已关联 FarPane desktop 和应用图标，但原预览仍引用通用 GIcon。另一个 D-Bus 窗口的预览 GIcon 名称正确，截屏却仍为通用图标；不能只凭 GIcon 名称声称图标已经呈现正确。这两类现象与下一步范围见[诊断说明](../../../Linux/docs/native-desktop-icon.md)。观察器只记录事件与一次合并 idle 采样，不刷新应用索引、主题或窗口关联。

`validation.json` 保存实际通过范围和两个观察到的关联/预览差异；`bundle-check.json` 记录 3,132 项冻结 bundle 校验。启动结果 pass 不代表首次图标修复、真实宿主、其他桌面、GPU、内存预算或中文输入通过。没有新候选、服务切换、提交或推送。按 Warp 应用名特判的中文方案继续暂停。

`SHA256SUMS` 覆盖本目录除该清单自身外的全部文件。之前冷启动/生命周期证据保持原字节。
