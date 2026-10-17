# FarPane Linux GPU 媒体重构（linux-host）：独立原生依赖构建

此入口从已校验的开发源码快照重建非 FFmpeg 原生库，不读取已安装的媒体库，也不改产品构建目录。它是完整源码构建的一个阶段，不等于整个核心、全部工具链或公开 CI 已完成验收。

## 输入和隔离

`Linux/packaging/native-source-builder.Dockerfile` 使用公开 Ubuntu 24.04 基础镜像，安装系统编译和 GUI 开发包。镜像不继承 linux-host 私有 builder；APT 软件包清单保存在镜像内 `/farpane-native-source-builder-packages.txt`。APT 仓库没有固定为历史快照，不能据此宣称按位复现。

重建需要从已核对归档 SHA-256 的源码包解压得到的目录，以及该包 `source-manifest.json` 的 SHA-256。脚本先验证所用 native-dependencies 文件清单、13 个配方的 pin 和 10 份源归档，再运行构建。它不把用户随意提供的清单哈希当作发布者签名。

两个构建工具由同一 vcpkg 源码固定版本和 SHA-512：

- vcpkg 2026-07-27 Linux glibc 可执行文件；pin 位于 `native-dependencies/vcpkg/scripts/vcpkg-tool-metadata.txt`，上游为 `https://github.com/microsoft/vcpkg-tool/releases/download/2026-07-27/vcpkg-glibc`。
- CMake 4.4.0 Linux x86_64 归档；URL 和 pin 位于 `native-dependencies/vcpkg/scripts/vcpkg-tools.json`。Ubuntu 24.04 自带 CMake 3.28 不支持该 vcpkg 所用的 `string(JSON ... STRING_ENCODE)`，不能强行用系统版本替代。

工具可以预下载或复用校验一致的下载缓存；不能用已经编译的应用依赖库代替重建。脚本只读挂载输入，将工具解压/复制到新的 `Build/Linux/native-bootstrap/dependencies.*`，再执行。下载工具和准备镜像需要联网，正式构建使用 `--network none`，4 CPU、12 GiB、普通 UID，不挂宿主服务、凭据、显示或 render 节点。

当前 canonical 的[公开工具链入口](native-build-tools.md)可用 `python3 -B Scripts/linux/prepare-native-tools.py --fetch-only` 获取并核对这两个工具以及 Rust 归档。随后使用 `Build/Linux/native-tools/downloads/` 中的确切文件路径；无需读取旧实验目录的工具缓存。此新增入口不反向加入此前冻结的旧源码归档。

## 执行

从仓库根目录准备镜像。以下是本次使用的资源限制命令；Docker legacy builder 会打印弃用提示：

```sh
DOCKER_BUILDKIT=0 docker build --network default --memory 12g \
  --cpu-period 100000 --cpu-quota 400000 \
  --tag farpane-native-source-builder:ubuntu2404 - \
  < Linux/packaging/native-source-builder.Dockerfile
```

使用自己保存的两个固定工具，调用：

```sh
Scripts/linux/build-native-dependencies.sh \
  Build/Linux/source-bundles/farpane-native-source-6464d1ae0ddf72e154ec4431 \
  6464d1ae0ddf72e154ec4431b91816a75942a7557e00ce243abe89ce3a17aff3 \
  /path/to/vcpkg-glibc /path/to/cmake-4.4.0-linux-x86_64.tar.gz
```

脚本支持第五个参数指定编译镜像，记录其实际 image ID。每次产生新目录，拒绝复用已有工作目录。vcpkg 以 classic 模式只使用已核对的 13 个配方，禁用下载与二进制缓存；不运行 RustDesk 包含旧 FFmpeg/AMF 的 manifest。

本阶段产物位于输出目录的 `work/vcpkg/installed/x64-linux/`。独立 triplet 保留 Rust link scripts 使用的 `lib/` 路径，只构建 Release 库；它不是原缓存的 triplet/ABI，新的 ABI 和库哈希单独记录。FFmpeg 9.0.2、AMF 和 libdrmtap 不属于本阶段，当前产品前缀始终保持原样。

完成后，`result.json` 记录输入、工具、库和 ABI 哈希，`dependencies.log` 保留完整编译过程。CPU 探针验证 Opus 小型 PCM 编解码、libyuv 白色转换值、JPEG 白色像素编解码、AV1/VP9 解码器创建释放和 MFX 无会话错误路径。它不测真实视频质量、GPU 或硬件音频。

入口现在自动生成完整 `installed-manifest.json` 并在结果中报告其哈希，供[完整源码构建](native-source-build.md)验证后消费。该清单函数对此前已完成的 209 个前缀条目核对，字节及 SHA-256 与原留存清单完全一致；没有因此重新编译已有成功依赖。

## 验证进度

公开基础镜像 digest 已通过 registry manifest 查询；Ubuntu 24.04 builder 的实际 image ID 为 `sha256:d0923a2040628a31f2048eb01704030bed22b5ae35e61726378565ff557b710d`。

`Build/Linux/native-bootstrap/dependencies.kZ9vOPIK/result.json` 已通过：14,333 个相关源文件条目、13 个配方和工具 pin 先行核对，断网、空安装前缀、无二进制缓存构建成功，产出 8 个静态库。编译及探针合计约 86.9 秒；上述 CPU 探针全部通过，报告版本为 Opus 1.5.2、AOM 3.14.1、VPX 1.15.2。此耗时不包括镜像准备、输入校验和源码复制，也不是产品构建或运行性能指标。

两次前序失败一并保留：首次使用系统 CMake 3.28，在 `STRING_ENCODE` 处失败；第二次已经完成全部配方，但检查器把 ffnvcodec 的 `debug/lib/pkgconfig/ffnvcodec.pc` 误判为调试库。检查改为拒绝实际调试 `.a` 文件后，最终从另一个空前缀重新完成构建和探针。没有修改上游配方或放宽静态库检查。原始日志、配方 ABI、库哈希和宿主状态见[本轮证据](../../Evidence/LinuxHost/2026-10-17-native-bootstrap/README.md)。

现有 `.4` 二进制和源码归档保持原版本；新增 bootstrap 文件还没有进入那个冻结的源码包。后续[完整空环境媒体/core/GUI 构建](native-source-build.md)及新程序的双发行版隔离软件连接已经通过。公开 Linux workflow、完整许可审计和真实桌面/性能发行验收仍需后续完成。
