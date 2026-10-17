# FarPane Linux GPU 媒体重构（linux-host）：本地 Linux CI 验证

独立 Linux workflow 和可本地执行的完整候选流水线已实现。此阶段使用已通过完整源码编译的 `application.fQLWLQG3`，明确复用应用/媒体及 SDK，验证源码、打包、测试和产物收集的串联。没有再次编译 FFmpeg/core/GUI，没有执行云端 workflow 或发布 Release。用户测试候选仍为 `.5`。

## 实现与实际问题

`Scripts/linux/ci-native-source.py` / `Linux/packaging/native_ci.py` 接受完整源码归档和 SHA-256，验证全清单及应用源码身份。默认路径会准备公开 builder/runtime 与固定工具、从空缓存构建全部依赖/媒体/core/GUI，再生成候选并测试；本地检查通过显式 `--reuse-build` 复用之前已经完成的构建，并记录 `full_build_executed_this_run=false`。

源码路径更新时，要求交付 manifest 绑定同一个实际构建结果，再逐文件验证 prepared 的 core/GUI/native 源码与原编译目录一致。构建记录、阶段日志、程序/库和 SDK 均再次校验。编译输入和交付输入分别记录，不把新文档快照说成重新空缓存编译。

串联时发现 packager 选择独立程序后仍从旧 `Build/Linux/src` 读取依赖 notices。修复后读取该次 `application/workspace` 的源码，并按原编译 manifest 验证 RustDesk、FFmpeg、libdrmtap 三份文本。打包容器刻意不挂载旧 checkout/媒体前缀，实际流程通过。另用临时 metadata 副本逐一修改三份 notice，均被拒绝；原构建前后完整加载通过，详见 `logs/notice-integrity.json`。

`.github/workflows/linux-native.yml` 仅手动触发、`contents: read`，使用固定官方 Actions 提交：

- checkout v7.0.1：`3d3c42e5aac5ba805825da76410c181273ba90b1`。
- upload-artifact v7.0.2：`cf430e030ddbb5b0abf93d22962f4752f3646cd9`。

对应官方 action.yml/README 保存在 `logs/`；YAML、输入字段、Node 24 运行时及提交固定形式已经核对。云端需要满足 4 CPU/12 GiB、Linux 6.5+ 和相应 Actions runner 要求；没有通过本地验证推断任意云端 runner 可用。Mac `release.yml` 未修改。

## 本地流水线

第一轮 `run.8cqgimzq` 输入旧编译归档 `6464d1ae…`，11 个阶段全通过。bundle 为 `farpane-native-dev-5faded3060b7bdea1fd59d25`，Deb 版本 `0.1.0~ci.20261017.1`。运行证据来自 `native-package-smoke/20261017T055438Z` 与 `native-deb-smoke/20261017T055455Z`。

第二轮 `run.3_u9fy_8` 使用下述新归档 `8295fb93…`，通过不同源码 manifest 的构建绑定与 prepared 源码比较，随后同样 11 个阶段全部通过。bundle 为 `farpane-native-dev-a4d03fc41d09a7122cb555fe`，Deb 版本 `0.1.0~ci.20261017.2`；运行证据来自 `native-package-smoke/20261017T060146Z`、`native-deb-smoke/20261017T060203Z`。两轮均明确标记复用构建、非云端执行、未发布。

每轮检查范围包括 15 项 bundle 完整性测试、5 项构建工具完整性测试、38 项协议测试、8 类包运行检查、6 类 dpkg 事务检查。bundle 和升级后的 Deb 各完成两次 loopback 软件视频连接、GTK 呈现、密码错误重试和 Viewer 回收，保留 Host/配置。测试实际程序为 GUI `482a3d8d…`、打包 core `4e0ac6b7…`，与 `.5` 相同；应用源码和原完整构建未改。

dpkg 使用同 artifact 的两个版本号进行暂存、升级、恢复及 purge 检查。不同 artifact 的 `.4 → .5` 测试仍以[前一轮记录](../2026-10-17-native-source-package/README.md)为准。私有保留进程是夹具哨兵，不是真实 systemd 激活；软件短连接不是 GPU、性能、长稳或真实桌面验收。

`runs-summary.json` 汇总每轮输入、产物哈希、运行路径和检查项；`runs/` 保存全部阶段命令、退出码、耗时及原始 stdout/stderr；`runtime/` 保存实际连接事件和内存/加载记录。PNG 不放入本证据目录，只在 `omitted-payloads.json` 记录路径、大小与哈希，原文件留在 Build。未将这些软件测试样本作为首页内存目标验收。

## 新源码交付

新快照 `farpane-native-source-8295fb93c1455505cafbf758` 含 88,635 个条目和 1,082 个 vendor 目录，收入公开工具入口、独立 Linux workflow、流水线和完整打包脚本。归档 SHA-256：`48b636dcb95024117d1043943e82a31642bb9d5f854c818a0951bf67719eb666`。

它绑定实际源码构建结果 `c6dbcbaa7ff0866088465a1f178c58760affc85019ea5966cbdaf6476014561b`，原编译 manifest 仍为 `6464d1ae0ddf72e154ec4431b91816a75942a7557e00ce243abe89ce3a17aff3`。完整来源见 `new-source-snapshot.json`。旧 `514e82df…`、`6464d1ae…` 归档保持冻结；新归档 `fresh_full_build_verified=false`、完整许可审计 false 不改。

## 边界与未验收项

所有本轮应用测试在断网容器、私有 Xvfb/D-Bus 与 loopback 中执行，没有宿主桌面、GPU、服务或凭据挂载。原 FarPane 与 RustDesk 服务 PID/状态、当前 FarPane release、四份产品 FFmpeg 静态库、`.5` 三项交付哈希及旧产品 receipt 均核对保持不变；见 `host-state.json`、`candidate-unchanged.json` 与 `final-check.json`。

未 commit/push/deploy、安装或启动新 GUI；原维护窗口确认仍待用户回复。Claude 的旧评审已在 v2.1 采纳，本轮只读核对已归档记录，没有发消息或唤醒其他代理。

云端完整执行、正式发布许可/对应源码审计、真实桌面和系统服务切换、Mac 互操作、硬件媒体/长稳/配对性能仍未通过。60 MiB 首页目标保持不变且未达到；本轮不改应用或分配器，也未重新测量该目标。`SHA256SUMS` 是本地证据索引，不是发布者签名。
