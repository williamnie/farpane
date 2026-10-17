# FarPane Linux GPU 媒体重构（hermes）：密码库与设备名称检查点

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40b`。这是原生 GUI 的一个功能检查点，完整 GUI、安装包及用户验收仍未完成。未安装或启停现有服务，未操作宿主桌面/显示/音频/密码库，未改 Mac 或 xuanwu；未重建 FFmpeg，未提交/push/deploy。

## 实现与最终结果

视频和文件认证共用系统密码库控件，默认不保存，显式读取，认证后才保存。错误密码、验证码不保存；待保存副本有界且丢弃时覆盖。最多两个按需工作线程，带取消和认证代校验，GUI 不等待阻塞调用。库通过 dlopen 按需加载，ELF 没有 libsecret 的硬依赖；没有明文配置回退。

服务器范围、公钥和设备标识共同隔离凭据。认证页与设备页均可确认删除；设备记录和密码可以分别忘记，也可先删除密码再提交带 revision 的记录删除。跨存储失败不冒充原子回滚。读取期间改用手动认证时，旧结果不能回填，成功认证的新密码仍可在旧读取取消后保存。

锁定时不主动请求 Unlock，明确提示先在系统密码管理器解锁；保存要求现有未锁定的默认 collection。锁定读取、保存、删除返回 status 2，密码库/记录保持存在，不把锁定视为不存在或删除成功。默认 collection 初始化及其他提供者仍须实测。

远端主机名从认证后的 PeerInfo 取得，限制长度、去掉控制字符；会话标题和设备记录显示/搜索该名称，用户别名优先。首次实际呈现后通过唯一配置 owner 持久化，旧记录字段缺省可读。

| 最终运行 | 实际检查 |
| --- | --- |
| `20261016T175246Z` | 五轮实际软件视频连接：错误密码不保存、成功后保存、第二 GUI 读取、暂停密码库后取消并手动连接、读取期间手动输入、删除后手动连接；设备页搜索主机名、取消删除、只删密码保留记录、同时忘记记录/密码；不同公钥/设备凭据保留 |
| `20261016T175326Z` | 无 libsecret 的隔离镜像中，两轮手动认证与实际 GTK 画面通过 |
| `20261016T175343Z` | 文件窗口认证后保存、真实上传下载及 SHA-256、逐次确认/取消、Host 配置保留；文件 worker 回收 |
| `20261016T175402Z` | canonical C 桥拒绝超过 4096 字节的值、未锁定删除；真实密码库锁定后读/存/删均拒绝；两轮实际 GUI 提示被锁定后手动连接并显示画面，未启动系统解锁提示，服务及记录保留 |

四轮运行的 `test-binaries.json` 与 `source-state.json` 的 GUI/core 哈希逐一一致。测试使用普通用户、私有 D-Bus/GNOME Keyring、两个私有 Xvfb、loopback 和合成密码；没有宿主总线、显示、GPU、用户配置或密码库挂载。`runs/` 保存原始事件、截图、进程 maps/PSS、文件与密码库结果。payload 和测试共享库只记哈希，不复制，可由 canonical 测试生成；不跟随符号链接。

22 项协议、3 项 GUI、27 项配置、5 项 staging 测试通过；native core/GUI Release、旧 Flutter/GPU 组合 cargo check、pin/patch/overlay/lock 核对通过。旧代码编译仍有既有 warnings，不称为零警告构建。

## 中间失败与处理

- `172718Z`：私有登录 collection 启动方式不正确。改为单个 foreground/unlock 测试 daemon，通过 stdin 提供合成解锁值，之后正常保存/读取通过。
- `172807Z`、`173310Z`：实际删除成功，但测试驱动重复对同一对话框发出确认，导致连接前超时。修复驱动的单次确认，保留原始失败记录。
- `174024Z`：测试 C 共享库放在刻意 noexec 的私有 runtime，无法加载。移到生成产物目录 Build，不放宽 runtime 挂载权限。
- `174118Z`：旧实现连续取消 Unlock 触发私有 GNOME Keyring 50 `gkd-secret-unlock.c:243` 的 `!self->current` 断言退出。最终实现不发起 Unlock；锁定时拒绝操作并允许手动连接，最终锁定矩阵通过。不能据此声称旧自动解锁交互通过。
- `174504Z`、`174929Z`：测试用第二个 daemon CLI 未能解锁已锁定的 collection。最终锁定测试仅验证产品实际支持的拒绝/手动连接路径；没有把该 CLI 当作已验证的桌面解锁。真实系统管理器解锁仍为未验收项。

中间成功运行同样保留，但只以表中四项作为最终版本结果。部分早期 locked/unavailable 模式继承了通用 `wrong-password-retry` 报告标签，实际上没有执行错误密码；最终脚本与最终报告已修正这一标签。

## 资源与未验收

最终正常密码库五轮的同步 PSS 样本：GUI 137,313–147,381 KiB，Viewer 13,783–14,125 KiB，Host 125,000–127,365 KiB，私有密码库 4,843–4,989 KiB。不同角色的区间不直接相加当作同一时刻测量；逐轮完整数据见 `process-sample.json`。样本是 640×480 软件媒体与 Xvfb/Cairo，不包含 root 服务、GPU 或宿主桌面。它不是首页 60 MiB、1440p GPU 或 20 轮长稳验收；尚未达到的内存目标没有被放宽。

KWallet 等其他提供者、真实桌面的手动解锁与默认存储初始化、2FA、配置/服务迁移矩阵、入站审批/通知/SNI/后台生命周期、富剪贴板、完整 HUD/诊断、真实媒体与桌面矩阵、跨发行版 ABI、完整打包仍未完成。`runtime_ready=false`。libsecret 头文件和 GNOME Keyring 仅加入隔离 builder/test 镜像，未安装到宿主；最终发布依赖范围仍须验证。

```sh
python3 -B Scripts/linux/prepare-native.py --check
Scripts/linux/test-native-viewer.sh secrets
Scripts/linux/test-native-viewer.sh secrets-unavailable
Scripts/linux/test-native-viewer.sh secrets-locked
Scripts/linux/test-native-viewer.sh secrets-boundary
Scripts/linux/test-native-viewer.sh files-secrets
```

详细行为与公开 API 依据见 [密码库合同](../../../Linux/docs/credentials.md)。
