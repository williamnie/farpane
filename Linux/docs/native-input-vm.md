# FarPane Linux GPU 媒体重构（linux-host）：独立内核输入回归

2026-10-18 UTC。用户离开期间继续无人值守开发。此前中文测试用私有 Mutter 键盘替代最后的硬件写入，不能证明 root/uinput 路径；本轮增加 KVM 私有内核测试环境，保留原有 `.1` 服务和入站连接。

测试系统由固定 Docker 镜像导出、在一次性容器中制作 ext4 镜像。复用公开发行版内核文件；后续 `desktop` profile 另复制锁定的单个 VKMS 模块，只在 guest 内加载，不复制宿主 initramfs、用户配置或凭据。QEMU 只开放 `/dev/kvm`，没有虚拟网卡、宿主 GPU、输入设备、显示、D-Bus 或服务 socket；测试内部可使用自己的 loopback。每次启动写独立 qcow2 overlay，基础磁盘只读。4 vCPU、6 GiB guest RAM、10 GiB 容器上限、180 秒总时限；退出清理只针对本次 UUID 容器。准备磁盘同样有资源和时间上限。

`Linux/tests/native-input-vm.lock.json` 固定镜像、Dockerfile、公开内核和配置哈希；APT 仓库不是历史快照，不能把 Dockerfile 称为未来可逐字节重建的镜像。所有测试代码和入口在 `Linux/`、`Scripts/linux/`，镜像缓存、磁盘、日志和产物在 `Build/Linux/native-input-vm/`。

已完成独立内核启动和真实 uinput→evdev 往返：测试键盘的 A-down/SYN/A-up/SYN 完整读回，guest boot ID 与宿主不同。随后，原始 `.2` 核心在 guest 中启动 root `--service` 和 UID 1000 `--server`，经真实特权 IPC 创建产品 uinput 键盘。桌面为私有 Mutter，登录发现使用已有受控 loginctl 夹具；这不是 systemd/logind 实机验收，也没有把“键盘创建成功”写成“中文已经输入成功”。

初次启动因内核已挂载 devtmpfs、脚本重复挂载而失败；修正为确认已有挂载类型。继续接 Viewer 时发现测试镜像缺少推荐依赖 Xwayland，已显式补入 Xwayland、PipeWire 和 portal。原始失败均保留。另一条 Docker 构建命令因使用工作区上下文、遇到私有目录权限而在构建前失败；后续只经 stdin 提交 Dockerfile，使用空构建上下文。

## 发现的独立 Viewer 状态错误

原始 `.2` 包内 GUI/Viewer 完成 TCP 连接和错误密码重试后，Host 发出固定的 Wayland 屏幕选择提示。`NativeUi::msgbox` 把类型中的 `hasclose` 解释为连接失败，界面出现“远程连接失败或已关闭”，尽管这条消息只是要求在远端选择屏幕。初次完整连接测试在此处失败并终止了私有测试，不能据此认定网络本身断开。

`Linux/native/viewer_ui.rs` 现在仅对上游这条确切类型、标题和正文显示“请在远端选择要共享的屏幕，等待授权…”。认证状态和权限不变，不吞掉其他 Wayland 错误，也不提前启用远程输入。两项单测覆盖提示、随后错误及三个近似但真正失败的消息。候选构建和私有 GUI 对比结果以本轮证据和测试候选记录为准。

修正后的 `.3` 已在同一私有内核中使用原始 GUI、Viewer、Host 和 root 服务完成对比：错误密码重试后收到屏幕选择提示，界面保持 Authenticating，Viewer 未回收，也没有谎报已出图。包内 core SHA-256 为 `c57fc5dd5755c2caf6e7780d5bf2cc33459b1629949079d2d9eedb17fcf62f6b`，GUI 字节与 `.2` 相同。Ubuntu 24.04 的 8 项包检查、6 组真实 dpkg 安装/升级恢复/卸载检查通过，bundle 和升级后各完成两次软件视频连接。没有重新验证 GPU 或整个发行版矩阵。

上一轮 headless 虚拟机记录中 `mutter_input_fds=[]`：headless Mutter 未打开物理输入节点。当时完整中文测试尚未建立，不能把 kernel 微测和虚拟键盘替身的两个通过结果拼成端到端通过。后续真实 GNOME profile 见下节；旧失败和旧测试范围保持不变。

