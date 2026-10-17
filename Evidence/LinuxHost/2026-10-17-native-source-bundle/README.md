# FarPane Linux GPU 媒体重构（linux-host）：离线源码包检查点

分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。已生成开发源码快照，并完成脱离原工作区与 Cargo 缓存的完整 GUI Release 构建。没有重建 FFmpeg、替换现有二进制、安装、发布或切换服务。

源码包：`Build/Linux/source-bundles/farpane-native-source-9cb60aa797e537ab5e997bf1.tar.gz`，760,837,871 字节，SHA-256 `8f106ef850acbf8f410f931fda0b5cb818da34fd2fbaaeb8f6d041489d5cb1d4`。包含 88,534 个文件条目、1,082 个 vendor 目录；60,731 个 Cargo 源文件另经 vendor 清单/校验和检查。目录数包含非 Linux/dev 依赖，不是运行时组件数或内存样本。

固定 Git/源归档重新展开后，应用 canonical patch/overlay/lock，与 prepared source 全树核对。`source-manifest.json` 明确列出旧 Flutter 生成物的排除项；保留固定原文件，不复制旧 plugin/cache。Flutter bridge 在 native Linux 下受 cfg 禁用。当前 `src/version.rs` 是日期生成器的观察值，不是原 Release 时间的证明。13 个实际非 FFmpeg port 的 72 份配方文件均匹配缓存 ABI；10 份源归档通过固定 Git 内容或配方 SHA-512 核对。配方 pin 保存在 canonical `Linux/native-source-pins.json`。

`smoke-runs/20261017T025513Z` 为首次四项通过：完整解包清单、core 离线图、GUI 离线图、重新编译后的 38 项协议测试。`smoke-runs/20261017T025659Z` 是增加完整 GUI 构建后的最终五项通过；实际编译为 Rust 1.89.0，Release 编译日志记录 1 分钟。新 GUI SHA-256 `4174a938a221ab53efe85c73ad323e33ac79e0c70bd0d688ea9d66fa76f20980`，无显示组件探测通过。它没有替换原 GUI；不主张与原二进制逐字节一致。

测试容器仅挂载源码包、独立测试驱动、只读 Rust SDK 和新的输出目录，网络关闭，约 4 核/12 GiB，无原工作区、Cargo registry/git/target 缓存、GPU 或宿主 socket。全部实际包路径在解压树中。core 的 666 项/GUI 的 71 项来自完整 metadata 图，和此前非 dev 材料遍历的计数不同。仅 core 依赖图通过；没有在这轮执行核心、FFmpeg 或其他媒体依赖的全新编译。

原始失败均保留：配方定位前两次在 Meson 的 SHA 字段位置上失败，最终在实际 port 配置中找到；源码包前三次分别因 Linux/Windows Flutter ephemeral 越界链接及已知生成文件差异拒绝。最终以逐项列出的旧构建输出排除表修正，没有忽略整个 Flutter 树或未知源修改。第四次生成成功。测试驱动与最终说明在快照生成后补齐；快照 manifest 保留生成时的 `fresh_full_build_verified=false`，后续 GUI 构建证据单独保存。

`source-state.json` 保存 326 个 canonical 文件哈希；`build-receipt.json` 绑定当前产品 core/GUI。`host-state-final.json` 与 Debian 阶段基线完全一致：FarPane PID 3212867、RustDesk PID 1880443、`/opt/farpane/current` 及四份 FFmpeg 静态库的哈希/大小/mtime 均未变。staging 63 文件只读检查、Python/shell 语法及 `git diff --check` 通过。

完整原生依赖/core 全新重建、公共 CI、嵌套第三方文本与完整对应源码/许可义务仍未验收，`complete_license_source_audit=false`、产品 `runtime_ready=false` 保持不变。本归档含清单、原始日志和校验值；大型源码树/归档留在 Build。复现说明见 [native-source-bundle.md](../../../Linux/docs/native-source-bundle.md)。
