# FarPane Linux GPU 媒体重构（linux-host）：离线源码包

已生成与当前开发二进制构建记录关联的源码快照，并在断网、空 Cargo/编译缓存、没有原工作区挂载的容器中编译出完整 GTK4 GUI。核心的离线依赖图也通过；原生媒体依赖及整个核心的全新构建尚未验证。这份开发快照不代表完整发布许可审计已经完成。

## 内容与来源

canonical 入口为 `Scripts/linux/package-native-source.py`、`Linux/packaging/native_source_bundle.py` 和 `Linux/native-source-pins.json`。输出固定在 `Build/Linux/source-bundles/`，不安装程序，不访问服务，也不重建已有 FFmpeg。

- `Linux/`、`Scripts/linux/` 保留本项目源码、补丁、pin、锁文件、安装工具与文档。
- `Build/Linux/src/` 从固定 Git 对象/校验过的 FFmpeg 归档重新展开，应用 canonical patch/overlay/lock，然后逐文件核对当前 prepared source 的内容、链接和执行权限。原生 GUI、协议与文件库保留原有路径关系。
- `vendor/` 与 `.cargo/config.toml` 来自两个锁文件的离线 `cargo vendor`，目录使用可迁移的相对路径。1,082 个目录包含其他平台和 dev 依赖；不是 Linux 运行时组件数，也不表示 GUI 内存占用。
- `native-dependencies/` 保存 13 个实际使用的非 FFmpeg 原生 port、72 份配方文件的 pin、原 ABI 记录、10 份源归档，以及固定版本的 vcpkg 源码。配方逐项匹配实际缓存 ABI；AOM/libyuv 的归档内容与固定 Git 对象核对，其余归档与配方的 SHA-512 核对。ffnvcodec 使用实际缓存 12.1.14.0 的历史配方，不能误用当前 vcpkg 树中的较新配方。
- FFmpeg 9.0.2、AMF 1.5.2 和 Meson wheel 原归档位于 `Build/Linux/downloads/`，按已有 pin 校验。没有用缓存中的旧 FFmpeg/AMF port 替代它们。

`source-manifest.json` 绑定 88,534 个文件条目；其中 60,731 个 Cargo 源文件另外通过 vendor 校验和及完整目录清单检查。没有复制安装中的 FarPane 可执行文件、编译输出、Cargo 索引、凭据或 Git 对象缓存；上游依赖自身携带的测试/构建资源仍随其源码保留。

prepared source 比较明确排除旧 Flutter build/plugin/cache/bridge-generator 输出，排除项逐项写入 manifest；固定版本中受跟踪的原文件仍在源码包内。Linux native 的 Flutter bridge 模块受 cfg 禁用。上游 `gen_version()` 每次构建/check 会重写 `src/version.rs` 中的日期，因此单独捕获当前生成文件，并明确它不证明原始 Release 的构建时间。其余 prepared source 必须与 canonical 重建完全一致。没有将忽略目录中的未知修改悄悄作为最终源码交付。

## 生成与检查

本地生成复用既有只读 reference 与 Cargo 缓存。先在隔离容器中从 core 清单运行 `cargo vendor --offline --locked --versioned-dirs --sync /workspace/Build/Linux/gui/Cargo.toml <vendor目录>`，将 Cargo 输出的 source replacement 配置保存为文件；然后执行：

```sh
python3 -B Scripts/linux/package-native-source.py \
  --reference /home/user/services/rustdesk-host-perf-20261015 \
  --vendor Build/Linux/source-bundles/work/vendor \
  --vendor-config Build/Linux/source-bundles/work/vendor-config.toml
Scripts/linux/test-native-source.sh \
  Build/Linux/source-bundles/farpane-native-source-9cb60aa797e537ab5e997bf1.tar.gz \
  8f106ef850acbf8f410f931fda0b5cb818da34fd2fbaaeb8f6d041489d5cb1d4
```

同一输出目录存在时拒绝覆盖，应先检查保存的结果。生成仍依赖 linux-host 已有镜像和源缓存，不声称是公共 CI 的完整 bootstrap。

源码包解压后，以快照根为工作目录，使用 Rust 1.89.0、C/C++ 工具链和系统 GTK4/libadwaita/EGL 开发库，可运行：

```sh
export CARGO_HOME="$PWD/Build/source-cargo-home"
export CARGO_TARGET_DIR="$PWD/Build/source-target"
export CARGO_BUILD_JOBS=4
cargo test --offline --locked --manifest-path Build/Linux/gui/Cargo.toml \
  -p farpane-protocol --lib
cargo build --offline --locked --release --manifest-path Build/Linux/gui/Cargo.toml
"$CARGO_TARGET_DIR/release/farpane" --build-info
```

需从快照根运行，使 Cargo 读取其中的 `.cargo/config.toml`。该 GUI 构建不需要安装 RustDesk 或主机 FFmpeg。完整应用还需要对应 core 和原生媒体依赖；单独执行 GUI 构建不等于安装完整应用。

## 实测结果与剩余范围

2026-10-17 最终检查 `Build/Linux/native-source-smoke/20261017T025659Z` 通过五项：归档/全部解包文件校验、core 离线图、GUI 离线图、38 项实际协议测试、完整 GUI Release 编译及无显示组件探测。容器仅挂载源码归档、独立测试驱动、只读 Rust SDK 和新的输出目录；网络关闭，无 GPU、宿主桌面或服务 socket。编译约 4 核/12 GiB。core 图含 666 项、GUI 图含 71 项；它们与材料清单的非 dev 边遍历计数口径不同。

源码归档为 760,837,871 字节，SHA-256 为 `8f106ef850acbf8f410f931fda0b5cb818da34fd2fbaaeb8f6d041489d5cb1d4`。新编译 GUI SHA-256 为 `4174a938a221ab53efe85c73ad323e33ac79e0c70bd0d688ea9d66fa76f20980`；它仅用于源码构建证明，没有替换已测候选 GUI。未验证与原构建的逐字节重现。

快照在测试之前冻结，因此其 `fresh_full_build_verified=false` 保持原值；外部证据记录后来的完整 GUI 编译通过，整个 native media/core 构建仍为未验收。测试驱动和本说明在快照之后补齐，canonical 的最新版本以本仓库为准；不修改已冻结源码包或伪造过去的清单。

尚需公共环境的原生依赖 bootstrap、全新 core/媒体源码构建、独立 Linux CI，以及[完整第三方许可与对应源码核对](native-source-materials.md)。材料存在不等于许可审计关闭。`complete_license_source_audit=false`、产品 `runtime_ready=false` 保持不变。原始失败记录、最终结果和源码清单见[本轮证据](../../Evidence/LinuxHost/2026-10-17-native-source-bundle/README.md)。
