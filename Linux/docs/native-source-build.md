# FarPane Linux GPU 媒体重构（hermes）：完整源码构建

此入口在独立目录中编译媒体库、原生核心和 GTK4 GUI，用来验证开发源码快照的可构建性。它不安装程序、不修改 `.4` 候选，也不访问正在运行的 FarPane/RustDesk。真实桌面、GPU 质量/性能、安装和正式发布验收另行记录。

## 前置输入

1. 已核对归档哈希的完整源码快照，以及其中 `source-manifest.json` 的 SHA-256。源码、patch、vendor 和下载归档都来自该快照。
2. [独立依赖构建](native-bootstrap.md)的成功输出目录。入口验证完整 `installed-manifest.json`，要求该输出对应同一源码快照、空安装前缀、未用二进制缓存。新依赖入口自动生成此清单并报告其哈希；此前已完成的前缀用同一函数核对，未因此重新编译库。
3. `farpane-native-source-builder:ubuntu2404` 编译镜像，以及标准 Rust 1.89.0 SDK（`bin/rustc`、`bin/cargo`、标准库等）。可用[公开工具链入口](native-build-tools.md)准备 SDK，并设置 `FARPANE_NATIVE_RUST_SDK` 为结果路径；不设置时保留 `Build/Linux/toolchain/` 默认值。SDK 只读挂载；本阶段编译应用和媒体依赖，不编译 Rust/GCC 工具链本身。镜像制作方法见上面的依赖文档。

编译容器使用普通 UID、4 CPU、12 GiB、`--network none`。不挂原产品前缀、Cargo 缓存、host 桌面/服务/音频/GPU 或凭据。所有源码先逐项校验，再复制到新的 `Build/Linux/native-bootstrap/application.*/workspace`，不是 Git worktree。编译输出和 Cargo home 初始为空。

## 执行和产物

```sh
Scripts/linux/build-native-source.sh \
  Build/Linux/source-bundles/farpane-native-source-6464d1ae0ddf72e154ec4431 \
  6464d1ae0ddf72e154ec4431b91816a75942a7557e00ce243abe89ce3a17aff3 \
  Build/Linux/native-bootstrap/dependencies.kZ9vOPIK \
  80d5c1ed47b3c31ddc4c91d2821969fb3d160cbdc72009092d64e3052e5556ad
```

第五个参数可指定编译镜像。入口逐项核对源码和新依赖文件，复制新依赖前缀，展开固定 AMF 头文件及 Meson wheel，然后按顺序执行：

- 快照内的 `build-ffmpeg.sh`，在新前缀编译 FFmpeg 9.0.2；原成功 FFmpeg 产物不挂载、不覆盖。
- `build-drmtap.sh`，编译私有 libdrmtap，检查版本、EGL 实现及 helper 禁用。
- `build-native-core.sh release`，锁定、断网、`farpane-native,linux-gpu-media`，关闭默认旧 UI feature。
- GTK4 GUI Release 编译，随后检查两个程序的 `--build-info`、协议一致性、实际 ELF 动态依赖和库解析。

输出目录中的 `active-stage.json`、各阶段 `.log` 和 `stages.json` 保存当前步骤及结果。只有全部阶段通过才生成成功 `result.json`；它记录两个程序、四份 FFmpeg 静态库及 libdrmtap 的实际哈希。程序位于 `workspace/Build/Linux/source-target/release/`，不是可直接替换已安装 release 的包。

新入口同时记录实际 rustc/cargo 的哈希、完整编译器版本和 SDK receipt（若存在）。旧成功 `result.json` 保持冻结，不为补充新字段而重编或改写。

失败目录保留用于定位；不要删除现有候选、反复重建已通过的媒体库或假定超时代表进程已结束。继续处理失败时，先核对具体进程/阶段和日志。若四个编译阶段都已成功、只是最终汇总失败，可在第五个镜像参数之后添加第六个参数（原输出目录），只重新验证。此模式要求同一镜像 ID、四个成功阶段及日志哈希一致，并核对所有原输入仍相同；仅允许上游构建脚本重写的 `src/version.rs`。不会执行任何编译，也不能覆盖已有成功结果。

## 隔离运行验证

完整构建成功后，可以用现有真实连接夹具检查新二进制：

```sh
Scripts/linux/test-native-source-runtime.sh \
  Build/Linux/native-bootstrap/application.EXAMPLE
```

将 `application.EXAMPLE` 换为实际成功输出；第二个参数可选运行镜像。入口先校验构建记录中的核心、GUI 和 libdrmtap 哈希，在该生成工作区内建立测试路径别名，再只读挂载到容器。夹具在容器自己的 `/opt`、`/run`、两个 Xvfb 和 loopback 中完成认证、视频解码与 GTK 呈现、退出/第二次连接及 Host 保留检查，不接触宿主显示或线上身份。

这项软件视频测试不验证新构建的 GPU 后端、真实 Wayland、硬件音频或运行内存目标。构建通过也不代表完整许可审计、公开 CI 或正式发布已经通过；不会据此把 `runtime_ready` 改为 true。

## 当前验证

`application.fQLWLQG3` 已通过：88,608 个源条目及新依赖前缀核验，空 Cargo/编译缓存下断网完成 FFmpeg、libdrmtap、核心和 GUI。阶段实际耗时分别约 37.2 秒、1.6 秒、522.1 秒、59.9 秒，不包含复制、校验和镜像准备。

最终 `result.json` SHA-256 为 `c6dbcbaa7ff0866088465a1f178c58760affc85019ea5966cbdaf6476014561b`。原生核心 SHA-256 `74ec25af68e3ea487453e22b934973f153f027fa518f93891566f5bc2a5fc13d`，GUI `482a3d8d69a31199de48b2d4a368c21101d79a1bb902404223282990f6221cc0`；它们与旧候选的哈希不同，不宣称按位复现。

首次运行的四个编译阶段均成功，但最终检查误把 Meson 的 `libdrmtap.so.0.5.8.p` 中间目录算作库。改为只统计普通库文件后，使用验证模式重新核对全部原输入（只有预期的生成日期文件变化）、阶段日志、两个程序及实际动态库解析，汇总通过；没有重编译已成功产物。原失败、修正前入口与后续验证日志均保存。

`runtime.IhtPGB2B`（Ubuntu 24.04 纯运行镜像）和 `runtime.ZbNmFUDZ`（Ubuntu 26.04 环境）均通过九类实际连接检查，每个环境两次软件视频会话。测试复制的核心/GUI 哈希与本次新构建逐项相同。该结果覆盖真实认证、软件视频解码、GTK 呈现、错误密码重试、退出回收及 Host/设置保留；仍不代表真实桌面或 GPU 验收。详见[完整源码构建证据](../../Evidence/LinuxHost/2026-10-17-native-source-build/README.md)。

`.4` 产品及冻结源码归档保持原版本。新增入口尚未进入该归档；本次新编译产物也不冒充 `.4` 构建 receipt 中的二进制。
