# FarPane Linux GPU 媒体重构（linux-host）：Debian 候选包

分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本阶段只增加 Debian 外层打包与验证，未重建 core/GUI/FFmpeg，未安装到宿主、提交、推送或发布。完整 GUI 目标仍进行中。

## 产物

输入为已通过自动重连及 Ubuntu 24.04/26.04 包测试的 `farpane-native-dev-d0fb65c957b35a48743a82d2`。两个测试包位于 `Build/Linux/debian/`：

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `farpane-native-candidate_0.1.0~dev.20261017.1_amd64.deb` | 17,144,040 | `2557ea97b706c03dddc86b62f06c6db4221ea8afa9c643743ce44d3bb1ff5103` |
| `farpane-native-candidate_0.1.0~dev.20261017.2_amd64.deb` | 17,142,732 | `9dad5b80e4226e2e672193f3879a3b3e33019db9a56a8333b9269928dd90d8f8` |

`.2` 用于实际升级测试，媒体/GUI 内容与 `.1` 相同；两者均为测试候选，`runtime_ready=false`。`.1` 在独立临时树重新打包后 SHA-256 相同。非法版本字段和 Build 之外输出均拒绝。包内独立维护工具及来源哈希与 canonical 一致，不要求用户保留开发工作区。

## 实际结果

Ubuntu 26.04 `20261017T022326Z` 与 Ubuntu 24.04 `20261017T022401Z` 各通过六组检查：

1. 真实 dpkg 安装，依赖满足，完整候选仅进入私有暂存。
2. 独立维护/用户入口命令可用，来源哈希一致，无 Python 字节码残留。
3. 使用 dpkg 安装的 GUI/core 完成两次真实软件视频连接、错误密码重试与 worker 回收。
4. 未结束维护事务使升级配置失败，原事务、当前链接、进程和配置仍保留。
5. 处理测试事务后，真实 `dpkg --configure` 恢复成功，升级版本和清单一致。
6. purge 删除候选及命令，保留暂存、旧版本、当前链接、测试进程、两个服务文件和配置。

没有使用 `--force-depends`。保留进程是私有阻塞 shell，服务文件为哨兵，不能等同于实际 systemd 维护或当前用户连接。视频使用实际 GUI/core/协议及私有 Xvfb，没有使用宿主显示、GPU、音频、密码库或总线。

26.04 前两次 `20261017T022240Z`/`20261017T022300Z` 保留为失败：安装已成功，但用于保留检查的 sleep 夹具来自 multicall coreutils，复制改名后报 `unknown program 'farpane'` 并退出；仅改变 argv[0] 仍不足以启动。随后用阻塞于私有管道的 dash 进程作为稳定哨兵，重跑完整检查通过。没有修改产品以迎合测试。

宿主只读前后比较通过：现有 FarPane/RustDesk 服务及 PID、current、branch/HEAD 相同；FFmpeg 四个静态库 SHA-256、大小和 mtime 不变。基线来自紧接此前的 Viewer 阶段最终只读采样，结束后重新实际读取。63 个 canonical staging 文件核对与 `git diff --check` 通过。

## 实现与证据

新增 `Linux/packaging/native_deb.py`、包内说明模板、`Scripts/linux/package-native-deb.py` 和隔离 dpkg 测试/入口。既有 runtime、维护事务、GUI、共享 RustDesk 和旧安装器实现均未修改。新增依赖声明依据实际 ELF，未知依赖、二进制与清单不符、超出 ABI 基线均拒绝；没有下载或安装宿主依赖。

安装只调用既有暂存逻辑；升级/移除包不能删除已经激活的 `/opt/farpane/releases`。真正激活和用户菜单绑定仍要求已有维护流程。此语义在 Debian Description、README.Debian 和 [合同](deb-contract.md)明确说明；候选包移除不等于应用停用。

`logs/` 包含打包、独立重打包、两次夹具失败、最终运行、拒绝输入和宿主状态。`runs/` 为原始 dpkg 与实际 GUI 结果；截图保留在对应 Build 目录。实际包控制信息、输入 artifact 清单/构建记录及 315 个 canonical 哈希已归档，`SHA256SUMS` 覆盖本归档。

完整第三方许可证/对应源码、Linux CI、正式发布、真实 systemd/logind 与桌面维护、GPU/音频/跨平台、长稳及低内存仍未验收。未声称 Debian 13、Fedora、默认内核或其他桌面已支持。本检查点完成不代表完整 GUI 交付目标关闭。
