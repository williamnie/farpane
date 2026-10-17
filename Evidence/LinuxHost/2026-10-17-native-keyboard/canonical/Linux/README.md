# FarPane Linux GPU 媒体重构（linux-host）

Linux 专用源码锁定、补丁、Flutter 应用、构建/安装入口和 GPU 探针。已实现 **P1 GPU 媒体集成，运行开关默认关闭**；用户已允许先完成集成并由其进行真实连接验收。P0 的真实同步/颜色/延迟项目及 P2/P3 仍未关闭，现有 RustDesk 服务保持原样。

- 最终方案：[`../docs/linux-host-gpu-media-plan.md`](../docs/linux-host-gpu-media-plan.md)
- 当前结果和未验收项：[`docs/p0-status.md`](docs/p0-status.md)
- P1 实现、测试与边界：[`docs/p1-status.md`](docs/p1-status.md)
- 当前应用和安装位置：[`docs/application-status.md`](docs/application-status.md)
- 原生 GUI 重构方案与内存目标：[`docs/gui-rewrite-plan.md`](docs/gui-rewrite-plan.md)
- 原生 GUI 开发进度、复现入口与未完成项：[`docs/gui-status.md`](docs/gui-status.md)
- 从固定源码独立重建非 FFmpeg 原生依赖：[`docs/native-bootstrap.md`](docs/native-bootstrap.md)
- 完整媒体/core/GUI 源码构建及新程序隔离连接：[`docs/native-source-build.md`](docs/native-source-build.md)
- 从独立源码构建结果生成 GUI bundle 和 Debian 包：[`docs/native-source-package.md`](docs/native-source-package.md)
- 固定公开 Rust SDK、vcpkg/CMake 获取与离线复用：[`docs/native-build-tools.md`](docs/native-build-tools.md)
- 独立 Linux CI、完整源码输入和本地复用验证：[`docs/native-ci.md`](docs/native-ci.md)
- Viewer HUD 统计口径、按需采样与脱敏诊断：[`docs/viewer-diagnostics.md`](docs/viewer-diagnostics.md)
- 同一窗口二十轮连接、资源回收及对象生命周期诊断：[`docs/viewer-lifecycle.md`](docs/viewer-lifecycle.md)
- 富剪贴板接入合同、资源限制与能力边界：[`docs/clipboard-contract.md`](docs/clipboard-contract.md)
- 原生开发包、同 release 库加载与隔离运行验证：[`docs/native-package.md`](docs/native-package.md)
- 原生安装、菜单迁移和回退事务：[`docs/native-install.md`](docs/native-install.md)
- 原生 root/user 生命周期和健康探针边界：[`docs/native-service.md`](docs/native-service.md)
- 原生系统事件、后台注册恢复与验证边界：[`docs/system-recovery.md`](docs/system-recovery.md)
- 原生桌面通知、托盘与窗口激活合同：[`docs/desktop-integration.md`](docs/desktop-integration.md)
- 原生远端密码库与设备名称合同：[`docs/credentials.md`](docs/credentials.md)
- 真实二次验证、验证码输入恢复及 `.6` 候选：[`docs/two-factor-authentication.md`](docs/two-factor-authentication.md)
- 原生 GUI 的真实 ID 直连、公钥拒绝与 hbbr 中继：[`docs/id-server-connections.md`](docs/id-server-connections.md)
- 独占键盘授权、取消、超时和窗口切换：[`docs/keyboard-shortcuts.md`](docs/keyboard-shortcuts.md)
- 同机 ID 冲突修复：[`docs/network-identity.md`](docs/network-identity.md)
- 自建服务器、固定密码和真实帧隐式布局修正：[`docs/implicit-layout.md`](docs/implicit-layout.md)
- CPU 像素消费者与 P1 接点：[`docs/p1-integration-audit.md`](docs/p1-integration-audit.md)
- Linux 依赖和补丁哈希：[`dependencies.lock.json`](dependencies.lock.json)
- canonical 源码、patch、pin 留在 `Linux/`；checkout、缓存、日志及产物均在忽略的 `Build/Linux/`。

## P1 应用构建与安装

```sh
python3 Scripts/linux/prepare.py --reference /home/user/services/rustdesk-host-perf-20261015
Scripts/linux/container.sh Scripts/linux/build-core.sh gpu
Scripts/linux/build-gui.sh
python3 Scripts/linux/package-app.py
Scripts/linux/test-gui.sh <artifact-directory>
sudo python3 -B Scripts/linux/install-system.py <artifact-directory>
python3 Scripts/linux/install-app.py <artifact-directory> --system
```

系统安装只放置独立 `/opt/farpane` 和 `farpane.service`，不启动/enable/daemon-reload。
菜单指向同一 root-owned 可执行文件，以满足原 DRM IPC 身份检查。
本机已按用户“现在启动并开启 GPU”的后续授权启动独立服务和 GUI、开启 GPU；尚未设置开机自启。
真实连接由用户测试；旧版本保留。首次启动检查见 `docs/application-status.md`。

