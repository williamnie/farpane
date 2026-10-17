# FarPane Linux GPU 媒体重构（linux-host）：Debian 测试候选包

现在可以从已验证的 native bundle 生成带完整 GUI 的 `farpane-native-candidate` Debian 包。它包含 GTK4/libadwaita GUI、独立核心、静态 FFmpeg、私有 libdrmtap、图标、桌面/服务模板、对应 bundle 源码，以及不依赖工作区的安装工具。用户无需安装 RustDesk 或宿主 FFmpeg。当前仍为开发候选，`runtime_ready=false`；不能当作正式发布验收。

## 构建与依赖

```sh
python3 -B Scripts/linux/package-native-deb.py \
  Build/Linux/artifacts/farpane-native-dev-<hash> \
  --version '0.1.0~dev.YYYYMMDD.1'
```

输出仅写入 `Build/Linux/debian/`，同时生成 SHA-256。此步骤不重建 core、GUI 或 FFmpeg，不安装到宿主。打包前验证 bundle 清单、实际 ELF 架构、依赖与 build 记录、glibc/libstdc++ 符号下限；新增未知动态库或超出声明 ABI 时拒绝打包。所有包内路径、权限和时间确定，Debian 压缩线程上限为 4；相同输入的独立重打包 SHA-256 一致。

直接依赖声明覆盖 GTK 4.14、libadwaita 1.5、GLib 2.80、glibc 2.39、图形/音频/X11/VAAPI/GStreamer 库、Python 3.11+ 与动态读取的 libsecret。包安装与暂存不依赖正在运行的 systemd；激活仍要求 systemd 桌面。systemd、用户总线和密码库提供者列为推荐组件，不表示密码库已解锁或桌面已授权。内核要求 Linux 6.5+，不能用容器的宿主内核验证替代目标发行版内核验收。

## 包管理与运行版本

包管理器拥有 `/usr/lib/farpane-native-candidate/` 下的候选和独立控制工具，及 `farpane-maintenance`、`farpane-user-integration` 两个命令。配置包时调用已有 `Store.stage`，将经过校验的完整候选复制到 `/opt/farpane/.staged/`。没有新增切换算法或 root helper 协议。

安装/升级不会改变 `current`、停止或启动服务、打开 GUI、绑定用户菜单或修改身份/密码。存在未完成维护事务或不认识的安装目录时，包配置明确失败；先处理原事务，再继续 `dpkg --configure farpane-native-candidate`，不能把失败当作已经激活。

实际服务与用户菜单切换仍走[安装合同](native-install.md)：先读取计划和确切前一版本，再于维护窗口执行 activate；桌面用户随后执行 bind。包内 `README.Debian` 已替换为该候选的实际 release ID，包含完整命令和回退说明。激活后的 GUI 使用同一不可变 release 的 core，不会直接从可被下一次 dpkg 替换的候选目录运行。

移除/purge 仅删除候选包自身的文件和命令，保留 `/opt/farpane` 的暂存/运行/回退版本、现有服务文件和用户配置。因此移除候选包不等于停用应用；应先维护切换到希望保留的版本。这项区别直接写入 Debian Description 和安装说明。没有实现自动清理用户数据或正在使用的 release。

## 实际验证

2026-10-17，以同一个已验证 native bundle 生成 `.1` 和 `.2` 两个候选，在 Ubuntu 26.04 与 Ubuntu 24.04 运行环境各通过 6 组检查：实际 dpkg 安装及依赖满足；独立控制命令/源码；包内 GUI 两次真实视频连接与 worker 回收；维护事务未结束时拒绝配置；升级失败后配置恢复；purge 后原链接、测试进程、服务文件与配置保留。未使用 `--force-depends`。26.04 前两次运行是进程夹具因 multicall coreutils 改名后启动失败，包本身已配置成功；修正夹具后完整重跑，失败记录保留。

保留进程是私有阻塞 shell，服务文件是容器内哨兵；不据此声称真实 systemd 维护或现有用户连接未中断的验收。视频采用真实 core/GUI/协议、两台私有 Xvfb，未使用宿主显示、网络、GPU、密码库或服务。

复现：

```sh
Scripts/linux/test-native-deb.sh FIRST.deb UPGRADE.deb
Scripts/linux/test-native-deb.sh FIRST.deb UPGRADE.deb ubuntu-24.04
```

输入限于 `Build/Linux/debian/`，测试只在既有隔离容器执行。实际记录与哈希见 [Debian 候选包证据](../../Evidence/LinuxHost/2026-10-17-native-deb/README.md)。新包没有安装到 linux-host，RustDesk 和现有 FarPane 保持原状。

这不是 Debian 13、Fedora/RPM、真实 GNOME/KDE/Wayland、硬件媒体、长稳或完整内存验收。正式发布仍需完整依赖许可证/对应源码与 Linux CI；当前 bundle 的既有源码和新控制脚本不能替代完整发布审计。