原始失败、修正前后 GUI 状态、构建与包测试见[本轮证据](../../Evidence/LinuxHost/2026-10-18-native-input-vm/README.md)。`.3` 仅生成候选，未 stage/activate；当前 `.1` 的服务 PID 64215、Host PID 70886 和已认证入站保留，RustDesk 仍由用户停止并禁用。

## 复现入口与范围

```sh
# 镜像构建不传仓库上下文，不接触宿主软件安装。
docker build --memory 12g --cpu-period 100000 --cpu-quota 400000 \
  -t farpane-native-input-vm:20261018 - < Linux/packaging/native-input-vm.Dockerfile

python3 -B Scripts/linux/prepare-native-input-vm.py ARTIFACT --stage service
python3 -B Scripts/linux/run-native-input-vm.py PREPARED_DISK_DIRECTORY
```

`ARTIFACT` 必须在 `Build/Linux/artifacts/`；准备结果 JSON 给出新的磁盘目录。运行还要求已缓存且哈希匹配的公开内核文件和 `/dev/kvm` 访问权限，工具不会安装内核或改变 KVM 权限。`--stage bootstrap` 只跑内核微测；默认 `service` 增加真实服务/Host/uinput 设备建立；`viewer-notice` 用原始 GUI 连接，核对授权提示没有变成失败；`viewer` 是继续完整视频/输入测试的入口，其首次出图仍需验证私有 portal 授权流程。

GUI 自带烟测要求测试 release 路径和 `/.dockerenv` 标记，guest 中显式设置这两个测试条件；它们不是虚拟机的隔离证明。真正隔离边界是无宿主设备/接口挂载的 QEMU 与独立内核。Guest PID 1 的入口在任何挂载、设备或关机操作前检查 PID、UID、专用标记和内核参数。

上述早期 profile 尚未覆盖网络中文提交→真实 root 按键→Wayland 应用文字；后续已补齐的私有测试如下。Warp、Mac 输入法和 linux-host 用户桌面验收仍未完成。生成候选不自动安装或重启当前服务。

## 真实 GNOME、内核键盘与网络输入

后续无人值守工作增加 `--stage desktop --target entry|terminal|browser`。guest 运行真实 systemd 259.5、PAM、logind、GNOME Shell/Mutter 50.1；UID 1000 的 seat0 会话由真实 loginctl 返回 Active=yes、Type=wayland、Class=user，不使用 loginctl 替身。VKMS 仅为 guest 软件虚拟屏幕，GNOME 使用软件 Mesa，产品走原有 DRM CPU 帧路径和 VP9 软件编码；这不是 GPU 性能测试。

原始 `.3` 包内 root 服务创建 uinput 键盘，核对 GNOME 的 `/proc/PID/fd` 确实打开其 evdev 节点。原始 GUI 在另一个 guest Xvfb 上完成 TCP 回环连接、错误密码重试、认证与真实画面呈现。XTEST 只驱动这个本地客户端；Alt+Tab 和 GTK Unicode 输入法提交均经产品网络、Host、特权 IPC 和内核键盘到达 GNOME。没有用 Mutter D-Bus 替代远端按键，也没有直接写入目标文本或剪贴板。

完整测试逐字提交“中文测试”，分别读取 GTK4 Entry、VTE 独立 PTY 和 Chrome 155.0.8059.84 的页面状态。观察器仅旁读产品 evdev，不 grab；检查实际四次 Shift-down/Insert-down/Insert-up/Shift-up、无 SYN_DROPPED、目标内容完全一致且不重复。具体结果及所有失败见[真实桌面回归证据](../../Evidence/LinuxHost/2026-10-18-native-input-vm-desktop/README.md)。六项入口保护测试通过。

Chrome profile 仅复制公开程序目录，不复制用户资料。255 项程序文件/链接清单锁定为 SHA-256 `aacb672df40b69bb6d4780b112ae15fcc46754b4a0d49b3f25abd3ea60784746`，在 guest 内使用空 profile、无外网、无 GPU 和合成回环页面；延用隔离 Chrome 测试的 `--no-sandbox`。它不是 Chrome 安全沙箱验收。

测试环境修正均限定于 guest：Linux 7 VKMS 使用 faux bus；Mutter 默认规则会忽略它，制作 guest 镜像时只移除两条确切 VKMS ignore 规则，其他规则保留。后置 TAG-= 覆盖无效的失败也保存。VTE 的图标加载器曾因 bwrap 报 unexpected capabilities 退出，私有用户会话显式清空 capability 集合并启用 NoNewPrivileges 后，bwrap 及目标正常；未降低宿主策略。观察器曾因未及时读取丢事件，改为每个客户端键事件后排空并拒绝 SYN_DROPPED。GUI 事件驱动 progress 文件可能停在首帧前，测试改用首帧绘制后才生成的 input-targets 标记，不修改产品状态来迁就测试。最后由 guest systemd 正常关机，避免直接 poweroff 截断串口或文件系统写入。

