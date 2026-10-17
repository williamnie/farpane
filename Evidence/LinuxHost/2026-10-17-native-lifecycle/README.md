# FarPane Linux GPU 媒体重构（linux-host）：Viewer 生命周期证据

本轮只增加隔离测试与诊断，原 `.5` 程序未改变。测试通过真实 XTest 控件操作，同一 GUI/Host 完成连接、密码验证、合成画面显示、断开返回和最后关闭 GUI；宿主服务与桌面不参与。

- 校准 `20261017T060951Z`：人工核对私有截图坐标，两轮预热加一轮测量，三个 Viewer 回收；不是二十轮验收。
- 普通运行 `20261017T061205Z`：两轮预热加二十轮，约 173.74 秒，22 个 Viewer 全部回收。GUI/Host FD 始终 12/40，软件帧映射归零；最大合计空闲 PSS 增长 2,430 KiB（2.37 MiB）。原记录的 `result=pass` 仅指已执行的回收、FD 与 10 MiB 增量检查。
- 对象诊断 `20261017T061853Z`：额外二十轮，同一 `.5` GUI/core，通过测试 preload 截获公共 GObject 构造器并添加弱通知。预热存活 2,682，最后 2,677；96,840 次创建/94,163 次销毁，无类型净增长或计数溢出。观察 socket/线程有额外成本，不用该轮内存作产品预算。
- 先前 `20261017T061822Z` 的观察库编译因 API 返回类型声明错误失败；改为 `GObject *` 后严格编译和实际运行通过。原失败日志保存，未将工具编译失败解释为产品失败。

**持续增长未排除**：普通运行最后十个采样间 GUI 仍增加 598 KiB、Host 16 KiB。GUI 增量主要为匿名页和堆，并有 64 KiB 字体文件页增加。观察没有发现覆盖到的 GObject 类型累积，但不覆盖所有分配或非 GObject 缓存；下一步应区分实际存活分配与分配器保留，不能直接宣称无泄漏。

原始 `.5` GUI SHA-256 `482a3d8d69a31199de48b2d4a368c21101d79a1bb902404223282990f6221cc0`，打包 core `4e0ac6b78fcc2e630aa52fe2485dc727bd1a5f45c3597e8b3daf970264cf3ced`。每次运行的 `test-binaries.json` 都核对这两个文件。首次校准与普通运行在对象观察入口加入前执行；诊断轮执行新增观察分支，不把后续诊断入口说成普通轮已启用。

`runs/` 保存各轮结果、逐连接 JSON/rollup、对象清单、基线与末轮完整 smaps、私有日志和实际二进制哈希。其余完整 smaps、GUI 截图与观察共享库保留在 Build，路径、大小和 SHA-256 记录于 `retained-in-build.json`。截图中的 ID/密码/桌面均为私有合成夹具，不是用户可连接的 FarPane ID。`trend.png`、`trend.csv` 与 `analysis.json` 来自未加观察库的普通运行。

`canonical/` 保存本轮结束时的测试/诊断/分析入口和文档。没有修改运行时 Rust 源码，未重新构建 FFmpeg/core/GUI、打新候选、安装或切换服务。`.5` 三项交付、原完整源码构建、旧 FFmpeg 静态库及原产品 receipt 核对保持有效，见 `final-check.json` 和边界记录。

GPU、1440p、真实桌面/systemd/logind、长稳、Mac 互操作及首页 60 MiB 目标均未因此通过；完整计划验收为 false。原生 GUI 维护窗口确认仍待用户回复，未重复发问。无 commit/push/deploy、新代理、Claude/OCS 或定时任务。

复现与口径见 [viewer-lifecycle.md](../../../Linux/docs/viewer-lifecycle.md)。本地 `SHA256SUMS` 是证据内容索引，不是发布者签名。
