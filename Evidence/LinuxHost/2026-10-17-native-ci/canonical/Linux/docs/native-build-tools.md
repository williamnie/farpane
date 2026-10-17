# FarPane Linux GPU 媒体重构（linux-host）：公开工具链入口

原完整源码构建借用了 linux-host 已复制的 Rust SDK。现在可从固定公开归档准备 Rust 1.89.0、vcpkg 和 CMake，不需要旧开发镜像或预先复制 `Build/Linux/toolchain`。这只准备构建工具，不安装应用，也不重新编译已有 FFmpeg。

## 固定输入

`Linux/native-build-tools.lock.json` 锁定 URL、归档名、哈希和下载大小上限，独立于应用源码 receipt，不改变已有候选的编译记录。

- Rust 的 rustc、cargo、rust-std 来自[官方 1.89.0 发布清单](https://static.rust-lang.org/dist/channel-rust-1.89.0.toml)，发布日期 2025-08-07。清单 SHA-256 `fbd1662e100e7b305908ece23b441cb7534eadfa6336c5f173ff08d1cec174a1` 已与官方 checksum 核对，三个 x86_64 Linux 归档分别固定 SHA-256。
- vcpkg 工具版本 2026-07-27、CMake 4.4.0 的 URL/SHA-512 来自已经固定的 vcpkg 源码 `9e593bb18ea69cc5095e012465dcd675a822ed0d` 的工具 metadata。实际下载再次核对，和独立原生依赖构建使用的工具逐项一致。
- Rust/GCC 工具链本身没有从源码编译。本入口只安装官方预编译 Rust SDK；C/C++/GTK 开发依赖仍由[公开 Ubuntu 24.04 builder](native-bootstrap.md)提供。

## 准备与复用

先按 `native-bootstrap.md` 准备公开 builder，然后执行：

```sh
python3 -B Scripts/linux/prepare-native-tools.py
```

下载写入 `Build/Linux/native-tools/downloads/`。哈希不匹配、缓存链接或缺失的离线文件会明确失败，不覆盖或自动修复旧文件。只有下载完整并通过固定哈希，才原子创建正式缓存文件；临时文件由本次调用清理。仅允许 HTTPS，包括跳转后的 URL。

Rust 安装在普通 UID、断网、4 CPU/12 GiB 的容器中执行，输入只读，输出为新建的 `Build/Linux/native-tools/rust-sdk.*/sdk`。安装使用显式 prefix 和 `--disable-ldconfig`；宿主 `/usr`、用户 Rust 环境及旧 SDK 均不变。结果 JSON 给出确切 SDK 路径、下载哈希、版本和包含全部 SDK 文件的 receipt。

后续复用已有输入而不联网或重装：

```sh
python3 -B Scripts/linux/prepare-native-tools.py --offline \
  --reuse-sdk Build/Linux/native-tools/rust-sdk.EXAMPLE/sdk
```

`--fetch-only` 只获取/核对五个工具归档；`--offline --fetch-only` 只核对缓存。`--cache` 必须位于当前源码根的 `Build/` 下。`--image` 可选择自行构建的同用途镜像。复用 SDK 时逐项验证清单，增加、修改文件或越界链接均拒绝，不就地修复。

## 接入应用构建

将结果中的 SDK 路径用于本次调用：

```sh
export FARPANE_NATIVE_RUST_SDK=/path/to/Build/Linux/native-tools/rust-sdk.EXAMPLE/sdk
Scripts/linux/build-native-dependencies.sh SOURCE_DIR MANIFEST_SHA256 \
  Build/Linux/native-tools/downloads/vcpkg-glibc-2026-07-27 \
  Build/Linux/native-tools/downloads/cmake-4.4.0-linux-x86_64.tar.gz
Scripts/linux/build-native-source.sh SOURCE_DIR MANIFEST_SHA256 \
  DEPENDENCIES_DIR PREFIX_MANIFEST_SHA256
```

占位参数需要使用实际验证结果；完整说明见[独立依赖构建](native-bootstrap.md)和[完整应用构建](native-source-build.md)。未设置 `FARPANE_NATIVE_RUST_SDK` 时保留旧路径行为。新构建结果额外记录实际 rustc/cargo 哈希、编译器完整版本和可用的 SDK receipt 哈希；旧冻结构建结果不重写。

源码包 GUI 检查也接受 `FARPANE_NATIVE_RUST_SDK`，并可用 `FARPANE_NATIVE_BUILDER_IMAGE` 显式选择公开 builder。SDK 挂载到 `/toolchain`，与安装时 `/output/sdk` 不同，以实际编译验证可迁移路径。

## 本轮验证

五个工具实际从固定公开 URL 下载，全部哈希一致；`rust-sdk.i5f0jr3s` 安装和离线复用成功，SDK receipt SHA-256 为 `adbd762eb3ea1beb1829d03a4a3f8611ff7a3cde261c1113cd6783e47e98a929`。编译器、Cargo、编译器共享库及目标标准库共 40 个关键文件与旧 SDK 内容相同。

`20261017T052232Z` 使用新 SDK、公开 Ubuntu 24.04 builder、冻结 `514e82df…` 源码归档、全新 Cargo/target，在断网容器中通过全部源码校验、两个离线依赖图、38 项协议测试及完整 GTK4 GUI Release 编译。新 GUI 构建证明 SHA-256 `686759427990833a512426e97129bfbdb399c768d4fe6579267d536812d52e3d`，没有替换 `.5` 产品 GUI，也不声称按位复现。没有重新编译 core/FFmpeg。

五项完整性回归验证了缓存损坏、离线缺件、缓存符号链接、SDK 增改文件及越界链接的拒绝与原文件保留。证据见[公开工具链检查点](../../Evidence/LinuxHost/2026-10-17-native-build-tools/README.md)。

新入口未加入此前冻结的 `514e82df…` 归档，旧归档保持不变。后续[独立 Linux CI](native-ci.md)已接入工具准备并完成本地复用验证，新入口随新源码快照交付。云端执行、完整许可审计、真实桌面与性能验收仍未完成。构建工具可获取，不等于发布已验收。
