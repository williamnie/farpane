# FarPane Linux GPU 媒体重构（hermes）：原生开发包

当前有带 GTK4 GUI 的原生开发 bundle，包含独立核心、静态 FFmpeg、私有 libdrmtap、图标、桌面/D-Bus/服务模板和 canonical 源码。其外层 [Debian 测试候选包](native-deb.md)已完成实际隔离安装、升级、移除与 GUI 连接；它仍不是已验收的正式 deb，也没有安装到宿主；`runtime_ready=false`。真实维护切换、依赖许可证与对应源码审计、跨桌面/完整功能/内存仍是交付门槛。

对应开发二进制的[离线源码快照](native-source-bundle.md)已生成；完整 GUI 在无网络、空缓存、没有原工作区挂载的容器中重新编译通过。源码归档是独立开发材料，不增加 `.deb` 的运行负担；完整 core/原生依赖的全新构建与发布审计仍待完成。

## 构建和打包

先按既有准备入口同步 canonical patch/overlay 和 `prepare-native.py`；不覆盖未知生成目录修改。应用构建复用已经编译的 FFmpeg 和 Cargo 缓存，无须宿主 RustDesk 或 FFmpeg：

```sh
Scripts/linux/build-native-app.sh /path/to/read-only-reference-cache
python3 -B Scripts/linux/package-native.py
Scripts/linux/test-native-package.sh Build/Linux/artifacts/farpane-native-dev-<hash>
Scripts/linux/test-native-package.sh Build/Linux/artifacts/farpane-native-dev-<hash> ubuntu-24.04
```

hermes 的只读 reference 为 `/home/xiaobei/services/rustdesk-host-perf-20261015`；这里只借 pinned Git 对象核对源码，不能运行其中的服务切换脚本。构建入口按顺序使用既有隔离镜像，约 4 核/12 GiB，不并行叠加容器。`native-build.json` 记录构建前后 canonical 文件哈希、实际 core/GUI 二进制哈希和无显示环境的组件 probe；源码或二进制改变后打包入口拒绝使用旧记录。FFmpeg 不由本入口重建。

`package-native.py` 只写 `Build/Linux/artifacts/`。它在副本中删除 Cargo 工具链 RPATH，记录修改前后哈希和 ELF 依赖/符号版本，并拒绝旧 GUI 库及动态 FFmpeg 依赖。开发包中的工具版本、源码和 patch/pin/lock 随包保存；原始构建二进制不修改。文件清单、长度、权限、SHA-256 和受限同目录 libdrmtap 别名共同决定 artifact ID；未列出的文件、路径越界、外部链接、硬链接、特殊文件或可写权限均拒绝。SHA-256 是完整性校验，不是发布者签名。

包的入口是 `farpane`，核心在 `libexec/farpane-core`。运行角色只接受 root-owned、普通用户不可写的 release。native libdrmtap 仅从该核心所在 release 的 `lib/` 加载，不回落 `/opt/farpane/current`、原 RustDesk 或环境搜索路径；库缺失、别名指向其他目录、库目录为符号链接或路径可被普通用户修改时明确失败。该修改只影响 native feature，旧 Flutter 的库选择保留。

`--build-info` 可在无显示/配置环境下检查 GUI 和 core；核心另有 `--check-bundled-media`，只加载同 release 的库并核对符号/ABI，不打开显示、GPU、采集或用户配置。它用于打包检查，不是 GPU 媒体功能验收。

## 运行依赖与验证范围

目标为 x86_64、Linux 6.5+、GTK 4.14+、libadwaita 1.5+，系统提供图形驱动、GLib/GTK、EGL/GLES/GBM、X11、PulseAudio 客户端库和核心所需 GStreamer/DBus 等运行库。精确 ELF 依赖见包内 `build.json`，实际闭包以测试容器的 ldd/加载结果为准。Secret Service、桌面通知和 Wayland 后台剪贴板等能力依赖桌面提供者，不能仅凭加载成功标记支持。

`native-runtime-ubuntu2404.Dockerfile` 从固定 Ubuntu 24.04 镜像建立纯运行测试环境，不包含 Rust 工具链、GTK 开发头文件、FFmpeg 或 RustDesk 安装。镜像和包版本锁定在依赖记录及测试日志。这个环境可证明用户态 ABI 和私有 X11 GUI/视频连接的兼容性；它仍使用宿主内核，不证明 Ubuntu 默认内核、真实 GNOME/KDE、Wayland portal 或硬件媒体兼容。

首次实际运行发现 Ubuntu 24.04 的 libva 2.20 缺少 `vaMapBuffer2`，核心在加载阶段即失败。FFmpeg 9 的 `hwcontext_vaapi.c` 按编译时 VA API 1.21 选择这个接口，旧分支本来使用 `vaMapBuffer`。native 最终链接现在以 `--wrap` 将该单一调用交给 `vaapi_compat.c`：一次性查询实际运行库，接口存在时原样传递 flags/返回值；仅在接口缺失时使用 FFmpeg 原有的旧映射操作。新接口返回错误时不重试旧操作。没有重建 FFmpeg，也没有替换系统 libva 或驱动；旧 Flutter 链接不启用该包装。独立 ELF 测试用两个实际符号集合和八个并发线程验证分派，不能代替旧发行版 GPU 实测。

`test-native-package.sh` 仅在无网络/宿主显示/GPU/socket 的容器中将开发包复制到私有 root-owned `/opt`。先检查 root/普通用户同 release 加载、缺库时禁止全局回退、越界链接/可写库拒绝及不创建配置；然后在私有 Xvfb/D-Bus 中运行两次真实软件视频连接、错误密码重试和 GUI 呈现/回收，沿用已有集成夹具。每次记录实际测试二进制、发行版、库闭包和原始日志。

2026-10-16，修复上述符号问题后的同一包，已在 Ubuntu 24.04 纯运行镜像及 Ubuntu 26.04 builder 各通过八类包/库检查和两次实际连接。证据见 [原生包与 ABI 检查点](../../Evidence/LinuxHost/2026-10-16-native-package-abi/README.md)。这里的兼容结论限定为已测软件视频/X11 场景，不据此扩大 GPU、桌面授权或完整发行版支持范围。

## 安装流程的隔离实现

desktop、D-Bus 和 systemd 文件中的 `@FARPANE_RELEASE@` 由新安装器绑定确切不可变路径；不是可以直接复制启用的文件。旧 `install-app.py`/`install-system.py` 不接受此 native manifest，不能把开发 bundle 传给旧安装器或手动覆盖现有 `current`。

新安装器已实现私有暂存、root/user 进程协调、journal 恢复、P1 回退和普通用户桌面事务，见 [安装与回退合同](native-install.md)。真实进程/文件事务与开发包探测在容器验证；服务管理器目前仍使用测试替身，真实 root/systemd/logind 和用户桌面切换待验收。安装器保留 ID、密钥、密码与共享配置，普通用户入口有独立 backup。完整产物和独立验证完成后再报告宿主维护窗口；本阶段不改变现有 FarPane/RustDesk 服务或宿主文件。
