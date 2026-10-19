# FarPane Linux GPU 媒体重构（linux-host）：Host 用户总线重建

2026-10-17，对 `.9` 候选中的原始 GUI/core 执行 Host 桌面总线断开与重建检查。十项检查通过；本轮只增加测试与证据，没有修改或重编产品，也没有更换安装包。

现有桌面测试只替换通知和 StatusNotifier 提供者。本轮直接结束整个私有 `dbus-daemon`，在同一 socket 路径启动具有新 bus ID 的进程，连续验证四个总线实例。Host 使用受管理候选中的原始 core，保持同一个 PID；两个私有 Xvfb 和 loopback 网络提供真实软件视频。通知/watcher 是测试提供者，GUI 审批、网络登录、视频解码和呈现均为实际程序。

| 场景 | 实际结果 |
| --- | --- |
| 等待批准时总线断开 | connected、托盘、通知及通知 action 能力均变为不可用；同一未授权请求保留，没有画面或自动批准 |
| 总线恢复 | 新 bus ID 下重新注册托盘，为仍有效的请求重新通知一次；没有重启 Host 或建立另一个入站请求 |
| 恢复后人工批准 | 真实 GTK“允许连接”按钮完成批准，Viewer 呈现画面，通知随后关闭 |
| 传输期间总线再次断开 | 同一已授权入站连接保留；改变私有画面后，Viewer 新帧计数继续增加 |
| 已授权时重建总线 | 桌面能力恢复，不把已授权连接重新当作待批准请求通知 |
| 无人批准且总线持续中断 | 约 30.112 秒后正常拒绝，零画面，Viewer worker 回收 |
| 超时后第四次总线启动 | 过期连接和通知不重放；关闭控制 GUI 后，Host 进程、身份和策略保持一致 |

测试 GUI 控制端和远端 Viewer 使用其他私有总线，专门隔离 Host 桌面适配器的行为。**本轮没有证明 GTK GUI 在自身总线死亡后继续运行**，也不覆盖登录会话更换、总线地址变化、地址中固定旧 GUID、真实 GNOME/KDE 通知/托盘、锁屏或睡眠。没有使用宿主总线、桌面、GPU、网络服务或用户配置；不构成硬件性能测试。

复现入口：

```sh
Scripts/linux/test-native-desktop-bus.sh \
  Build/Linux/artifacts/farpane-native-dev-e7508f297ef1d671172d7737
```

入口复用已固定的隔离镜像，限制 4 CPU/12 GiB、无外部网络，不带设备或宿主服务挂载；最长 210 秒，只有容器里的受控进程会被测试结束。测试在 root 私有目录校验并暂存候选，然后以普通用户运行 Host/GUI；没有启动 root supervisor。新增夹具位于 `Linux/tests/native_desktop_bus_smoke.py`，通过既有 `native_viewer_smoke.py` 的专用分支执行。

原始运行 `Build/Linux/native-desktop-bus-smoke/20261017T093347Z` 退出 0。结果绑定实际打包后的 GUI/core 哈希；完整记录见[专项证据](../../Evidence/LinuxHost/2026-10-17-native-desktop-bus/README.md)。新增测试未收入冻结 `.9` 的源码归档，后续实际打包再纳入；产品文件和当前服务保持不变。完整 GUI、维护窗口、60 MiB 首页目标及发布门槛仍未全部验收。

## GUI 自身总线中断的退出与恢复

2026-10-18，使用冻结 `.20261018.3` 追加两个普通用户端点的实际双向连接测试。A 的 GUI/Viewer 连接单独的第三条私有总线；A 的 Host、B 的 GUI/Viewer/Host 均使用其他私有总线。全过程为两个私有 Xvfb 桌面、软件视频、容器内回环网络；没有 root supervisor、用户桌面或输入法测试。

结束 A 的 GUI 专用 `dbus-daemon` 后，**GUI 收到 SIGTERM 退出（返回码 -15），不是继续运行或透明恢复**。其出站 Viewer 随后退出，B 的对应入站清空。A 的独立 Host 与从 B 接入的原会话 ID 保持不变：改变 A 的合成画面后，B 的真实窗口仍显示新颜色。替换为同一路径、新 bus ID 后，重新打开 A 的 GUI 首页，仍接入原 Host，未自动重建旧出站 Viewer；B 的原入站画面继续。最后关闭窗口/断开，两个 Host 与原身份保留。

第一次运行 `20261018T094124Z` 的进程检查只验证 `/proc/<pid>/exe` 已不可读，不能排除退出后的僵尸进程。因此不采纳该轮“完全回收”结论。测试入口随后增加容器 init，并要求失去 GUI 父进程的 Viewer **整个 `/proc/<pid>` 消失**。最终 `20261018T094225Z` 退出 0，12 项检查通过，含上述完整回收、新总线身份、实际新画面与 GUI 重开。

```sh
bash Scripts/linux/test-native-coexistence.sh \
  Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5 gui-bus
```

此模式限定 2 CPU/4 GiB、300 秒，复用已校验候选，不编译或启用暂停中的 Warp 草稿。工具入口原有 `run`/`calibrate` 模式保持，新增 init 负责容器内孤儿回收，不能把 init 的工作当成应用自己 wait 已退出子进程的证据。检查证明 GUI 故障不会连带结束独立 Host 的活动入站，未证明真实登录会话/系统总线/桌面退出、GPU 或所有资源门槛通过。

两轮原始结果、私有截图、二进制哈希和最终测试源码见[GUI 总线故障证据](../../Evidence/LinuxHost/2026-10-18-native-gui-bus/README.md)。产品 GUI/core、包、当前安装和服务均未变化，未提交/推送。
