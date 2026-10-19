# FarPane Linux GPU 媒体重构（linux-host）：Fedora/RPM 开发候选

2026-10-18。冻结 `.20261018.3` 的 GTK4 GUI、核心、私有媒体库、图标和独立维护工具已打成 x86_64 RPM。无需安装 RustDesk 源码或宿主 FFmpeg。此包是开发候选，`runtime_ready=false`、`release_accepted=false`，不是正式 Fedora 支持或公开发布声明。

本轮只扩展包装与隔离验收。没有重新编译 GUI/core/FFmpeg，没有使用活动工作区中的 Warp 特判草稿；没有在 linux-host 安装 RPM、切换服务、打开用户桌面或调用 GPU。

## 产物与来源

| 项目 | 值 |
| --- | --- |
| RPM | `Build/Linux/rpm/farpane-native-candidate-0.1.0~dev.20261018.3-1.fc44.x86_64.rpm` |
| SHA-256 | `0c0e45b9a67f2e5502d732ccdc1321f7a48106727583056394531fd0b7c05fc7` |
| 大小 | 19,770,160 字节 |
| 应用 release | `farpane-native-dev-d393fd0cff634416807feae5` |
| manifest SHA-256 | `7ec4f7e64dc80688225c5398f99d3f2931f9f2e6346f115469a64defb4b69ebd` |
| 既有应用完整源码归档 | `Build/Linux/source-bundles/farpane-native-source-704f37fe999ad9f837832f79.tar.gz` |
| 应用源码归档 SHA-256 | `88bcdffdf6d246e02a7979e5653bfe111ace4c7e730f69bf66efeca1ddda09ba` |

既有源码归档绑定应用源码，不含后来新增的 RPM 包装代码。新增配方、安装工具、测试与固定镜像清单保存在 canonical `Linux/`、`Scripts/linux/`，并在本轮证据中保存实际快照；不能把旧源码归档宣称为包含新包装流程。包内 `package.spec` 与 `candidate.json` 记录生成规则、依赖和安装工具哈希。许可字段沿用项目自己的 AGPL-3.0-only 声明；第三方原始材料随 payload 保留，完整许可/来源审计仍未完成。

## 安装行为

RPM 仅拥有 `/usr/lib64/farpane-native-candidate`、两个 `/usr/bin/farpane-*` 维护入口，以及对应文档/许可目录。安装、升级、移除均无事务脚本，不自动 stage、不激活 `/opt/farpane`、不启停服务或绑定桌面入口。依赖根据已验证 ELF 的直接链接和 API 下限转成 Fedora 包/能力声明；私有库不向系统声明全局 provides。

包内已经包含 GUI。用户桌面入口仍通过现有[安装事务](native-install.md)绑定到明确激活的 release，以免包管理器升级时替换正在运行的应用。维护流程依次为：安装候选、显式 stage、核对当前版本并生成 plan、在维护窗口 activate，最后由普通桌面用户 bind。README.RPM 和 native-install.md 随包提供；命令入口分别为 `farpane-maintenance` 与 `farpane-user-integration`，不依赖源码目录。

卸载 RPM 只删除其候选与工具，保留已暂存/激活的 `/opt` 副本、服务、身份、密码、用户配置与入口。已有维护事务未完成时，RPM 升级可放置新候选，但显式 stage 仍拒绝绕过恢复记录。自动激活始终关闭；它与应用本身的 GPU 设置无关。

## 隔离验收

实际固定环境是 Fedora 44 用户态：glibc 2.43、GTK 4.22.5、libadwaita 1.9.4、GLib 2.88.4、libva 2.23.0、Mesa 26.2.4、RPM 6.0.2。镜像与 Dockerfile 哈希见 `Linux/tests/native-runtime-images.lock.json`；dnf 仓库没有时间快照锁定，记录的镜像内容固定，不宣称以后重建镜像仍会解析到相同包版本。

1. 冻结 bundle 的 8 项运行/媒体库边界检查通过，包含 ELF 闭包、缺库/跨 release/可写库拒绝、配置不被启动探针改动。
2. 实际 RPM 安装、`.1 → .3` 升级、显式暂存、维护事务冲突与卸载保留共 7 组检查通过。没有关闭 RPM 依赖检查；安装后的清单和 7 份安装工具源码逐项核对。
3. bundle 与 RPM 安装后的应用各完成两次真实 TCP 软件视频连接，共四次。真实 GTK 呈现、错误密码后重试、成功设备记录、Viewer 回收与 Host 身份保留通过。RPM 测试从包安装后的 payload 创建 root-owned 私有执行副本，不执行工作区新编译核心。
4. 相同冻结输入在同一固定包装镜像内重新打包，RPM SHA-256 相同。此检查是包装复现，不是完整应用源码重编或镜像仓库快照复现。

保留行为使用真实文件、私有常驻 shell 和服务单元哨兵验证，不是实际 systemd 服务切换。UID 1000 在运行镜像 passwd 中未注册，D-Bus 有查询警告；数字 UID 的私有会话通过，不代表完整用户登录、系统密码库或桌面总线已验收。所有连接都位于无外网容器、私有 Xvfb/总线，未挂载宿主显示、输入或 GPU。

Fedora 自己的内核、SELinux enforcing、systemd/logind、GNOME/KDE/Wayland、硬件媒体与跨平台完整交互仍未验收；首页 60 MiB 和 24 小时长稳目标也未关闭。中文输入方案按用户要求暂停讨论，不将这些打包检查算作中文修复。

复现（只作用于 Build 与隔离容器）：

```sh
python3 -B Scripts/linux/package-native-rpm.py Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5 --version 0.1.0~dev.20261018.3
python3 -B Scripts/linux/package-native-rpm.py Build/Linux/artifacts/farpane-native-dev-bfc1befc221061266d5f50da --version 0.1.0~dev.20261018.1
python3 -B Scripts/linux/test-native-rpm.py 'Build/Linux/rpm/farpane-native-candidate-0.1.0~dev.20261018.1-1.fc44.x86_64.rpm' 'Build/Linux/rpm/farpane-native-candidate-0.1.0~dev.20261018.3-1.fc44.x86_64.rpm'
bash Scripts/linux/test-native-package.sh Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5 fedora-44
```

入口默认 4 CPU/12 GiB；包装用普通 UID、断网和只读根，测试只在容器内执行 root 包事务。镜像准备使用独立 Dockerfile；本轮首次包装发现 Fedora `timeout` 在无 init 的 PID 1 位置直接退出 125，以及 rpmbuild 默认 `/var/tmp` 不可写，分别通过 Docker `--init` 与私有 `/tmp` 修正。失败日志保留，没有放宽为宿主安装或可写宿主根。

原始检查、失败日志、图像、固定输入与源码快照见[本轮证据](../../Evidence/LinuxHost/2026-10-18-native-fedora44/README.md)。
