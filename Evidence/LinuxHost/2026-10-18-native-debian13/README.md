# FarPane Linux GPU 媒体重构（linux-host）：Debian 13 兼容检查证据

分支 `codex/linux-host-gpu-media`，HEAD `0b7381291f84637cb5eea557a498aced16ed5dd4`，包含尚未提交的中文修复。2026-10-18 UTC 执行。只新增 Debian 13 运行镜像、两个测试入口选项和文档/证据，没有改应用、重编、重新打包、安装到 linux-host、提交或推送。

## 被测产物与环境

- Bundle：`farpane-native-dev-67f5d1594e8961809614f4e1`，`artifact-manifest.json` 与 `artifact-build.json` 原样归档。
- 安装输入 `.20261018.1` SHA-256：`9960dfb15c170d66c23677c006f9c37633f4c9ccf47cd72ab0e1809e8fc353e9`。
- 升级输入 `.20261018.2` SHA-256：`986b9c13d94347d88069351f951e1c96ea8abb2701a86c3cbeecb64c4482d148`。
- 实际运行的包内 core SHA-256：`26147ece6e48ce42ae550f0452809227bf7c54ce8a659218a97d80456c424661`；GUI：`9e57d7b3540b4282bcf23837d2bd05fc082f5da45a729f9d8f0e09a61984a421`。
- Debian 13 运行镜像：`sha256:51e070245b4871c7202d3a4e0dabe4fa77b5f4e65a6a6e2845bf2cc5a3313ff4`；官方基础镜像、canonical 测试源码哈希见 `environment.json`，获取/构建日志原样保留。

仅镜像准备联网。两次测试都用 `--network none`、4 CPU/12 GiB/512 PID、私有 D-Bus 和 Xvfb，没有宿主显示、总线、GPU、输入设备或用户配置。容器内安装运行库及 Debian 候选，不安装宿主软件。`os-release.txt` 为 Debian 13/trixie（13.7）；完整运行包版本保存在 `runs/package/runtime-packages.txt`。APT 仓库没有固定历史快照，不承诺镜像按位重建。

## 结果

| 原始运行 | 结果 |
| --- | --- |
| `Build/Linux/native-package-smoke/20261018T070404Z` | 8 项 bundle/ELF/私有库边界检查；9 类会话检查、两次软件视频连接 |
| `Build/Linux/native-deb-smoke/20261018T070439Z` | 6 组真实 dpkg 事务检查；升级后 `.2` payload 的 9 类会话检查、两次软件视频连接 |

四次会话均有实际帧、GTK 呈现确认、错误密码重试和 worker 回收。core/GUI 哈希均匹配 bundle 的 `packaged_binaries`。升级阶段保留旧候选及当前链接；未结束的维护事务阻止自动配置，删除合成事务后 `dpkg --configure` 成功；purge 删除候选工具而保留私有版本、进程、配置和服务文件。没有使用 `--force-depends`。

`runs/` 保留原始结果、dpkg/应用日志、二进制哈希、合成画面截图和进程样本；逐映射内存数据仍在对应 Build 目录。截图仅含私有测试桌面，与用户屏幕无关。`package.log`/`deb.log` 是完整入口输出，`result.json` 是上述实际结果的摘要。第一次归档汇总把 strip 后 core 与 strip 前编译输入直接比较，校验退出；修正为实际包内哈希后通过，没有因此改产品或重跑测试，详见 `aggregation-notes.txt`。

slim 镜像没有 UID 1000 的 passwd 名称项，因此私有 D-Bus 有用户名称查询警告；数字 UID 下全部测试通过，未覆盖真实登录用户的系统集成。保留进程是私有 shell 哨兵，服务文件也是夹具，不能称为实际 systemd 服务升级验收。

## 边界与当前服务

容器共用 linux-host 的 `7.0.0-38-generic` 内核，没有 Debian 内核、真实 GNOME/KDE/Wayland、GPU、音频/密码库/文件全矩阵、跨平台中文或性能验收。首页 60 MiB 和中文实机问题不因本轮通过而关闭。

只读 `runtime-state.json` 确认 linux-host 当前仍为 `farpane-native-dev-bfc1befc221061266d5f50da`，FarPane root PID 64215；RustDesk inactive/disabled，与用户先前手动停止状态一致。`.2` 仍暂存未激活，现有应用构建记录有效。测试入口的复现方式见[Debian 13 说明](../../../Linux/docs/native-debian13.md)。
