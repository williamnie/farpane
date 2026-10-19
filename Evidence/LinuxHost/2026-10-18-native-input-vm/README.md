# FarPane Linux GPU 媒体重构（linux-host）：私有内核与 Viewer 授权提示

2026-10-18 UTC，`codex/linux-host-gpu-media`，HEAD `0b73812` 加保留的未提交修改。用户离开期间无人值守推进；没有切换当前服务或用户桌面，没有访问宿主输入/GPU，没有修改 Mac、RustDesk 或 xuanwu。

本轮修正一个单独的原生 Viewer 状态错误：Wayland Host 的“请在远端选择共享屏幕”提示被误解释为连接失败。`.2` 原始 GUI 连接复现，`.3` 在相同私有 guest 中保持等待授权且 Viewer 未退出。**中文到 Warp/Chrome 的实机缺陷仍未关闭。**

| 证据 | 实际范围 |
| --- | --- |
| `bootstrap-failed/` | 首次 guest 已启动到 PID 1，重复挂载 devtmpfs 失败，未执行输入 |
| `bootstrap-passed/` | 修正挂载后，真实 guest uinput→evdev 的 A-down/SYN/A-up/SYN 完整读回 |
| `root-host-passed/` | `.2` 原始 root 服务、UID 1000 Host 经真实特权 IPC 创建产品键盘；此镜像还缺 Xwayland，不能算完整桌面 |
| `viewer-before/` | 补齐 Xwayland/PipeWire/portal 后，`.2` 实际连接、错误密码重试，屏幕选择提示被显示为失败；测试随即退出，不能认定网络已断开 |
| `viewer-after/` | `.3` 原始 GUI/Viewer/Host/root，同样的提示保持 Authenticating，不提前授予权限或谎报出图 |
| `viewer-ui-unit.log` | 2 项状态映射单测，包括随后错误和三种近似错误消息 |
| `guest-guards.log` | 3 项 guest 入口保护，在任何宿主挂载/设备打开/服务启动前拒绝普通进程 |
| `package-ubuntu2404.log` | 8 项包/ELF/路径检查，随后两次真实私有软件视频连接 |
| `deb-ubuntu2404.log` | 6 组实际 dpkg 安装、`.2 → .3` 升级、恢复与 purge 保留；升级后再两次软件视频连接 |
| `build-receipt.json`、`app-build.log` | canonical/pin 与生成源码一致；增量核心 Release，GUI 和 FFmpeg 复用 |
| `source-archive-verification.json` | 完整归档 91,478 条目逐项核验，1,082 个 vendor 包；不是再次完整冷构建 |
| `source-metadata-verification.json` | 断网、空 Cargo home、没有仓库或旧编译缓存挂载，core/GUI 图全部解析到源码快照内 |
| `installed-state.json`、`installed-activity.json` | 当前 `.1` PID 64215/70886 保留，1 条已认证入站；RustDesk inactive/disabled |

`busy_count=4` 是保护工具将入站、CM 文件工作 owner 和媒体 owner 相加的活动计数，不是四条连接或四次文件传输。最新 guest 中 `mutter_input_fds=[]`，headless Mutter 未读取物理输入节点；本轮只验证内核微测、产品设备建立和 Viewer 提示，不把它们拼成完整中文输入成功。

产物：`farpane-native-dev-d393fd0cff634416807feae5`；Deb `0.1.0~dev.20261018.3`，18,819,724 字节，SHA-256 `476f189cac60495be8b54fad2e0c8070bf904cdfa3420af7af1baa72f68bea64`。包内 core SHA `c57fc5dd5755c2caf6e7780d5bf2cc33459b1629949079d2d9eedb17fcf62f6b`，GUI SHA `9e57d7b3540b4282bcf23837d2bd05fc082f5da45a729f9d8f0e09a61984a421`。当前没有 stage/activate、commit/push。

完整源码 `farpane-native-source-704f37fe999ad9f837832f79.tar.gz`，SHA-256 `88bcdffdf6d246e02a7979e5653bfe111ace4c7e730f69bf66efeca1ddda09ba`，应用源码与当前二进制构建记录逐项一致。源码收集后补充的验收结果文档不改变归档中的应用代码。712 个依赖和 45 条未关闭材料记录与 `.2` 相同；打包第一次因旧材料清单绑定旧二进制被拒绝，重新生成真实清单并核对依赖/问题逐项相同后更新 pin，第二次通过，没有绕过检查。

`image-build-2.log` 保留一次构建上下文选错、因私有目录权限而在构建前退出的失败；后续 `image-build-3.log` 只通过 stdin 传 Dockerfile，使用空上下文。镜像从原缓存层增量补依赖，未安装宿主软件。QEMU 只开放 KVM，4 vCPU/6 GiB RAM，未配置虚拟网卡；guest loopback 用于私有连接。基础磁盘、overlay 和各次完整产物留在 `Build/Linux/native-input-vm/`，不纳入 Git。

主要复现命令和后续完整输入测试缺口见 [native-input-vm.md](../../../Linux/docs/native-input-vm.md)；当前候选和维护窗口边界见 [native-test-candidate.md](../../../Linux/docs/native-test-candidate.md)。本轮未重新验收 GPU、内存、真实 logind/桌面、Mac 输入法、Warp 或发布门槛。
