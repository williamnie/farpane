# FarPane Linux GPU 媒体重构（hermes）：原生开发包与 ABI

2026-10-16，`codex/linux-host-gpu-media`，HEAD `b01c40b`。原生 GUI、核心和私有媒体库已形成可重复打包的开发 bundle；仍为 `runtime_ready=false`。没有安装、启动新宿主服务、提交、推送或发布，完整 GUI/后端/安装交付目标继续进行。

实际内容包括 GTK4/libadwaita GUI、`libexec/farpane-core`、私有 libdrmtap、FarPane 图标、desktop/D-Bus/systemd 模板、patch/pin/lock、canonical 源码及已有许可证。没有 Flutter engine、原 RustDesk 安装或动态 FFmpeg 依赖。完整依赖许可证/对应源码审计尚未完成，不能将此候选作为公开完成版发布。

## 构建、加载与完整性

- 新 `build-native-app.sh` 复用隔离工具链和静态 FFmpeg，构建前后核对 canonical/staging，记录输入源码和实际组件哈希。打包验证原始二进制、记录及随包源码一致，在副本中删除构建工具链 RPATH；原始构建二进制不修改。
- 新 native manifest 校验文件、路径、哈希、长度、权限、同目录库别名和 artifact ID。15 项测试覆盖篡改、漏项、越界、符号/硬链接、特殊文件与可写权限。同一候选固定输入的两次压缩包 SHA-256 一致；不是对独立重编译逐字复现的声明。
- native libdrmtap 仅从实际 core 所属不可变 release 的 lib 目录加载，root/普通用户一致。缺库时不使用旧 `/opt/farpane/current` 或环境搜索；跨目录别名、库目录符号链接和普通用户可写库均拒绝。原 Flutter 选择逻辑保持。
- GUI/core 的 build-info probe 无须桌面或配置；新增媒体库 probe 只查 ABI/符号，不打开 GPU/显示。实际测试确认没有创建配置或 runtime 文件。新增入口按 drm/hwcodec feature 保护，native 不启用硬件的组合和旧 Flutter/GPU check 均通过。

## Ubuntu 24.04 的真实失败与修复

初次纯运行镜像 `runtime/20261016T223942Z` 在核心加载阶段失败：libva 2.20 没有 `vaMapBuffer2`。此前 Ubuntu 26.04 构建环境使用 libva 2.23。这证明仅看 glibc 版本和 GTK API 下限不足以声称跨发行版兼容。

固定 FFmpeg 9 的 hwcontext_vaapi.c 在编译期 VA API 1.21+ 调用新接口，旧分支使用 vaMapBuffer。native 现在以最终链接 --wrap 和一次性动态查询选择实际接口；新 API 的 flags/返回值原样保留，仅接口缺失时使用已有旧操作。新接口返回错误时不重试旧操作。两份真实 ELF 符号集合、独立翻译单元、八个并发线程和 lookup 计数验证均通过。**FFmpeg 静态库未重建，系统 libva/驱动未替换。** 四个静态库的大小、mtime 和哈希记录保留。

最终包在 Ubuntu 24.04 纯运行镜像和 Ubuntu 26.04 builder 中，各完成八类包/库检查与两次实际 TCP 登录、软件解码、GTK 呈现、错误密码重试和 Viewer 退出回收，Host 保留。最终运行目录及精确包/二进制 SHA-256 见 `source-state.json`；每轮有发行版、实际包版本、ldd 闭包和原始日志。Ubuntu 24.04 镜像未安装 RustDesk、FFmpeg、Rust 工具链或 GTK 开发头文件。

这些测试使用宿主内核和私有 Xvfb/D-Bus，不能代替目标发行版默认内核、真实 GNOME/KDE/Wayland、硬件编解码、音频和完整功能验证。限定 render 节点的包 GPU 检查结果以 `source-state.json` 的 gpu 字段及对应原始日志为准；deferred 表示没有进行，不算通过。

## 保留的其他失败与限制

首个 manifest 测试夹具继承了用户的 0002 umask，目录为 0775，被严格校验拒绝；夹具改为明确 0755 后 15 项通过，未放宽产品权限规则。构建期间追加 feature 保护使源码变化，构建记录拒绝签发该次产物；之后以稳定源码重新完成构建。CPU-only check 发现旧诊断入口引用被禁用的 hwcodec 函数，补齐 feature 条件后通过。原始失败日志全部保留。

完整目标的未验收项仍包括：安装/升级/回退与本产品 desktop/autostart 迁移、用户维护窗口中的 root/user 协调切换、真实桌面/后台/睡眠/网络恢复、跨平台互操作、音频设备与同步、完整 GPU/最大分辨率/故障/长稳、首页 60 MiB 和整条链路低内存、发行版完整矩阵及 Linux CI/许可证/源码发布。

目前包内桌面和服务文件仍含 `@FARPANE_RELEASE@` 模板，不可直接启用；旧安装器不接受 native manifest。现有 FarPane/RustDesk 服务、配置、ID、密码、宿主桌面和 /usr 均未改变。后续完成原生安装器和隔离升级回退，再安排实际切换测试。

复现与边界见 `package-contract.md`。生成 tar.gz 留在 Build/Linux；`artifact-manifest.json`、`artifact-build.json`、`build-receipt.json` 和 `source-state.json` 固定产物/源码信息，`evidence-sha256.json` 固定原始证据。此前归档未改写。

最终开发包：`farpane-native-dev-98a34f241b2e1b20a2bcbaba`；tar.gz SHA-256：`9e31a4401c64db6561b50adc1b6c9740a87eefe577ec2050b5a779a7cd9fc19d`。GPU 检查 `20261016T225409Z` 通过，使用限定 renderD128、256×128、12 fps 静态内容，两轮真实 VAAPI/DMA-BUF 呈现、after-paint 和退出回收通过，未使用软件帧。17.24 秒内 86 次已安装 FarPane 的只读连接计数检查均为空闲；没有切换服务、显示模式或实际桌面。这是 hermes 驱动上的私有测试，不是 Ubuntu 24.04 GPU 或全分辨率/低内存验收。
