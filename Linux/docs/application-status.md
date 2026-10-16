# FarPane Linux GPU 媒体重构（hermes）：应用交付进度

## 用户最新授权

2026-10-16 UTC，用户选择沿用 Flutter，要求完成全部开发、build 并安装后由用户测试。
随后明确答复：**“允许先完成 GPU 集成，由我测试验收”**。
这取代此前“P0 所有真实连接门槛通过后才能开始 P1”的开发顺序要求。
P0 未测项目仍是未验收项，不会据此改写为通过；GPU 默认关闭。
现有 RustDesk 服务、进程、配置/ID/密钥、桌面/显示边界继续有效。没有 commit/push 授权。

## 已完成的 B0 应用

以下 B0 为保留的旧版本。**当前已安装 P1 开发版**：

- artifact：`farpane-p1-445515cfa1ec-90876510-551585f0`（包含网络身份与隐式 DMA-BUF 布局修复）。
- 入口：`/opt/farpane/farpane`；root-owned 版本目录为 `/opt/farpane/releases/<artifact-id>`。
- 菜单：`~/.local/share/applications/org.farpane.FarPane.desktop`，Exec 指向上述系统入口。
- 用户副本：`~/.local/opt/farpane/<artifact-id>`；旧 B0 目录保留。
- 服务单元：`/etc/systemd/system/farpane.service`；初次安装未激活，现已按用户后续授权启动，尚未设置开机自启。
- 核心 SHA256：`445515cfa1ece3579afc3834f8c6be500c19babc85afcc4c9d381281b7802099`。
- GPU 已编译集成，新安装运行开关默认关闭；本机已按用户后续授权开启。设置、状态、重试入口已在隔离 Xvfb 中实际检查。
- 所有可执行依赖解析、私有 FFmpeg 干净加载、root-owned 权限与安装后无副作用诊断通过。

实现和实际测试边界见 [P1 状态](p1-status.md)。当前交付尚未完成精确画质、延迟或长稳验收。

后续用户已确认新 ID/固定密码连接显示桌面。隐式布局修复后再次确认“画面正常”；
对应日志为 `LinuxGpu` / `GPU media active`，2560×1440、H.264、4 Mbps，QoS 从 15 调至 36 FPS。
这确认了本机新 GPU 管线实连出画面，仍不替代精确颜色、同步、延迟与长稳验收。
20 秒短采样中，GPU 后端/代际/已认证视频连接全程稳定；五个 FarPane 进程合计 CPU 为 7.87%，
媒体服务进程 4.03%（一个逻辑核=100%）。修复前同桌面旧路径短采样分别为 22.12%/18.68%。
未控制桌面负载、协商帧率和编码参数，不能作为正式 A/B 降幅；首次断线后的空闲样本已排除。

- 完整 Flutter Release bundle；沿用固定 Flutter 3.24.5 / Dart 3.5.4 / pub 锁。
- `farpane-linux` 构建特性：FarPane 配置目录、IPC、D-Bus 标识、桌面 runner。
- `--farpane-paths` 在配置/日志/桌面初始化之前输出路径，用于无副作用安装验收。
- 固定 libdrmtap 0.5.8 源码重建，EGL 必需、helper 禁用；FFmpeg 9.0.2 静态库复用。
- 无宿主显示/GPU/网络/服务 socket 的 Xvfb 容器内打开实际窗口并检查截图。
- 132 项 Flutter 测试、47 项 FarPane-feature scrap 测试通过。
- 源码/补丁/overlay 字节一致性、prepare 重入、安装器保留旧产物与拒绝覆盖用户文件验证通过。
- B0 应用已安装到 `~/.local/opt/farpane/farpane-b0-8e9baef0a1ef-90876510`；
  `current/farpane` 为入口，菜单项为 `~/.local/share/applications/org.farpane.FarPane.desktop`。
  仅执行无副作用路径诊断；未打开宿主 GUI、未安装/启动服务。

该旧 B0 副本不含 GPU 产品集成，保留用于回退对照。

## 构建入口

```sh
Scripts/linux/container.sh Scripts/linux/build-drmtap.sh
Scripts/linux/container.sh Scripts/linux/build-core.sh gpu
Scripts/linux/build-gui.sh
Scripts/linux/test-flutter.sh
python3 Scripts/linux/package-app.py
Scripts/linux/test-gui.sh <artifact-directory>
sudo python3 -B Scripts/linux/install-system.py <artifact-directory>
python3 Scripts/linux/install-app.py <artifact-directory> --system
```

新源码/构建/安装脚本在 `Linux/`、`Scripts/linux/`；checkout、缓存、日志和 bundle 在 `Build/Linux/`。
GUI 测试工具镜像由固定 builder 派生，安装工具只发生在镜像里；镜像 ID 记录在依赖锁。
未向宿主 `/usr` 写入文件，未安装主机 FFmpeg。

## 本阶段原路径改动范围

