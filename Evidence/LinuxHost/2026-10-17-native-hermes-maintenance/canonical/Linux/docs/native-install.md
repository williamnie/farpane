# FarPane Linux GPU 媒体重构（hermes）：原生安装与回退

原生安装分为 root 的 release/服务事务和普通用户的桌面入口事务。canonical 实现在 `Linux/packaging/native_install*.py`、`native_user_install.py`，入口在 `Scripts/linux/install-native*.py`。现已在授权维护窗口完成 hermes 的真实 systemd/GNOME 用户桌面切换，用户确认 Mac 入站画面和键鼠正常；详情及权限迁移修复见[实机记录](native-hermes-maintenance.md)。用户切换、greeter、重启和真实回退仍未验收，开发包保持 `runtime_ready=false`。

## 暂存与计划

`install-native.py stage ARTIFACT` 在 `/opt/farpane/.staged` 中建立 root 私有的校验副本。源目录可属于普通用户；安装器固定 manifest 字节，通过逐级 `O_NOFOLLOW` 目录 FD 复制，限制文件数、单文件与总大小，并验证每个文件的长度、SHA-256、权限与受限媒体库别名。目标不继承源所有者、ACL、xattr 或硬链接。源目录中的符号链接目录、特殊文件、清单外文件和复制期间改变的内容被拒绝。

stage 保持 current、服务、进程、菜单和用户配置不变。相同包重复暂存不会覆盖已有 release；私有暂存目录不能由桌面用户启动。它不自动升级，也不改变现有服务的开机启用状态。

`install-native.py plan RELEASE --expect-current PREVIOUS` 使用共享只读锁，检查精确的旧版本、服务单元及进程身份。必须先 stage；第一次安装用 `--expect-current none`。输出仅包含版本、服务状态、PID/UID/角色/start ticks，不输出进程参数或密码。

## 维护窗口中的系统切换

以下为维护窗口接口示例；每次操作应绑定当时真实的新旧版本：

```sh
sudo python3 -B Scripts/linux/install-native.py stage /absolute/path/to/artifact
sudo python3 -B Scripts/linux/install-native.py plan NEW_RELEASE --expect-current OLD_RELEASE
sudo python3 -B Scripts/linux/install-native.py activate NEW_RELEASE --expect-current OLD_RELEASE --maintenance-window
```

activate 使用独占锁与 durable 恢复记录。先将新旧 release 根目录设为 root 私有，阻止普通用户从旧菜单或 autostart 启动另一代；再停止验证过的 `farpane.service`，通过 pidfd 终止已识别的 GUI、Host、Viewer、旧 CM/托盘角色并等待退出。其他产品进程不会进入停止集合。未知角色、额外活动代、已删除 executable、unit 别名/drop-in 或身份不一致均拒绝。普通用户进程超过期限仍未退出时失败，安装器不发送 SIGKILL；systemd 对其服务 cgroup 仍按原单元自身的停止策略工作。

确认没有残留后绑定精确 release 的 systemd 单元，原子替换 current 和产品入口，重新加载单元，开放新 release，再恢复原来是否运行的状态。首次安装默认不启动；明确添加 `--start-service` 才启动。root 服务至少连续三次检查保持相同 MainPID/角色，随后提交安装记录。这个检查只验证 root 进程，不能证明用户 agent、采集或远程连接已经就绪。

旧版本保留原字节，仅收紧目录访问权限；不会清理回退版本。当前仅接受已经具有 `linux-gpu-media` 的 P1 legacy release 或 native release，拒绝 B0 回退。普通用户的 ID、密码、密钥和共享配置不被安装器读取、复制或修改。

异常时自动尝试恢复旧单元、current、目录权限、安装记录及原运行状态；无法恢复则保留 journal 并明确报错。主机重启或安装进程被中断后，用 `install-native.py recover --maintenance-window` 显式恢复。已 durable 提交且目标健康的事务仅清除残留 journal，不撤销成功安装。恢复前复核 unit/current/安装记录，拒绝覆盖管理员在事务之外的修改。

