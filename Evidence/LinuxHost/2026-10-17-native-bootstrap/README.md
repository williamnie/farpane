# FarPane Linux GPU 媒体重构（hermes）：独立依赖构建证据

本阶段完成非 FFmpeg 原生依赖从固定源码重建，不替换 `.4` 候选，不声明完整空环境核心、GUI 性能或正式发布验收通过。使用 `codex/linux-host-gpu-media`、HEAD `b01c40bd7da588f0ec2add2947a9368289006792`，未提交、发布或切换服务。

## 输入和实际执行

- 已冻结的 `farpane-native-source-6464d1ae0ddf72e154ec4431` 源码快照；manifest SHA-256 `6464d1ae0ddf72e154ec4431b91816a75942a7557e00ce243abe89ce3a17aff3`。使用前核对 14,333 个相关源条目、13 个 port 和 10 份源归档。
- Ubuntu 24.04 公开基础镜像 digest 已向 registry 查询。新 builder `sha256:d0923a2040628a31f2048eb01704030bed22b5ae35e61726378565ff557b710d` 从该基础镜像和 APT 开发包构建；包版本和 registry manifest 留存。APT 未固定历史快照，非按位复现声明。
- vcpkg 2026-07-27、CMake 4.4.0 的工具二进制复用只读下载缓存，分别匹配同一 vcpkg 固定源码给出的 SHA-512。没有从该缓存读取应用静态库，也没有运行旧实验脚本。两个工具由入口复制/解压后在新的输出目录执行。
- 普通 UID、`--network none --cpus 4 --memory 12g --pids-limit 512`；无 GPU、宿主显示、服务 socket、凭据或旧安装前缀挂载。classic 模式、固定配方根、禁用下载和二进制缓存。独立 Release triplet 与原缓存 ABI 分开记录。

## 成功范围

`runs/final/result.json` 对应 `Build/Linux/native-bootstrap/dependencies.kZ9vOPIK`：13 个配方完成，产生 AOM、JPEG、TurboJPEG、MFX、Opus、pkgconf、VPX、libyuv 共 8 个静态库，及 ffnvcodec 头文件/编译辅助工具。完整编译和探针约 86.9 秒，不包含镜像准备、源码复制/核验，不代表应用性能。

`probe.log` 验证真实新库的 Opus 小型 PCM 编解码、libyuv 白色像素转换值、JPEG 白色图编解码、AV1/VP9 解码器创建/释放、MFX 无会话返回。没有实际 AV1/VP9 帧编解码、硬件音频或 GPU 测试。报告版本为 Opus 1.5.2、AOM 3.14.1、VPX 1.15.2。

`installed-manifest.json` 列出新前缀 209 个文件/链接；`installed-share/` 保留 ABI、许可证、SBOM 和编译配置。完整静态库和中间产物留在 Build，未复制进 Evidence。`canonical/` 冻结本次入口与探针，`canonical-inputs.json` 绑定它们的哈希。

## 失败与修正

1. 镜像命令首次同时给了 stdin Dockerfile 和 `--file`，Docker 拒绝执行；修正命令后镜像成功。原日志保留。
2. `runs/system-cmake/`：先强制使用 Ubuntu 自带 CMake 3.28，AOM 配方通过 vcpkg 的 SPDX helper 调用 `STRING_ENCODE` 时失败。改用固定 SHA-512 的 CMake 4.4，不改上游配方。
3. `runs/debug-metadata/`：全部配方已经编译成功，但检查器把 header-only ffnvcodec 配方留下的 `debug/lib/pkgconfig/ffnvcodec.pc` 当作调试库。改为检查实际调试 `.a` 后，从另一个空前缀完成最终构建及探针。没有将失败轮次改记为整套通过。

## 保持不变和未验收

`host-state.json` 与上一 RGBA 阶段完全一致：已安装 FarPane current、FarPane/RustDesk PID 和服务状态、四份现有 FFmpeg 静态库的大小/mtime/hash 均未变。当前产品构建 receipt 仍有效。没有宿主安装、桌面/显示/密钥/密码/网络修改，没有 commit/push/deploy。

新增 bootstrap 代码尚未进入冻结 `.4` 源码归档。完整 FFmpeg/AMF/libdrmtap/core 空环境构建、公开 Linux CI、完整许可发布审计、真实桌面与性能验收仍未完成；首页 60 MiB 目标此前未通过，本阶段没有重新测量。维护窗口仍待确认，不以此依赖构建代替用户实际连接测试。

文件完整性由 `SHA256SUMS` 逐项校验；该清单是本地证据索引，不是发布者签名。
