# FarPane Linux GPU 媒体重构（linux-host）：有限按键观察

## 2026-10-19 09:43：首次授权实机观察完成

用户确认“已连接，可以开始”，随后报告“已提交，仍没有文字”。北京时间约 09:43:27–09:43:57，在当前 `.8` 核心上完成 30 秒窗口，正常按时结束、exit 0；此项覆盖了下文原先未验收的实机设备权限与 CLI 路径。没有再次开启采集。

通过 root PID 1497504 的 uinput FD 绑定到 event7，Host PID 1497613、core c403acbf 均未变；内核掩码回读通过，初始九键全松开。共记录 22 个白名单事件：一组单独 Shift 按下/抬起，随后五组完整 Shift-down / Insert-down / Insert-up / Shift-up，没有 Ctrl/Alt/Meta，没有丢帧或未完成帧。五组总跨度分别为 60、143、83、59、62 微秒；这些时长是观测值，不是已确认的故障原因。

同窗口的既有 Host 日志出现五次非 ASCII 提交（chars=2、released_modifiers=0），均在剪贴板写入后约 50ms 进入 ready/queued，时间与五组内核事件相符。仅导出阶段和长度/位掩码，未导出正文。日志时间以输出文件最终 flush 时间减 30 秒近似对齐，前后保留 -2/+1 秒余量，不声称具有事务 ID 的精确关联。

现在可以确认这些组合键完整进入了实际虚拟键盘事件流；仍不能证明 Mutter、IBus 或 Chrome 收到并消费。已把完整记录交给 Claude（OCS seq24），要求继续以原版成功路径为基准；不因事件很快就加等待结案，也不改快捷键。原版成功会话的后端、selection 类型和构建差异仍待核对。

`Evidence/LinuxHost/2026-10-19-native-paste-key-observer/real-capture/` 保存过滤事件、用户结果、分析、退出状态与日志阶段。FarPane 服务 active / MainPID 1497504 / NRestarts 0；RustDesk inactive / MainPID 0，均保持原状。下面保留工具准备时的范围和未执行状态说明。

2026-10-19。针对原版可用、FarPane 自动提交中文失败的对照，准备直接观察 FarPane 虚拟键盘在内核中实际发出的修饰键与 Insert。该工具是诊断工具，不是输入修复；尚未读取宿主 evdev，尚未开启用户测试窗口。

入口为 `Scripts/linux/observe-native-paste-keys.py`，设备与过滤实现在 `Linux/diagnostics/paste_keys.py`。必须先得到用户对本次短时实际输入事件观察的同意；`--approved-test-window` 只防误操作，不代替用户授权。首次建议保持当前 FarPane 连接，在 Chrome 输入框提交一次中文，不手动粘贴；无需切换 RustDesk。

准备好的命令（得到授权后才运行）：

```sh
sudo -n python3 -B Scripts/linux/observe-native-paste-keys.py \
  --uid 1000 \
  --release /opt/farpane/releases/farpane-native-dev-9a76a6c2af66e3955470ea24 \
  --seconds 30 --approved-test-window
```

开始前核对当前 root-owned release、manifest/core 哈希、systemd MainPID、Host 只读观察接口、两者实际 executable/UID/角色与 start ticks，并要求恰好一个已认证入站。持有两个 pidfd，运行期间持续检查进程/安装目录/设备，周期检查 Host 代际及入站数量；变化则停止。不能单凭设备名包含 RustDesk 就读取。

设备归属通过已验证 FarPane 服务持有的 uinput FD 确认：`pidfd_getfd` 短暂复制该 FD，仅调用 `UI_GET_SYSNAME`，立即关闭副本；从对应的 `/sys/devices/virtual/input/inputN/eventN` 取得具体设备。要求唯一 `RustDesk UInput Keyboard`，再核对 evdev 字符设备编号、名称与 sysfs inode。无权限复制 FD、来源未知、多个键盘、设备变化均停止，不改用扫描所有键盘的办法。不在观察期间保留 uinput 副本，以免影响虚拟设备生命周期。

evdev 以 `O_RDONLY|O_NONBLOCK|O_NOFOLLOW` 打开。`EVIOCSMASK` 仅设置观察者自己的队列掩码，并用 `EVIOCGMASK` 回读确认：只允许 EV_SYN/EV_KEY，按键仅 29/97（左右 Ctrl）、42/54（左右 Shift）、56/100（左右 Alt）、125/126（左右 Meta）、110（Insert）。不记录字母、扫描码、鼠标位置或正文，也不读取剪贴板。设置掩码前的短暂排队事件全部丢弃，只有 `ready` 之后属于本轮。解析器另有同样白名单防线。

输出只含版本/进程标识、初始九键状态、白名单键按下/抬起/重复及相对时间。每个 SYN_REPORT 后才输出完整帧；SYN_DROPPED、异常帧或超过 256 个白名单事件立即停止。时长最多 60 秒，另有包括准备阶段的绝对超时；不后台驻留。没有 EVIOCGRAB、设备写入、注入、服务控制或桌面输入源操作。内核事件只能证明已进入这个输入设备的事件流，仍不能证明目标应用消费。

验证：11 项解析/隐私/边界测试、8 项既有 VM 防误运行测试通过。私有 KVM 内核回归 `run.1l_4zaka` 通过：真实 uinput FD 归属确认、内核白名单过滤、Shift/Insert 完整四事件、最终释放状态，以及另一未过滤 reader 仍收齐包括普通键的所有事件。QEMU 只暴露宿主 `/dev/kvm`，无宿主输入设备、桌面、网络或 GPU。没有把这项低层验证称为实机 FarPane CLI 的完整验收。

首轮 `run.5r6_ngw_` 因 `/proc/self/fd` 枚举自身临时目录 FD 随后消失而误报 device_changed；仅对尚未识别为 uinput 的消失 FD 跳过，已识别设备的变化仍终止。修复后重新制作磁盘和验证。首次 unittest 调用遗漏测试模块搜索路径导致导入失败，改为既有 discover 入口后 8 项全过，记录不作为产品故障。

证据：[2026-10-19-native-paste-key-observer](../../Evidence/LinuxHost/2026-10-19-native-paste-key-observer/README.md)。当前安装仍为 `.8` 核心 c403acbf；没有重编产品、安装、切服务、提交或推送。实际宿主设备权限、一次真实提交的事件，以及成功原版对应会话的后端仍待验证。