显式回退也调用 activate，以旧 release 为目标、新 release 为 `--expect-current`。这会经过同样的维护窗口、进程协调及身份检查，不是手动替换符号链接。root 恢复和用户入口恢复分开记录。

## 普通用户的菜单、图标和 D-Bus

系统切换成功后，以桌面用户运行：

```sh
python3 -B Scripts/linux/install-native-user.py bind NEW_RELEASE --previous OLD_RELEASE
```

首次安装的 previous 为 `none`。用户安装器核对系统 current/安装记录和完整 native manifest，再安装 FarPane desktop、两个图标和 D-Bus 激活入口，绑定同一不可变 release。默认遵循 passwd home 和绝对 XDG data/config/state 目录；拒绝路径中的符号链接、非本用户条目、硬链接和其他用户可写的祖先目录。它不使用 sudo，也不启动 GUI、Host 或用户总线。

旧系统安装器写出的精确 FarPane 菜单可迁移；后续 native 文件须匹配本用户安装记录的哈希。只有已知旧 FarPane tray 内容或精确受管理的 FarPane autostart 才移除，不创建隐藏 GUI 自启动。陌生菜单/autostart 原样保留并报错，RustDesk 文件从不纳入操作集合。没有托盘支持时仍可从应用菜单打开 FarPane。

每次更新先保存包含原字节的私有 journal，再逐项原子写入；提交后保留独立 backup，不递归嵌套历史。重复 bind 同一 release 幂等。中断后用 `install-native-user.py recover` 恢复原文件或完成已提交事务；系统已回退至前一版本后用 `install-native-user.py rollback` 恢复该版本的菜单/autostart/图标和上一份记录。用户在安装后自行改过的文件不会被回退覆盖。

root 安装记录中的 `user_integration_required=true` 表示每个桌面用户都需独立完成此步骤，不由 root 猜测或写入其他人的 home。

bind 会创建或收紧本产品配置目录为 0700，保留配置文件字节及无关祖先目录权限；该加固在桌面入口回退后仍保留。0775 的桌面目录仅在主组经 NSS 确认为单人私有组、且没有 access/default 扩展 POSIX ACL 时允许。ACL 读取异常、其他用户可写、共享组与符号链接继续拒绝。本机迁移与真实 ACL、幂等/回退测试见上述实机记录。

## 隔离测试与剩余门槛

`Scripts/linux/test-native-install.sh ARTIFACT` 使用已有 builder、私有 `/opt`、PID namespace、无网络/宿主显示/GPU/服务 socket 的容器。唯一额外 capability 为容器 PID namespace 内检查普通用户进程所需的 SYS_PTRACE。进程夹具是真实 ELF/pidfd；服务管理器是替身。测试覆盖暂存无运行副作用、真实 SIGTERM/回收、P1 升级与回退、启动失败、五个 durable 阶段及目录/单元切换中断、未知角色/活动代、并发锁、管理员与用户文件修改保留、普通用户来源复制、桌面迁移与七个中断点。

真实开发包另经同一安装器暂存、私有文件激活、普通用户 core/GUI build-info 与私有媒体库 probe，以及真实图标/菜单/D-Bus 文件绑定和 GIO 桌面文件读取；root supervisor 不启动。Ubuntu 24.04 纯运行镜像可复用完成的 builder 测试所生成并带源码/二进制哈希的进程夹具，不在运行镜像安装编译器：

```sh
Scripts/linux/test-native-install.sh ARTIFACT ubuntu-24.04 Build/Linux/native-install-smoke/RUN/process-fixture
```

这些隔离测试不替代重启/登录/后台启用、多用户会话、桌面通知/托盘交互或回退后的真实连接。Debian 候选与完整应用源码包现已提供，hermes 基本切换和用户入站验收已完成；RPM、完整依赖许可审计、内存目标与完整 GUI/媒体矩阵仍未完成。
