# FarPane Linux GPU 媒体重构（hermes）：原生安装事务

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40b`。本轮完成新安装器的隔离实现：root 私有暂存、只读计划、协调本产品进程的维护切换、P1 回退与 journal 恢复，以及普通用户菜单、图标、D-Bus、已知旧 autostart 的独立迁移与恢复。宿主没有安装原生版，仍为 `runtime_ready=false`；完整 GUI 交付目标继续。

## 最终结果

- Ubuntu 26.04 / Python 3.14：`runs/20261016T232802Z`，24 项事务检查全部通过。
- Ubuntu 24.04 / Python 3.12：`runs/20261016T232834Z`，同样 24 项通过；使用带源码/二进制哈希的既有进程夹具，运行镜像没有安装编译器。
- 两个环境都用真实开发包完成同一安装器的暂存、私有文件激活、普通用户 GUI/core probe、同 release 私有库加载、图标/菜单/D-Bus 绑定和 GIO desktop 读取。root supervisor 没有启动。
- 实际进程、信号、pidfd 和文件事务是真实的；**服务管理器是替身**，不能据此宣称 systemd、logind、root 用户监管、重启或桌面切换验收通过。systemctl 输出解析另覆盖精确 MainPID、drop-in/别名拒绝、missing-unit 和总线故障的区别。

测试覆盖：stage 保持旧服务/用户进程与 unit/current 不变、暂存禁止普通用户执行、升级/回退关闭双方旧代进程、启动失败恢复、五个 durable 阶段中断、收紧目录权限至 rename 之间中断、unit 写入至 current 切换之间中断、初次安装失败恢复无 unit/入口、未知角色/额外活动代/删除 executable 拒绝、并发锁、保留管理员与用户在事务之外的修改、普通用户来源转换为 root-owned 副本、未退出用户进程不发送 SIGKILL。每项均保留独立无关 RustDesk 名称进程与随机配置样本，验证不被停止或修改。

普通用户事务使用实际 UID 1000、真实 FarPane 图标和模板，检查重复执行、旧菜单/autostart/图标完整回退、七个文件/提交中断点、未知入口拒绝、符号链接祖先拒绝，以及 system current 不匹配时拒绝回退。恢复记录只保存在测试用户自己的私有 state，不启动 GUI 或总线。

## 产物与边界

开发包为 `farpane-native-dev-51d4c2b0bb05647cc5f5494f`，tar.gz SHA-256：`3a4a702023047f86f14a58d85c1f1e151f7b8d07186fe72df56f52541248ef7e`。264 个清单条目包含安装工具与本轮 canonical 源码/文档。GUI、核心和 libdrmtap 与上一检查点通过软件视频/GPU 测试的包逐字节一致；构建 receipt 与随包源码核对通过。本轮未重编译、未使用 GPU，四个 FFmpeg 静态库大小/mtime/SHA 保持不变。

所有运行均在无网络、私有 PID namespace 与 `/opt` 的已有容器镜像中。SYS_PTRACE 仅用于容器内读取真实普通用户进程身份，没有挂载宿主服务、桌面、用户总线、GPU 或配置。宿主 FarPane 仍为原 P1，MainPID 3212867、current 路径和 disabled/active 状态与开始时相同；没有修改原 RustDesk，没有 commit/push/deploy，也没有调用其他代理实现。

## 已保留的失败与局限

早期夹具漏建 lib 目录、复制服务模板时继承了 0664 权限，均被正常拒绝；修正夹具为标准目录/0644 后通过。新增“其他活动代拒绝”后，一个仅传 GUI 路径的删除 executable 测试先碰到真实 core，检查集合改为包含完整同代入口；产品拒绝规则未放宽。相关原始事务失败日志保留在 runs。

首次实际包测试试图调用镜像未安装的 desktop-file-validate，得到 PermissionError（搜索 PATH 含不可访问目录）；该失败的终端栈未由当时脚本落盘，此处为说明而非伪造原始日志。后改为实际 libgio 的 desktop parser，无需新包且不启动应用；最终通过。测试入口现在会将后续整个运行的异常另存 error.txt，避免只记录事务子集成功。

完整真实服务/后台生命周期、root 与 user 两端显示会话、实际发行版桌面、完整媒体/内存预算、deb/RPM/AppStream/Linux CI、完整依赖许可证与源码发布仍未完成。真实宿主切换应在产物及其他独立工作完成后报告维护窗口。操作合同见 installation-contract.md；这里的测试替身不代替该窗口。

原始开发 tar.gz 与 ELF 进程夹具留在 Build/Linux。归档包含 manifest、build receipt、各轮日志、夹具哈希、系统/Python 信息和 canonical 源码哈希；evidence-sha256.json 固定本轮归档。旧证据目录未改写。