- Linux CMake：支持独立 Cargo target 路径，设置 FarPane runner 与 GTK application ID。
- `core_main.rs` / `platform/linux.rs`：Linux feature 限定的身份初始化薄接点。
- `server/dbus.rs`：FarPane feature 使用独立 D-Bus 名称；feature-off 保持原名。
- scrap loader：FarPane 只从自己的安装目录/相邻 bundle 加载 libdrmtap；root 只接受固定 `/opt/farpane/lib`，不扩大 root 搜索路径。
- B0 当时仅增加 root/scrap Cargo feature 宣告；当前 P1 的必要接点详见 P1 状态中的变更面清单。

## 自建服务器连接修正（2026-10-16 UTC）

用户进一步确认 Mac mini 使用 hermes 自建 ID/Relay 服务器。此前 FarPane 仅在公共服务器注册，
无法证明能被现有客户端找到；已只配置 FarPane 的服务器地址及 hermes 服务器公钥。

本机域名 `pan.cicadacode.com` 被解析为代理地址。实际中继配对探针通过局域网地址成功，
局域网与域名两端配对超时。FarPane 因此使用 `192.168.50.44:21116` 和 `192.168.50.44:21117`；
原服务器、代理和 RustDesk 客户端配置均未修改。只读取自建服务器的容器监听信息、公钥及相关连接日志。

改为局域网注册后，Mac mini 的连接已到达 FarPane 并通过传输握手；随后用户报告密码错误。
发现 FarPane 原有选项为 `verification-method=use-permanent-password`，因此先前读取的临时密码未启用。
**临时密码接口有返回值不代表该密码可用于认证**。用户明确选择自己设置的固定密码；保持原模式且不覆盖密码。
随后服务端确认已认证的 H.264 视频连接，用户确认“已显示桌面”。GPU 首次仍回退旧路径，
原因与修复见 [隐式布局修正](implicit-layout.md)。

## 同机 ID 冲突修复（2026-10-16 UTC）

首次连接发现 FarPane 与原 RustDesk ID 相同。配置路径隔离并不能隔离上游的 MAC 派生 ID/machine-id 注册身份；
先前交付漏掉了这项检查。现已安装网络身份修复版：本地一次性迁移到独立随机 ID，注册 UUID 加 FarPane 命名空间，
不发送旧 ID 重命名请求，不改变本地密码加密。细节和改动面见 [网络身份修复](network-identity.md)。

隔离实际程序测试通过：新配置持久化、旧冲突 ID 迁移、重启 ID 稳定、GPU/服务器选项保留。
本机新 ID 注册在线且密钥确认，root/user 身份一致；已重启独立服务复核并重新打开 GUI，GPU 保持开启。
现有 FarPane 密钥/永久密码存储与备份一致；原 RustDesk 未控制或读取配置。该身份修复检查点尚未验收真实媒体流。
旧 P1/B0 产物保留归档；在线 CPU 对照应使用修复版关闭 GPU，不能再用缺少身份修复的旧产物。

## 已授权的首次启动（历史记录，2026-10-16 UTC）

用户明确答复“现在启动并开启 GPU”，授权启动独立服务和打开 FarPane 窗口。
已执行 `systemctl daemon-reload`、`systemctl start farpane.service`，从同一 `/opt/farpane/farpane` 打开 GUI，
通过该程序的 `--option linux-gpu-media Y` 管理接口启用 GPU。未启用开机自启。

检查结果：服务 active/running、重启次数 0；用户 server/tray/GUI 均来自系统版本；
主 IPC、service IPC、DRM IPC 已建立；GPU 选项持久化为 Y，状态为 enabled=true/backend=idle；
ID 服务器在线、注册密钥已确认。idle 表示等待兼容的视频连接，不代表 GPU 已处理真实桌面。
该首次启动检查点尚未设置自建服务器；后续已按上文完成 hermes 自建服务器配置。

真实连接、实际 CPU/画质/延迟仍由用户验收。未访问现有 RustDesk 的配置/ID/密钥或控制其进程，未改显示模式。
启动记录见 `Evidence/LinuxHost/2026-10-16-p1-activation/README.md`。

## 后续手动启动步骤

安装器不会运行这些命令。本机已完成首次启动；服务停止后可执行：

```sh
sudo systemctl daemon-reload
sudo systemctl start farpane.service
/opt/farpane/farpane
```

使用新的 FarPane 配置和 ID；没有自动复制 RustDesk 的服务、配置、ID 或密钥。
本机 GPU 已开启。测试时选择 H.264 编码，到 Settings → General → Linux GPU media 查看实际后端/原因。
需要退回旧媒体路径时关闭开关。停止本次测试的独立服务可使用 `sudo systemctl stop farpane.service`。

此启动会创建 FarPane 的用户进程/托盘并使用桌面；首次启动已获得用户明确授权。
原 RustDesk 不需要停止、替换或切换。没有修改显示模式、Mac/xuanwu 目录，没有 commit/push。
