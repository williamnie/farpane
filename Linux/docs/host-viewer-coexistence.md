# FarPane Linux GPU 媒体重构（hermes）：Host 与 Viewer 并存检查

2026-10-17。同一 `.8` 原始候选完成两个独立端点的真实双向软件视频连接，九项检查通过。此前单端 loopback 的入站审批测试不能单独证明两个端点的生命周期独立；本轮补齐这一范围，没有修改产品、重编或替换候选。

## 环境与方法

固定 `native_builder` 镜像、断网容器、4 CPU / 12 GiB；不挂载宿主显示、GPU、输入、音频、配置或服务接口。两个端点分别使用 UID 2201/2202、独立 HOME/XDG 目录、私有 D-Bus、不同本机身份和合成密码。Host 的私有 Xvfb 为 `:91`/`:93`，GUI 为 `:92`/`:94`；软件采集 640×480，GUI 1020×720。两端直接监听容器 loopback 的 21118/21119，不连接现有 hbbs/hbbr。

从校验过的 bundle 复制到容器内 root 所有的不可变 release；GUI、Host、Viewer 均以各自普通用户运行。GUI 不使用内部 smoke 控件，连接、输入密码、断开和关闭窗口均通过外部 XTest。Host 开关使用原有鉴权 `--config-cli`；入站断开仅使用真实 GUI 按钮，没有扩大配置命令权限。

每一阶段改变远端合成桌面的色块，等待 GUI 像素与新颜色匹配。阶段记录同时保存 Host PID、入站连接编号、GUI/Viewer 的可执行路径、UID、PID 和 start ticks；关闭与重开部分通过进程和配置断言、截图及 Viewer 日志记录。不是只检查旧画面或连接状态文本。

## 结果

| 操作 | 实际结果 |
| --- | --- |
| A 控制 B，同时 B 控制 A | 两端各一条已认证入站和一个出站 Viewer，均显示新画面 |
| 两端关闭“允许连接本机” | 两个新连接监听均停止 |
| 关闭接入后继续更新画面 | 两条现有入站和出站继续，Viewer 身份不变 |
| 两端重新允许接入 | 监听恢复，两条画面继续，Viewer 不替换 |
| A 的“本机连接”中断开入站 | B 的出站 Viewer 回收，A 的出站继续显示 B 的新画面 |
| B 再次连接 A | 创建新的 B Viewer，恢复双向画面 |
| 关闭 A GUI | A 自己的 Viewer 回收；A Host 和 B→A 连接保留，B 继续接收 A 的新画面 |
| 重开 A GUI | 新 GUI 回到首页、没有 Viewer 子进程，B→A 画面继续 |
| 退出两端 GUI | Viewer 全部回收，两个 Host 仍存活，身份、认证和服务器配置不变 |

通过轮为 `20261017T083137Z`。原 Host PID 为 27/78；A Viewer 为 223，B Viewer 从 262 断开后变为 354。双向阶段匹配颜色像素约 152,144–157,664，阈值为 70,000。计数来自私有夹具，不能推导真实画质、帧率或延迟。断开后的即时对话框截图可能早于 UI 列表下一次刷新，本轮不宣称已测列表刷新期限。

前序夹具失败均保留：第一轮在清理顺序中出现 Xlib I/O 致命退出；修正后，第二轮明确显示 `config-cli` 拒绝入站断开（`Command is unavailable offline`），这是角色边界；第三轮手动校准文件因生成目录属主而未写入，60 秒等待超时。随后改为真实 GUI 操作、固定私有窗口坐标，并修正输出属主与清理顺序。没有放宽产品权限或掩盖这些失败。

## 重现与范围

```sh
Scripts/linux/test-native-coexistence.sh \
  Build/Linux/artifacts/farpane-native-dev-3f68a4bc59ff54565b6a31db
```

Canonical 为 `Linux/tests/native_coexistence_smoke.py`、`native-coexistence-layout.json` 与上述脚本；共享 `native_lifecycle_smoke.Display` 仅扩展允许的私有显示编号。输出位于 `Build/Linux/native-coexistence-smoke/`。原始失败、成功、截图、程序哈希及 canonical 快照见[证据](../../Evidence/LinuxHost/2026-10-17-native-coexistence/README.md)。

产品构建 receipt、raw/packed GUI/core、Deb、bundle 和源码归档继续使用 `.8`，没有新版本。新增诊断文件不在已经冻结的 `.8` 源码包中，下一次实际打包时纳入；不重写原归档。本轮不覆盖 root 监管、真实 systemd/logind、桌面/用户切换、GPU 并发、性能或 Mac 互操作。原生维护切换仍待用户确认，首页 60 MiB 和完整方案验收状态不变。