产品适配器的隔离测试入口为 `Scripts/linux/container.sh Scripts/linux/build-gpu-test.sh`，
随后 `Scripts/linux/run-p0.sh adapter`；限定 renderD128、单路 256×128/12 FPS，不使用宿主桌面。

## P0 基线复现

在仓库根目录、`codex/linux-host-gpu-media` 分支执行。reference 仅提供原始 Git 对象和公共编译缓存，始终只读；不要执行旧实验目录的切换脚本。

```sh
python3 Scripts/linux/prepare.py --reference /home/user/services/rustdesk-host-perf-20261015
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/linux/verify-sources.py --reference /home/user/services/rustdesk-host-perf-20261015
Scripts/linux/generate-bridge.sh /home/user/services/rustdesk-host-perf-20261015
Scripts/linux/container.sh Scripts/linux/build-core.sh
Scripts/linux/container.sh Scripts/linux/build-p0.sh
Scripts/linux/run-p0.sh cpu
Scripts/linux/run-p0.sh gpu
Scripts/linux/run-p0.sh gpu-lifecycle
Scripts/linux/run-p0.sh gpu-argb
Scripts/linux/run-p0.sh gpu-pool-one
Scripts/linux/run-p0.sh gpu-steady
Scripts/linux/test-clean-load.sh release
python3 Scripts/linux/package-core.py
```

已有 FFmpeg 9.0.2 静态库不需重新 configure/build。旧缓存的FFmpeg debug/lib已移到 `Build/Linux/retired/cached-ffmpeg-debug`，两种Rust profile都只链接新版PIC档案。首次空缓存才执行 `Scripts/linux/container.sh Scripts/linux/build-ffmpeg.sh`。0006 补丁只影响 libavfilter；已有配置可以在 `Build/Linux/ffmpeg-build` 增量 `make -j4 libavfilter/libavfilter.a && make install`。构建入口固定镜像 ID、Rust 1.89.0，通常限 4 CPU/12 GiB，无网络，无 GPU/显示/服务 socket；仓库只读，仅 `Build/Linux` 可写。

GPU 入口持有互斥锁，只映射 `/dev/dri/renderD128`，uid 1000，容器内临时补充节点所属组（Docker device 映射不继承宿主 ACL；未改宿主组或权限），1 CPU/1 GiB、无网络/桌面/socket、只读根文件系统。仅合成 256×128 图像、12 FPS，测试顺序执行。`cpu` 的上传编码结束后再启动硬件解码，不并行运行多条 GPU 媒体流。

旧库对照可单独执行 `build-legacy-cpu.sh <reference>` 后运行 `run-p0.sh legacy-short`；这是读取 pin 的 7.1.1 基线测试，产品依赖仍为 9.0.2。`run-p0.sh cpu-short` 使用相同非默认短 GOP，供比较关键帧语义。

## 验证入口

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Linux/tests/test_prepare.py
Scripts/linux/container.sh -c 'cd Build/Linux/src/rustdesk && cargo test --offline --locked -p scrap --features hwcodec,drm,wayland --lib -- --test-threads=1'
Scripts/linux/container.sh -c 'cd Build/Linux/src/rustdesk && cargo test --offline --locked --lib --features flutter,hwcodec,drm drm_capturer -- --test-threads=1'
```

其他已验收 root filter 为 `cursor_pos_tests`、`input_map_tests`、`peer_abs_sample_tests`、`ipc::test`。不要用 `drm_capturer::tests`，该 filter 匹配零项；实际模块名为 `drm_capturer_tests`。所有结果必须检查实际执行数量。

`test-clean-load.sh` 构造只有 ELF 依赖闭包的空根目录，里面没有 FFmpeg 命令或动态库；仅 `dlopen(RTLD_NOW)` 核心库，不调用 RustDesk 入口。它验证加载，不替代真实连接或完整应用安装验收。

`package-core.py` 生成 `Build/Linux/artifacts/b0-<hash>/lib/librustdesk.so`、依赖清单、补丁、许可证和哈希。它不是完整安装包，不部署、不替换安装文件。干净加载根和产物拒绝覆盖不一致的既有数据。

当前缓存复用的是固定旧 vcpkg 非 FFmpeg 依赖和固定 builder；从零重建全部非 FFmpeg 原生依赖及跨发行版打包仍未验收。

Viewer 的会话授权与自动重连见[Viewer 自动重连](docs/viewer-recovery.md)。

完整 GUI 的 Debian 测试候选包、依赖与维护安装流程见[Debian 包说明](docs/native-deb.md)。

发布前的离线依赖与许可材料归集见[源码材料清单](docs/native-source-materials.md)。
