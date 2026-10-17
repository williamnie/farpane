# FarPane Linux GPU 媒体重构（hermes）：原生 GUI 实机切换

2026-10-17，北京时间。用户明确授权进入维护窗口后，hermes 已从旧 P1 FarPane 切换到 GTK4/libadwaita 原生版。用户随后在 Mac mini 使用原 ID **1709575223**、自己的固定密码连接，并确认“画面和键鼠正常，保持连接”。这次通过的是 Mac → Linux Host 的基础实机验收，不是 Linux Viewer、完整功能或性能预算验收。

分支仍为 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。没有 commit、push、发布、修改 Mac/xuanwu 或重建 FFmpeg。

## 运行状态与迁移

- 当前 `/opt/farpane/current`：`releases/farpane-native-dev-e7508f297ef1d671172d7737`，原 `.9` 应用 payload。
- 旧版 `farpane-p1-445515cfa1ec-90876510-551585f0` 保留，可通过安装事务回退；没有在本次连接期间试回退。
- `farpane.service` active，root PID 1413675，NRestarts=0；保留原来 disabled 的开机策略。桌面 Host PID 1415880。
- GUI 经真实用户 systemd/D-Bus 环境打开，初始 PID 1418597，生命周期检查后 PID 1434762。图标、菜单和 D-Bus 激活文件已绑定同一 release。
- ID、加密身份、固定密码字段、salt、密钥及 ID/中继服务器字段与迁移前私有备份逐项相同。公开证据只保存比较结果，不保存值。
- 用户明确说明 RustDesk 是自己手动停止的。检查时其服务 inactive/disabled；本任务没有启停或重新启用它，也没有动自建 hbbs/hbbr。

安装使用工作区中的 `stage → plan → activate → bind`，仅在 `/opt` 和 FarPane 自身服务/用户入口范围操作；没有在宿主执行 dpkg、安装 FFmpeg 或写 `/usr`。实际桌面是 GNOME Wayland；未改显示模式、锁屏或休眠。

## 实机发现与修复

旧用户 FarPane 配置目录为 0775，native owner 拒绝启动。仅将该产品目录收紧至 0700；root 的 FarPane 目录也从 0755 收紧至 0700。凭据内容未改。用户图标目录同为 0775，但属于经 NSS 核对的单人主组；原安装器错误拒绝这一正常布局。

`Linux/packaging/native_user_install.py` 现在检查主组名称、补充成员和其他账户的主组，允许没有扩展 POSIX ACL 的单人主组目录。共享组、world-writable、扩展 ACL、符号链接、错误 owner 和硬链接继续拒绝，ACL 读取异常也拒绝。普通用户 bind 在内容验证后将 **FarPane 自身配置目录**设为 0700，不改任何配置文件内容或无关祖先目录；首次安装建立空的私有目录。幂等 bind 同样执行检查。配置目录权限加固在桌面入口回退时保留，不作为恢复宽松权限的事务项目。

实机 `~/.local/share/icons` 和 `hicolor` 原有 0775 未改变。最终安装器在本机再次 bind 返回 `already_installed=true`，没有启动或重启任何进程。

10 项权限单测通过，包括实际 access/default ACL 拒绝；25 项隔离安装事务、真实包暂存/入口绑定/媒体库探针/GIO 解析通过。事务测试新增 0775 图标与旧配置、凭据字节保留、回退仍保留 0700 的检查。服务事务测试使用容器替身；本次实际 systemd 激活证据单独记录。

初次用户 bind 的拒绝日志保留。新增测试中曾遗漏 fixture 的 `state` 属性；修正后通过。第一轮隔离事务 24 项通过，之后的真实包断言误查 `config/farpane` 而不是直接构造器使用的 `.config/farpane`，退出 1；修正该断言并保留 probe 不生成 XDG 配置的检查后，全套 25 项及真实包检查通过。没有把这些失败删除或记为首轮全通过。

## GPU 与资源实测

北京时间 **21:08:35–21:09:05**，一条真实 Mac → hermes 入站连接，采样前后 `media_backend=gpu`、无降级原因、同一已授权连接。只读 `/proc` 采样确认 Host 持有 `/dev/dri/renderD128`，AMDGPU 编码引擎累计计数在 30 秒内增加约 **5.979 秒**，计算引擎计数也增加；这证明 GPU 实际工作，不仅是配置开关开启。

| 进程 | CPU，100%=单个逻辑核 | PSS |
| --- | ---: | ---: |
| root 监管服务 | 2.17% | 39.06 MiB |
| 桌面 Host | 5.20% | 65.05 MiB |
| GTK GUI | 0.07% | 130.85–130.87 MiB |
| 同时合计 | **7.43%** | **234.97–234.99 MiB** |

这是未控制画面内容的短时连接样本，未进行旧版配对 A/B，不能外推动态视频、1440p 或延迟。PSS 不含全部 GPU 分配；原始样本另保留按 DRM client 去重后的驱动计数，不把 VRAM/GTT 简单加到 PSS 后称为整机独占内存。首页 **60 MiB 目标仍未达到**。

北京时间 21:11:56–21:12:07，停止并重建本任务启动的 GUI 用户单元，后台不重启。Host/root PID、同一授权连接和 GPU 后端保留；GUI 关闭的 10 秒内编码继续，后台 PSS 合计约 **104.15 MiB**。重新打开后 GUI 使用新 PID，连接仍在。该检查是退出 GUI 进程的实机生命周期验证，没有自动点击窗口关闭按钮，也没有另行测量 Mac 每帧呈现或重开后的稳定 GUI 内存。

只读采样入口为 `Scripts/linux/sample-native-runtime.py`，限定当前不可变 release 的进程，不读取或保存任意命令行/凭据，不执行服务或 GPU 控制命令。

## 安装包与来源

最新 Debian 候选：`Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261017.11_amd64.deb`，18,714,628 字节。

SHA-256：`5305789932d492224d21d726fcfa64308b77cd8c6b8816c43074f86981f517a8`。

`.10` 是第一版安装权限修复包，`.11` 增加 ACL 拒绝与权限迁移说明；旧包均保留。`.11` 的 GUI/core/媒体及完整 payload 与 `.9` 逐项相同，新增安装器完整 Python 源码在 Debian `control/` 中，已逐文件核对 canonical 哈希。无需再次切换正在运行的应用。没有重复未变化的完整 dpkg/媒体矩阵，最终安装器已做上述针对性回归。

`.9` 完整源码归档 `farpane-native-source-a2b4ecc2bc7e4908a8c1aeb5.tar.gz` 继续对应应用；它不含本次新安装器修复、测试和采样脚本。这些 canonical 文件在工作区和本次证据中，安装器运行源码也随 `.11` 的独立控制工具交付。没有把旧归档称为包含本次全部变更。

## 尚未验收

Linux 发起到 Mac 的出站界面与真实媒体、硬件音频、中文输入/富剪贴板/文件互操作、真实托盘点击和通知交互、多桌面/多用户/锁屏/休眠/重启、真实回退、多显示器/颜色、24 小时长稳、配对完整进程性能及 60 MiB 首页目标均未完整验收。公开 CI/Release 和完整许可来源审计仍未完成，候选保持 `runtime_ready=false`，不因此否定本次已通过的基本连接。

原始记录、失败、具体检查和哈希见[实机维护证据](../../Evidence/LinuxHost/2026-10-17-native-hermes-maintenance/README.md)。配置备份仅留在受限的 Build 私有目录，未复制到 Evidence。
