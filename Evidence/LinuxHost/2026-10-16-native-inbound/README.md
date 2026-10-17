# FarPane Linux GPU 媒体重构（hermes）：入站审批与出站并存

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40b`。完整原生 GUI 仍在开发；未安装、部署或提交本检查点。现有 RustDesk/FarPane 服务、配置和桌面保持原状，未改 Mac/xuanwu，未重建 FFmpeg。

## 改动

- Viewer 增加“本机连接”入口，显示待批准/活动连接数量。临时对话框复用真实 Host 状态和命令，允许、拒绝、撤权、断开入站连接；无需先退出出站画面。对话框关闭不等于批准，不停止 Host。
- 会话控件绑定以弱 widget 为生命周期锚点，跨 Home/Viewer 切换仍能更新有效对话框，关闭后清除失效回调。该实现没有把反复打开的回调永久留在控制器中；20 轮组合内存验收仍未完成。
- Viewer 对远端人工批准请求明确显示“等待远端允许连接”。不要求用户凭空输入密码，也不把等待批准当作已有画面。
- GUI 命令绑定发起时观察到的 Host generation。后台重连后拒绝旧操作，禁止把旧审批改为新 generation 发送；错误时清除尚未交付的旧快照。新增单测以实际 Unix socketpair 验证旧/未知代的审批没有发送字节。真实 agent 重启与旧请求并发重放尚未单独完成。

## 真实验证

`20261016T180800Z` 在隔离容器、普通用户、两个私有 Xvfb、无外网/GPU/宿主 socket 中运行同一个 Host。GUI 同时作为出站 Viewer 和本机入站管理界面，连接真实 loopback 网络，使用实际 GTK 按钮与受保护控制 IPC。

| 流程 | 证据 |
| --- | --- |
| 允许 | 批准前未呈现，批准后收到并呈现真实软件帧；实际键鼠撤权按钮使 Host 和 Viewer 权限都变为 false；实际断开按钮结束连接，worker 回收；约 5.8 秒 |
| 拒绝 | 实际拒绝按钮结束未授权连接，没有接收/呈现帧、没有写入最近记录；约 4.4 秒 |
| 无人处理 | 关闭管理对话框、不作批准；既有 30 秒审批超时结束连接，没有任何帧，worker 回收；包含启动/建立连接约 34.2 秒 |

三轮 Host 均保留，身份、认证、共享、GPU 与服务器配置不变；只有成功呈现的一轮写入最近设备。实际审批对话框截图已检查。它证明“尚未作出决定”的超时，不冒充 GUI 完全退出后通知/自动激活、root/greeter 或不同用户登录切换测试。

最初 `20261016T180628Z` 的批准/撤权/断开已经完成，但测试未等待对话框绘制就点击按钮，缺少要求的截图。修正驱动等待实际截图后再决定，重跑完整三轮；失败日志原样保留。

| 回归运行 | 结果 |
| --- | --- |
| `20261016T180939Z` | 键鼠、中文 IME 单次提交、预编辑不外发、失焦/断开松键、工具栏操作不发给远端，通过两轮实际连接 |
| `20261016T181006Z` | 五轮密码库真实连接、设备编辑/删除/搜索与隔离记录检查通过 |
| `20261016T181046Z` | 文件实际上传下载、覆盖拒绝/允许、本地覆盖对话框、进行中写入撤权、退出状态与 SHA-256 通过 |

以上四次 `test-binaries.json` 均与归档 GUI/core 哈希一致。Host 生命周期、普通 GUI 关闭/重开与设备页、离线配置 helper、身份认证回归通过；其原始结果单列 `host-regression/`。GUI 4 项单测、native core/GUI Release、旧 Flutter/GPU 组合 check、51 个 canonical 文件和 pin/patch/overlay/lock 核对通过。旧核心已有 warnings 保留。

## 未验收与下一步

权限撤销时已经按下的键在实际远端释放、不同权限/并发请求的全部组合、后台崩溃重启与旧请求、GUI 完全关闭的通知/D-Bus 激活/SNI、后台注册、睡眠网络恢复、富剪贴板、完整 HUD/诊断、实际桌面/媒体与长稳资源、完整安装包仍未完成。不能把当前 IPC 单测当作所有重启竞态已验收。

`logs/native-inbound-abi-symbols.json` 记录两项 ELF 的最高直接 glibc 需求均为 2.39。只核对直接符号版本不能证明 Ubuntu 24.04 或整个依赖闭包可用；GTK/libadwaita/媒体依赖仍需目标容器与桌面验证。首页 60 MiB 以及其他预算没有被放宽。`runtime_ready=false`。

```sh
Scripts/linux/test-native-viewer.sh approval
Scripts/linux/test-native-viewer.sh input
Scripts/linux/test-native-viewer.sh secrets
Scripts/linux/test-native-viewer.sh files-matrix
Scripts/linux/test-native-host.sh
python3 -B Scripts/linux/prepare-native.py --check
```
