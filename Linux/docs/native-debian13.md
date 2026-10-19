# FarPane Linux GPU 媒体重构（linux-host）：Debian 13 运行检查

2026-10-18，现有 `.20261018.2` 原生候选通过 Debian 13 用户态运行及安装事务检查。使用原始 GUI/core/bundle/Debian 包，没有重新编译、重新打包或修改应用。linux-host 仍运行已安装的 `.20261018.1`；此次没有激活中文候选或操作用户桌面。

## 环境与结果

新增 `Linux/packaging/native-runtime-debian13.Dockerfile` 从固定官方 Debian 镜像创建纯运行环境，镜像 ID、基础镜像和 Dockerfile 哈希保存在 `Linux/tests/native-runtime-images.lock.json`。此记录独立于应用构建依赖，因此不会仅因添加测试发行版而改变既有构建记录。APT 未固定历史快照；确切软件包清单随证据保存，不承诺镜像按位重建。

实测 `/etc/os-release` 为 Debian 13/trixie（13.7），GTK 4.18.6、libadwaita 1.7.6、GLib 2.84.4、glibc 2.41、Python 3.13.5、Mesa 25.0.7。镜像没有 Rust 工具链、GTK 开发头文件、RustDesk 安装或 FFmpeg 命令行程序。运行测试断网，仅使用容器回环连接、私有 D-Bus 和两个 Xvfb；上限 4 CPU/12 GiB/512 PID，不挂载宿主显示、总线、GPU 或输入设备。

| 检查 | 实际结果 |
| --- | --- |
| Bundle 启动和动态库 | 8 项通过，包括完整 ELF 依赖闭包、普通用户/root 的私有媒体加载、缺失/跨 release/可写库拒绝；无 GTK3/Flutter/Sciter 依赖 |
| Bundle 实际会话 | 9 类检查通过，两次实际认证、软件解码和 GTK 呈现，错误密码可重试，Viewer 回收且 Host/身份/配置保留 |
| `.1 → .2` dpkg 事务 | 6 组通过，真实安装、维护事务冲突拒绝配置、`dpkg --configure` 恢复、升级与 purge 保留检查；没有强行忽略依赖 |
| 升级后的包内会话 | 同样通过 9 类检查、两次实际软件视频连接；核对运行的是 `.2` payload |

普通 UID 1000 在 slim 镜像中没有 passwd 名称记录，私有 D-Bus 打印该查询警告；测试按数字 UID 执行且所有检查通过。该环境没有验证依赖真实登录用户、密码库或系统会话的桌面服务。

包升级保留测试使用私有 shell 哨兵、合成配置和服务文件，不运行实际 systemd。不能把这些结果称为 Debian 的真实服务切换、GNOME/KDE/Wayland、发行版内核、硬件媒体、音频/文件/密码库全矩阵或内存验收。容器共用 linux-host 内核；Linux 6.5+ 的独立目标机验证仍保留。此次视频检查没有测试 Mac→linux-host 中文输入，真实缺陷仍按[中文记录](chinese-input.md)保持未关闭。

## 复现

在仓库根目录准备运行镜像（只获取容器依赖，不安装到宿主）：

```sh
DOCKER_BUILDKIT=0 docker build --network default --memory 12g \
  --cpu-period 100000 --cpu-quota 400000 \
  --tag farpane-native-runtime-debian13:20261018 - \
  < Linux/packaging/native-runtime-debian13.Dockerfile
```

本次缓存镜像可直接使用已固定 ID；其他机器重建后若因 APT 更新得到不同 ID，应显式设置既有测试覆盖变量 `FARPANE_NATIVE_RUNTIME_IMAGE` 为该镜像，并重新保留实际 ID 与包清单，不能把结果归给本次固定镜像。

```sh
Scripts/linux/test-native-package.sh \
  Build/Linux/artifacts/farpane-native-dev-67f5d1594e8961809614f4e1 debian-13

Scripts/linux/test-native-deb.sh \
  Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.1_amd64.deb \
  Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.2_amd64.deb debian-13
```

原始结果和程序哈希见[Debian 13 证据](../../Evidence/LinuxHost/2026-10-18-native-debian13/README.md)。本轮新增测试入口和文档尚不在此前冻结的 `e5ee1c6b…` 完整源码归档中；该归档仍与被测候选的应用源码相符，既有候选及归档均未重写。