```sh
python3 -B Scripts/linux/prepare-native-input-vm.py \
  Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5 \
  --stage desktop --target terminal
python3 -B Scripts/linux/run-native-input-vm.py PREPARED_DISK_DIRECTORY
```

本轮只修改测试基础设施和文档，未重编、重新打包或安装应用。`.3` 冻结源码归档绑定的应用源码仍匹配；本节新增测试不在那份历史归档内。当前 `.1` 服务 PID 64215、Host PID 70886 和一条已认证入站保留，RustDesk 仍 inactive/disabled。

范围限制：这个 GTK profile 使用 Linux 客户端的逐字 Seq 提交；后续的 Mac 式整段消息与修饰键对照见下节。Warp 以及真实 Mac mini→linux-host 仍需单独验证。私有回归通过不能证明当前安装版中文已修复，也不能替代维护窗口验收。

## Mac 式 Seq 与旧版对照

新增 `--input-driver wire`，在同一独立内核桌面中使用最小协议测试端。它按正常直连流程先核对错误密码被拒，再用合成固定密码认证、接收实际软件视频；不修改 Host 认证或键盘权限。该连接只用 guest loopback，不连接 ID 服务或宿主。

测试消息与仓库中 Mac `rdn_client_send_text → session.input_string` 构造相同：`Message.key_event` 中仅有 `KeyEvent.seq`，down=false、press=false、Legacy、modifiers 为空，不另发 Clipboard 消息。一次提交“中文测试”，再在内核 EVIOCGKEY 确认 Control 确实处于按下状态后提交“控制提交”，最后提交“混合A1，🙂é”。每次核对实际文字、焦点、无重复、恰好一组粘贴按键，以及 Control-up 先于 Shift/Insert。迟到的物理 Control-up 也不能重复输入。客户端声明 Mac OS，版本固定 1.5.0；这是协议等价测试，不是运行真实 Mac 应用。

同一测试分别运行原始 `.1` 与 `.3` bundle，均逐项验证包内容后复制到 guest，没有替换其库或输入代码。结果：

| 目标 | `.1` 普通整段提交 | `.1` Control 残留时 | `.3` |
| --- | --- | --- | --- |
| GTK4 Entry | 成功 | 剪贴板更新、焦点正确，但文字未增加；Control 仍按下 | 三种提交均正确，Control 先释放 |
| VTE PTY | 成功 | 文字仍能粘贴，但 Control 未释放，因此状态检查失败 | 三种提交均正确，Control 先释放 |
| Chrome 155 | 成功 | 焦点正确，文字未增加；Control 仍按下 | 三种提交均正确，Control 先释放 |

这证明 `0043` 的修饰键修正适用于真实网络/特权 IPC/内核路径；也说明各应用对 Ctrl+Shift+Insert 的处理不同，不能把 VTE 的旧版结果写成“没有文字”。原始失败和成功均见[协议对照证据](../../Evidence/LinuxHost/2026-10-18-native-input-wire/README.md)。没有抓到用户实际失败瞬间的按键状态，故不能断言这是实机故障的唯一触发条件。

`native-input-vm.lock.json` 记录 protobuf schema、帧编码、upstream input_string 和 Mac bridge 源文件哈希，准备 wire guest 时核对。3 项协议测试覆盖默认字段/中文字节、帧长度边界、截断/溢出拒绝；入口保护增至 8 项，协议连接和设备打开都在 guest 检查之后。首轮协议测试尚未完成焦点准备，保留失败；增加同 GTK profile 的远端点击后通过，没有用额外 API 直接写文字。

```sh
python3 -B Scripts/linux/prepare-native-input-vm.py \
  Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5 \
  --stage desktop --target browser --input-driver wire
python3 -B Scripts/linux/run-native-input-vm.py PREPARED_DISK_DIRECTORY
```

本轮仍只改测试和文档，无应用重编、打包、部署或实际桌面操作。`.3` 保持原包及哈希，`.1` 当前安装仍未替换。Warp、Mac 输入法及灰色兼容菜单、实机维护窗口验收继续保留。
