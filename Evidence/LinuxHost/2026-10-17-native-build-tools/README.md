# FarPane Linux GPU 媒体重构（hermes）：公开工具链验证

本阶段新增固定公开工具下载和独立 Rust SDK 安装入口，解决完整源码构建依赖 hermes 旧 SDK 的缺口。使用新 SDK、全新 Cargo/target 和已冻结源码，实际完成协议测试与 GUI Release 编译。未重新编译 core/FFmpeg，未替换 `.5` 产品或安装到宿主。

## 输入与实现

`Linux/native-build-tools.lock.json` 固定 rustc、cargo、rust-std、vcpkg 和 CMake 的 URL/归档名/哈希。Rust 1.89.0 的官方发布清单及 checksum 保存在 `logs/`，清单 SHA-256 `fbd1662e100e7b305908ece23b441cb7534eadfa6336c5f173ff08d1cec174a1` 已核对。vcpkg 2026-07-27/CMake 4.4.0 的 SHA-512 与固定 vcpkg `9e593bb18ea69cc5095e012465dcd675a822ed0d` 源码工具 metadata 一致。

五个固定 URL 均实际下载成功、验证通过；下载日志、大小/哈希、缓存状态保存于 `sdk/downloads.json`。不执行网络脚本或浮动 rustup 安装；只有完整下载通过固定哈希后才原子创建缓存文件。损坏缓存不会自动覆盖。SDK 安装脚本来自已固定归档，在普通 UID、4 CPU/12 GiB、断网的公开 Ubuntu 24.04 容器中运行。`--prefix=/output/sdk --disable-ldconfig`，只读输入与独立输出，没有宿主显示/GPU/服务/凭据挂载。

`prepare-native-tools.py --offline --reuse-sdk` 校验缓存及完整 SDK 清单；`--fetch-only` 允许只准备工具。`FARPANE_NATIVE_RUST_SDK` 为完整源码构建和源码 GUI 检查选择只读 SDK；不设置时保留原默认路径。新结果记录 rustc/cargo 和 SDK receipt 哈希，旧冻结结果不改写。

## 结果

安装输出 `Build/Linux/native-tools/rust-sdk.i5f0jr3s/sdk`，125 个文件/链接清单条目。SDK receipt SHA-256 `adbd762eb3ea1beb1829d03a4a3f8611ff7a3cde261c1113cd6783e47e98a929`。

- rustc `1.89.0 (29483883e 2025-08-04)`，二进制 SHA-256 `c6ac0142c05a60b0f6c15e1a118bd5ac3bd04924cd6dc0c328f501c5f86e4142`。
- cargo `1.89.0 (c24e10642 2025-06-23)`，二进制 SHA-256 `5b32bd53b8a08d8e206daed51f3fce40cdc0729038ff96bd0ca845596a2c1019`。
- 编译器、Cargo、编译器共享库和目标标准库共 40 个关键文件与旧 SDK 内容完全相同，详见 `logs/compiler-identity-check.json`。没有据此声称所有文档、安装清单或路径元数据逐字节相同。
- 离线复用成功，五项完整性回归通过：损坏缓存拒绝且保持原内容、离线缺件不创建文件、缓存符号链接拒绝、SDK 增改文件拒绝、SDK 越界链接拒绝。

`Build/Linux/native-source-smoke/20261017T052232Z` 将新 SDK 挂载到不同于安装路径的 `/toolchain`，在 public builder `sha256:d0923a2040628a31f2048eb01704030bed22b5ae35e61726378565ff557b710d` 中测试。只有冻结 `514e82df…` 归档、新 SDK、测试驱动及新输出挂载；网络关闭，没有原仓库/编译缓存挂载。

五项实际检查通过：88,621 个源码条目校验、core/GUI 离线依赖图（666/71 个包）、38 项协议测试、完整 GTK4 GUI Release 编译和无显示组件探测。GUI 证明产物 SHA-256 `686759427990833a512426e97129bfbdb399c768d4fe6579267d536812d52e3d`。它只证明 SDK 和源码入口可用，没有替换 `.5` GUI，也不宣称按位复现或完整媒体再次编译。

下载/安装 handle48957、新 SDK GUI 检查 handle70248 均 exit0，无待续作业。只读查验了 checkout v4.2.2 / upload-artifact v4.6.2 的 Git refs 作为后续 CI 调查；本阶段没有新增 workflow、触发 GitHub job 或发布附件，不将元数据查询当作 CI 执行证据。

## 边界与未完成项

`.5` bundle/Deb/源码归档哈希全部未变，`candidate-unchanged.json` 保存核对。宿主 FarPane/RustDesk PID、状态、当前 release，以及旧四份 FFmpeg `.a` 大小/mtime/hash 与上一阶段一致；旧产品 receipt 仍有效。无安装、服务/桌面切换、commit/push/deploy，维护窗口确认仍待回复。

工具获取入口与本轮外部测试代码尚未纳入冻结 `514e82df…` 归档；canonical 和本证据中保留，不能假称下载旧归档即含新入口。公开 Linux workflow/云端执行、完整第三方许可审计、真实桌面/Mac/硬件媒体/长稳/配对性能仍未关闭，60 MiB 首页目标未过。本阶段没有重新测量内存或改变验收范围。

`SHA256SUMS` 为本地证据索引，不是发布者签名。
