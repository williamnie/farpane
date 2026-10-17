# FarPane Linux GPU 媒体重构（hermes）：独立源码打包交付

本阶段将上一轮完整源码构建的新 core/GTK4 GUI/媒体库，打包为独立 `.5` 候选。新源码归档在没有 Git 工作区、旧产品缓存或网络的容器中，使用自己的入口生成完整 GUI bundle 和 Debian 包。没有重新编译 FFmpeg 或应用，没有安装到 hermes，也没有修改现有服务、显示、身份或密码。

## 来源与实现

编译输入为 `6464d1ae…`，实际构建结果 SHA-256 `c6dbcbaa7ff0866088465a1f178c58760affc85019ea5966cbdaf6476014561b`；原始构建证据见[完整源码构建](../2026-10-17-native-source-build/README.md)。交付输入为 `514e82dfb17b17ebe68927259d81b6d6520e5429a1864d254130baa6dccd244b`，88,621 条。新归档保留完整应用/依赖源码，并加入独立构建/打包入口和根 notices；prepared 应用源码与实际编译目录逐项一致，生成日期文件取自实际编译目录。

`native_package_source.py` 核对原源记录、四阶段成功日志、实际程序/媒体库/四份 FFmpeg 哈希，再生成打包所用 receipt。`--source-build` 显式选择新编译结果，不覆盖原产品 receipt。`source_build` 保存编译来源，`source_origin` 保存交付来源；解压目录不误认外层 Git HEAD，不伪造提交或“干净”状态。`source_head`/`source_dirty` 为 null。

`source-summary.json`、`products.json`、`artifact/build.json` 分别保存来源摘要、输出哈希和完整构建记录；原始大清单仍在冻结源码归档内。源码 manifest 的 `fresh_full_build_verified=false` 表示没有将新归档全部字节再次空环境编译；旧快照的真实完整编译由独立证据绑定，不改写冻结历史。完整许可审计仍 false。

## 实际执行

- 归档打包：`Build/Linux/native-source-package/package.voOsdKkO`，Ubuntu 24.04 public builder `sha256:d0923a2040628a31f2048eb01704030bed22b5ae35e61726378565ff557b710d`。普通 UID、断网、4 CPU/12 GiB、只读源码/编译输入、全新输出，没有宿主服务/显示/音频/GPU/凭据挂载。完整归档校验、两个打包入口、Debian 解包 payload/安装器源码逐项一致。
- Bundle：Ubuntu 24.04 `20261017T051154Z`、Ubuntu 26.04 `20261017T051224Z`，各八类包/私有库检查和两次实际软件视频连接通过。
- GPU：`20261017T051247Z`，限定 renderD128、256×128 静态夹具、虚拟输出 12 fps；两次私有 Wayland 会话完成 VAAPI、DMA-BUF 和 GTK 呈现，没有软件帧回退。86 次现有 FarPane 空闲查询均为零，约 17.25 秒。
- Debian：Ubuntu 24.04 `20261017T051312Z`、Ubuntu 26.04 `20261017T051424Z`，各六类 `.4 → .5` 真实 dpkg 检查通过。测试从原先“同 artifact 只变版本号”扩展为不同 artifact；升级后运行 `.5` 的实际 GUI，两次连接通过，新旧暂存保留。维护事务未结束时的配置失败是预期负向检查，随后配置恢复和 purge 通过。保留进程/服务文件为私有哨兵，没有调用宿主 systemd 激活。
- 15 项既有 bundle 单测通过；真实构建结果加载、canonical 源码变化拒绝和外层 Git 误识别拒绝通过。Python AST/Bash 语法检查通过。

`runtime-summary.json` 绑定五组实际测试与包内程序：GUI `482a3d8d69a31199de48b2d4a368c21101d79a1bb902404223282990f6221cc0`，打包后 core `4e0ac6b78fcc2e630aa52fe2485dc727bd1a5f45c3597e8b3daf970264cf3ced`。原始 core `74ec25af…` 经副本 RPATH 清理形成打包后哈希，原编译二进制不改。软件会话各呈现 1–2 帧，GPU 会话各完成 1 帧，均为短时功能检查，不是帧率或长稳验收。私有夹具 PNG 只留哈希/大小。

所有测试进程成功退出。证据汇总脚本两次读取元数据路径/结构有误，修正后重新核对已有结果，未重跑应用测试；记录在 `aggregation-note.json`。新测试驱动及 Debian 测试扩展在交付归档冻结后产生，保留于 canonical 与本证据，不谎称已包含在该归档。

## 交付与边界

候选 `Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261017.5_amd64.deb`，16,972,476 字节，SHA-256 `0880de6640ee0718762639c84ac97ac86e0cd853c9f3952dc1633047ed684060`。对应 bundle `farpane-native-dev-5ad72a016972fad57d895c5e`，完整归档和源码哈希见 `products.json`。

`logs/host-state.json` 与上一阶段相同：当前仍为旧 FarPane release，FarPane/RustDesk PID、状态及四份旧 FFmpeg `.a` 的大小/mtime/hash 未变；原产品 receipt 有效，旧 `.4` 包未覆盖。无 commit/push/deploy、宿主安装或服务/桌面切换，维护窗口确认仍未收到。

公开 Linux CI、完整第三方许可审计、RPM/其他平台仍未完成。真实 GNOME/KDE/Wayland、systemd/logind、Mac 互操作、硬件音频、1440p/多显示器/颜色/故障长稳与配对性能仍待验收。首页此前 99–106 MiB，60 MiB 目标未过，本阶段未重测该目标。`runtime_ready=false`；本阶段关闭独立打包检查，不关闭完整 GUI/发布验收。

`SHA256SUMS` 为本地证据索引，不是发布者签名。
