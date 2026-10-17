# FarPane Linux GPU 媒体重构（linux-host）：独占键盘与 .7 候选

2026-10-17，分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。实际复现并修复 `.6` 超时后残留 Wayland 独占请求的问题；新 `.7` GUI 已打包，未安装、未启停宿主服务。

## 产品修复

只有 `Linux/gui/src/viewer_input.rs` 变化：用户请求意图与实际授权分开，保留/清理超时 source；超时、主动取消、桌面撤权、失活及断开都调用 GDK restore。鼠标点击独占按钮不抢走画面焦点，避免取消操作被焦点清理重置后又开启。待确认时间为 15 秒，实际授予后才显示“键盘已独占”。

新 GUI SHA-256 为 `9e57d7b3540b4282bcf23837d2bd05fc082f5da45a729f9d8f0e09a61984a421`。复用核心 raw `b9c87fe3…`、包内 `7c363f0e…`；差别来自原有去 RPATH 打包步骤，核心来源与 `.6` 相同。没有编译核心或 FFmpeg。

## 真实测试及前序结果

| 运行 | 结果 |
| --- | --- |
| `keyboard/20261017T072925Z` | 测试夹具未创建虚拟 pointer，GTK 没收到鼠标能力，未进入连接；补充私有 virtual pointer 后继续，未修改产品解决此项 |
| `keyboard/20261017T073015Z` | 原 `.6` 实际失败：按钮先显示未授权，迟到 `.active()` 仍启用独占；请求没有 `.destroy()`；原始前后截图保留 |
| `keyboard/20261017T073241Z` | 一秒超时的中间修复通过七项；对应 GUI `a88a7577…`，保留其 bundle，不当作最终八项结果 |
| `keyboard/20261017T073523Z` | 最终 15 秒版本八项通过，实际远端匹配 269,216 个像素；超时、延迟正常确认、取消、撤权、旧计时器、失活和断开均检查 |
| `input/20261017T073646Z` | X11 两次真实视频会话、键鼠、中文单次提交/预编辑不外发、工具栏隔离、失活/断开松键通过 |
| `deb26/20261017T073740Z` | Ubuntu 26.04 六类实际 dpkg 检查通过，`.6 → .7` 后两次真实视频连接、worker 回收与 Host 保留 |
| `deb24/20261017T073826Z` | Ubuntu 24.04 同上；容器共用宿主内核，不代表独立发行版内核/真实桌面验收 |

GUI 单测 9 项通过，1 项原有专用图形夹具测试按要求跳过；两次 GUI Release 编译分别对应中间/最终修复。没有为本次无变化的媒体路径重跑 GPU 或冷构建。

## 隔离与证据

私有 Sway/pixman、Xvfb、D-Bus、虚拟键鼠和 screencopy，固定已有测试镜像、4 CPU/12 GiB、network none。原始 GUI 不启用产品 smoke 开关；Sway IPC 实际控制独占授权，并用失败响应确认已撤销的 inhibitor 不存在。物理输入设备、宿主显示/GPU/音频、系统总线和用户配置均未挂载。

`runtime/` 保存上述原始运行和失败；`canonical/` 保存测试及实现；`logs/` 保存构建、打包与校验输出；`before/` 保存旧 receipt/实现/notice 绑定；`deliverables.json` 记录 `.7` tar、Deb、源码归档；`source-archive-check.json` 核对实际 tar 条目与应用源码；`host-state.json` 和 `prior-deliverables-unchanged.json` 记录旧服务、FFmpeg 与 `.6` 交付件不变。`SHA256SUMS` 逐项复核。

新 `.7` Debian 包 SHA-256 为 `809fecd71d5704bc6c77f081570013b91461c7e735996eb16e5cb804f873c5dd`，17,232,020 字节；bundle 为 `farpane-native-dev-dd74b93990400290806487c9`。完整源码归档另行绑定当前 GUI/复用核心；没有宣称本版本新的完整媒体冷构建或按位复现。依赖材料仍为 712 个包、2,598 份材料、45 个待核对记录，仅更新 GUI/构建 receipt 的绑定，不代表完整发布审计完成。

真实 GNOME/KDE 授权对话框、物理快捷键/布局/IME、锁屏、Mac 互操作、GPU 1440p 与长稳、首页 60 MiB 和公开 CI 仍未验收。维护切换尚未获答复；RustDesk、当前 FarPane、线上 hbbs/hbbr 均保持原状，没有 commit/push。
