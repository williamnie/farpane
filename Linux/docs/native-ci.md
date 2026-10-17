# FarPane Linux GPU 媒体重构（linux-host）：Linux 候选 CI

独立入口 `Scripts/linux/ci-native-source.py` 串联源码校验、公开构建工具准备、原生依赖与应用构建、打包和隔离运行测试。GitHub 手动入口是 `.github/workflows/linux-native.yml`，不修改 Mac 的 `release.yml`。本地复用构建模式已通过；云端完整执行尚未进行，也没有发布 Release。

## 输入与运行

需要普通用户、Python 3.12+、Docker、至少 4 CPU/12 GiB 内存和足够的临时磁盘空间。软件运行夹具要求宿主 Linux 6.5+。资源不足会明确失败；不能假设任意 GitHub runner 都满足要求。首次准备 builder/runtime 镜像和固定工具时需要网络，实际应用编译及运行测试断网。系统包由固定 Ubuntu 基础镜像的发行版仓库提供，不声称所有 apt 包版本或二进制按位复现。

源码输入必须是完整的 FarPane native source snapshot，含 prepared trees、Cargo vendor 和原生依赖源归档。它必须与当前 checkout 的应用源码记录一致。不能以 GitHub 自动生成的普通仓库源码 zip 代替。先按[源码交付](native-source-package.md)生成并审核归档，再使用确切 SHA-256：

```sh
python3 -B Scripts/linux/ci-native-source.py \
  --archive Build/Linux/source-bundles/farpane-native-source-SNAPSHOT.tar.gz \
  --sha256 ARCHIVE_SHA256 --version 0.1.0~ci.YYYYMMDD.N
```

把占位值换为实际值。默认会在新的 `Build/Linux/native-ci/run.*` 下运行，不覆盖旧输出。亦可指定 `--output Build/Linux/native-ci/NEW_RUN`，该目录必须尚不存在。

云端手动 workflow 输入为公开 HTTPS `source_url` 和 `source_sha256`，由 checkout 中的脚本执行完整构建。URL 不接受用户名、密码、查询串或 fragment；下载有大小限制，解包前后分别核对归档哈希和完整文件清单。输入 SHA-256 是内容校验，不是发布者签名；执行者仍须选择可信的完整源码快照。

完整路径依次执行：

1. 构建公开 Ubuntu 24.04 builder 与 runtime 镜像，固定并校验 Rust SDK/vcpkg/CMake 工具。
2. 在独立前缀从源码生成非 FFmpeg 依赖，再从空 Cargo/target 构建 FFmpeg、libdrmtap、headless core 和 GTK4 GUI。
3. 用该次构建结果生成 GUI bundle 及 Debian 候选；依赖 notices 从该次构建源码读取并校验，不依赖 linux-host 旧 checkout。
4. 运行 bundle/工具完整性测试、38 项协议测试、真实软件视频连接及 dpkg 暂存/升级/清理测试。
5. 收集 bundle、Deb、输入源码归档、固定工具/依赖记录、构建结果和 SHA256SUMS。

每阶段记录命令、耗时、退出码及 stdout/stderr 哈希。失败保留本次目录，不自动重试或覆盖它。`deliverables/` 只在全部阶段通过后生成；失败日志位于该次输出根目录。GitHub 始终上传可用日志，成功时额外上传候选文件，保留 14 天。

## 复用已验证构建

本机已有成功源码构建时，可显式跳过媒体/应用重编：

```sh
python3 -B Scripts/linux/ci-native-source.py \
  --archive Build/Linux/source-bundles/farpane-native-source-SNAPSHOT.tar.gz \
  --sha256 ARCHIVE_SHA256 --version 0.1.0~ci.YYYYMMDD.N \
  --reuse-images --runtime-image RUNTIME_IMAGE_ID \
  --reuse-build Build/Linux/native-bootstrap/application.BUILD \
  --reuse-sdk Build/Linux/native-tools/rust-sdk.SDK/sdk --offline-tools
```

此模式重新验证源码构建 receipt、各阶段日志、程序和媒体库以及 SDK 清单。交付快照与原编译快照不同时，还要求其显式绑定相同构建结果，并比较全部 prepared 应用源码。它不会修改既有构建目录。结果明确记录 `full_build_executed_this_run=false`、`validated_build_reused=true`；不能把复用测试说成再次空缓存编译。GitHub workflow 不使用这些复用参数。

## 已完成验证与限制

本地 `run.8cqgimzq` 使用原编译快照 `6464d1ae…`、完成构建 `application.fQLWLQG3` 和公开 SDK `rust-sdk.i5f0jr3s`。11 个阶段全部退出 0：15 项 bundle 测试、5 项工具完整性测试、38 项协议测试、8 类包检查和 6 类 dpkg 检查通过。bundle 与升级后的 Deb 各完成两次实际软件连接、错误密码重试、GTK 呈现及 Viewer 回收。安装升级采用同 artifact 的两个版本号；此前 `.4 → .5` 的不同 artifact 检查另见[源码打包结果](native-source-package.md)。

构建包 `farpane-native-dev-5faded3060b7bdea1fd59d25`、Deb `0.1.0~ci.20261017.1` 仅用于 CI 检查，不替换当前 `.5` 用户候选。测试没有宿主桌面、GPU 或服务挂载，不等同于真实 systemd、硬件视频、性能或长稳验收。后续源码快照与完整证据见[本地 CI 记录](../../Evidence/LinuxHost/2026-10-17-native-ci/README.md)。

Workflow 将 checkout v7.0.1 和 upload-artifact v7.0.2 固定到核对过的官方提交，均使用 Node 24；runner 需支持对应运行时。只授予 `contents: read`，不创建 GitHub Release，不提交、推送或安装应用。新的源码归档收入此独立 Linux workflow 和工具入口，旧 `514e82df…`/`6464d1ae…` 归档保持不变。

正式发布仍需云端执行、完整对应源码/许可审计和产品验收。首页 60 MiB 目标未达到；真实桌面、跨平台、硬件媒体和维护切换门槛保持不变。候选包含 GUI、核心及媒体库，不需要另装 RustDesk 源码或主机 FFmpeg；发行版运行库要求见[候选说明](native-test-candidate.md)。
