# FarPane Linux GPU 媒体重构（linux-host）：原生 GPU 探针活动保护

2026-10-18，修正测试工具在安装原生 GUI/core 后不能确认 Host 空闲的问题。原 `run-native-gpu-test.py` 以普通用户 Python 请求旧 `VideoConnCount`，原生 Host 的身份检查会关闭这个连接。旧工具会报错停止，并没有把错误当作空闲；但此后无法进行既定 GPU/首页内存探针。

## 实现

`Scripts/linux/observe-native-activity.py` 使用已经存在的原生 root 只读观察入口，仅发送 `NativeActivity(None)`。没有增加产品端权限、控制命令或 socket，没有读取凭据、配置、剪贴板或屏幕；不会启动离线配置 helper。通过 `sudo -n` 运行这个只读观察进程，是因为该入口只接受内核标识为 root 的调用方；没有交互授权时直接失败，不回落到较弱检查。

每次读取验证 root 所有、不可由普通用户修改的 release/core 路径与当前链接；通过 `SO_PEERCRED` 和 `SO_PEERPIDFD` 验证确切 UID、可执行文件、`--server` 角色和存活状态，并把活动快照绑定到 `/proc` 启动时间。缺少 Linux 6.5+ 的稳定句柄、进程退出、未知/过期/未来状态、错误字段或当前 release 变化均拒绝。沿用原生监管合同的 3 秒时效，不把缺失数据变成零。

非空闲条件为任一计数非零：已认证连接、待审批、CM 文件工作所有者、视频服务及尚未释放的媒体资源。`busy_count` 是这些计数之和，同一连接可能占多个计数，**不能把它当作连接人数或正在传输的文件数**。

GPU 测试只启动一个观察进程，经私有管道请求/应答，避免每 200 ms 重启 Python/core。父进程关闭管道即退出；观察进程另有 120 秒绝对寿命和 1,000 次请求上限，不是常驻监控或定时任务。观察出错或变忙时，runner 只删除本次创建的随机命名测试容器；现有 Host/GUI/服务不在停止范围。

新 runner 默认使用原生活动检查。`--legacy-host` 仅为明确选择旧版 Host 的历史 video-count 路径；原生失败绝不会自动尝试旧路径。其余 GPU 锁、限定 renderD128、低负载、90 秒 Viewer/30 秒 codec 上限保持不变。最终输出改用 `before_activity_count`/`after_activity_count`，并记录 guard 类型和不含凭据的最后观察。

## 验证

- 11 项单测通过：零值、四类活动、未知 schema/owner、过期/未来时间、非法数值、截断/超大/错类报文及绝对超时；模拟 runner 在启动前拒绝忙/未知，运行中只停止自己容器，且不自动降级旧查询。另验证连续可读输入不能绕过观察进程绝对寿命、EOF 退出及不完整请求拒绝。
- 原始 `.2` bundle 在断网、无 GPU、私有 D-Bus/Xvfb 中完成两次实际软件视频连接。root 观察器取得 314 个有效快照，191 个空闲、123 个非空闲；验证错误 UID/exe 拒绝、视频/媒体资源活动、释放后重新空闲、Host 退出为未知。观察器 FD 始终为 5。
- 对 linux-host 仅作 5 次只读观察，确认 Host PID 70886、1 条已认证入站连接、1 个 CM 文件工作所有者和 2 个媒体所有者。观察进程随后正常退出，未留后台任务。
- 实际调用 GPU runner 被非空闲状态阻止，尚未创建测试容器或打开 render 节点。服务、已安装 `.1` 和暂存 `.2` 未改变。

本轮没有新的 GPU、首页内存或真实桌面测试结果。当前没有运行中的 FarPane GUI 可只读复测，已有入站连接又阻止私有 GPU 探针；此前实机约 131 MiB 与私有 Wayland 约 78 MiB 的差异仍未定位。不能将测试工具修复计为内存优化或 60 MiB 达标。应用、媒体和既有候选均未重编或重打包。

## 复现

```sh
python3 -B -m unittest discover -s Linux/tests -p test_native_activity_observer.py -v
Scripts/linux/test-native-activity.sh \
  Build/Linux/artifacts/farpane-native-dev-67f5d1594e8961809614f4e1
```

普通 GPU/首页探针继续使用原 `run-native-gpu-test.py` 命令，不需要先手工运行观察器；任何活动或未知结果都应保持停止，不绕过保护。检查只证明当前桌面 UID 的原生 Host 活动，不替代同机其他应用/GPU 任务的负载安排或真实桌面维护窗口。

原始记录见[活动保护证据](../../Evidence/LinuxHost/2026-10-18-native-activity-observer/README.md)。新增工具及测试在 canonical Linux/Scripts 中，尚不在此前冻结的 `.2` 完整源码归档中；被测应用源码与该归档的对应关系未改变。
