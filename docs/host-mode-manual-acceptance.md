# FarPane Host Mode 真机验收手册

> 基线：`feature/hostMode`，提交 `eab19cd`，FarPane `0.1.0`，build `202608111917`
>
> 被控端：Mac mini；控制端：MacBook Pro（或另一台 Mac）
>
> 状态：Host Mode 代码开发已完成，本文用于补齐尚未执行的现场验收。

## 1. 明天测试什么

明天按以下优先级执行。时间不够时至少完成 P0、P1 和 P2，并把失败项停在原状，不要为了“通过”降低分辨率、缩短性能窗口或改用旧包。

| 优先级 | 范围 | 预计时间 | 是否需要两台 Mac |
|---|---|---:|---|
| P0 | 安装、版本、权限、单机 Host/HostAgent smoke | 15–25 分钟 | 否 |
| P1 | 连接、画面、键鼠、密码、会话生命周期 | 30–45 分钟 | 是 |
| P2 | 撤权、断开、关窗、App/Agent、睡眠/网络/显示恢复 | 40–60 分钟 | 是 |
| P3 | 音频、剪贴板、双向文件、多显示器 | 60–90 分钟 | 是；多显示器需额外显示器 |
| P4 | 600 秒性能窗口和 1,800 秒稳定性 | 至少 70 分钟；完整矩阵数小时 | 是 |

明天不要求完成：Intel Mac 30 分钟矩阵、三台控制端并发、Developer ID 公证/staple/quarantine、防火墙干净机首启、第三方 RustDesk 互操作。这些属于发布或额外硬件验收，不阻塞本轮 FarPane→FarPane 测试。

## 2. 统一通过原则

每项只有以下三种结果：

- `PASS`：操作和指标全部满足；
- `FAIL`：出现崩溃、错误、卡死、数据错误、输入泄漏或硬指标失败；
- `NOT RUN`：缺少第二台 Mac、额外显示器、Intel 机器、虚拟音频设备或时间，不能写成通过。

通用失败条件：

- 任一端 FarPane 自行退出、反复启动多个 App、出现不可恢复黑屏；
- 密码、公钥、服务器地址或远端 ID 出现在截图、提交文件或公开日志中；
- 断开或撤权后仍能注入键鼠、继续读写剪贴板、播放音频或写文件；
- Host 停止后仍持续采集/编码，或断开后不回到“可被连接/就绪”；
- 为通过测试手动删除失败证据、覆盖原日志或缩短规定的 600/1,800 秒窗口。

HUD 上某一秒的 FPS 不是正式性能结论。正式结论以 P4 runner 生成的 `*.run.json` 中 `status=pass` 为准。

## 3. 安全与隐私

1. 不把 Hermes 公钥、密码或设备 ID 写进本文、测试备注、截图文件名或 Git。
2. Hermes 公钥只用于验证连接到的是正确的 RustDesk ID/Relay 服务端，不是 SSH 登录凭据，也不是服务器私钥。
3. 截图前隐藏临时密码和本机 ID。日志可由 Codex 直接读取，不需要把密码复制给 Codex。
4. 文件传输只使用本手册创建的测试目录，不选 Documents、Desktop 根目录、Home 或其他真实资料目录作为接收根。
5. 音频测试使用耳机，避免麦克风和扬声器形成回授。

## 4. P0：安装与单机预检

### 4.1 Mac mini 安装当前构建

先完全退出所有 FarPane 实例，再在 Mac mini 执行：

```zsh
cd /Users/xiaobei/Documents/xiaobei/farpane
git status --short --branch
git rev-parse --short HEAD
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Build/FarPane.app/Contents/Info.plist
Scripts/install-local-macos.sh Build/FarPane.app
codesign --verify --deep --strict "$HOME/Applications/FarPane.app"
```

预期：

- 提交为 `eab19cd`；
- build 为 `202608111917`；
- 安装脚本显示 `INSTALLED_APP=.../Applications/FarPane.app`；
- `codesign` 无错误；旧安装若存在会被安装脚本自动备份。

不要通过 Spotlight 或 Dock 中的旧图标判断启动的是哪一份。测试时打开精确路径：

```zsh
open "$HOME/Applications/FarPane.app"
```

### 4.2 将同一新版交给控制端

在 Mac mini 打包：

```zsh
cd /Users/xiaobei/Documents/xiaobei/farpane
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  Build/FarPane.app "$HOME/Desktop/FarPane-202608111917.zip"
```

通过 AirDrop 或局域网把 ZIP 交给 MacBook Pro，解压后放到该用户的 `~/Applications/FarPane.app`。控制端也必须核对：

```zsh
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$HOME/Applications/FarPane.app/Contents/Info.plist"
codesign --verify --deep --strict "$HOME/Applications/FarPane.app"
```

主验收要求两端均为 build `202608111917`。旧版 FarPane 只保留为兼容性补测，不作为 P1–P4 主验收控制端。

### 4.3 权限与启动 smoke

Mac mini 的“系统设置 → 隐私与安全性”至少检查：

- 屏幕与系统音频录制：FarPane 开启；
- 辅助功能：FarPane 开启；
- 麦克风：仅在执行 P3 音频测试时开启；
- 权限刚变更后完全退出并重新打开 FarPane。

然后执行构建/签名/真实采集预检：

```zsh
cd /Users/xiaobei/Documents/xiaobei/farpane
RDN_HOST_GOLDEN_APP="$HOME/Applications/FarPane.app" \
  Scripts/preflight-host-mode-h1-golden.sh
```

通过指标：最后出现 `H1_GOLDEN_PREFLIGHT_READY`；测试没有 `skipped`；签名、App/Core UUID、真实 ScreenCaptureKit→硬件 H.264 均通过。

单机 UI smoke：

- [ ] 首页能打开，服务器配置仍在，但不会显示或自动复制密钥；
- [ ] 开启 Host 后出现稳定本机 ID，状态最终为“可被连接/就绪”；
- [ ] 临时密码默认隐藏，点击显示后可再次隐藏，重新生成后旧临时密码失效；
- [ ] 关闭 Host 后回到关闭状态，无第二个 FarPane App 被拉起；
- [ ] 若启用后台 HostAgent，App 关闭后菜单栏/首页状态不冒充错误的前台 Host。

## 5. P1：FarPane→FarPane 核心连接

### 5.1 Golden Connection

1. Mac mini 开启 Host，等到“可被连接/就绪”。
2. MacBook Pro 使用新版 FarPane 输入 Mac mini ID。
3. 使用当前临时密码连接，不使用官方 RustDesk。
4. 保持连接至少 5 分钟，其中静止 1 分钟、连续拖动/滚动 2 分钟、普通使用 2 分钟。

通过指标：

- [ ] 60 秒内出现远端画面；如果超过 60 秒，记实际耗时并标为观察项；
- [ ] 画面尺寸、方向、颜色正确，没有持续黑屏、绿屏或花屏；
- [ ] Viewer HUD 的编码帧、呈现帧持续增长；正常网络下没有超过 2.5 秒的可见停帧；
- [ ] Host 显示正在采集/编码，必要时能看到“远端请求刷新/刷新关键帧已发送”；
- [ ] 连接期间不会启动第二个 FarPane App 或多个 Connection Manager；
- [ ] 断开后 Mac mini 在 10 秒内停止采集/编码并回到 ready；
- [ ] 立即重连可以再次看到画面，不需要重启 Host。

当前 FarPane Viewer 产品主路径是 HEVC/H.265；Host 的 H.264 硬编能力由 P0 的真实硬件预检覆盖。当前 Viewer 没有手动 codec 选择器，因此明天不把“强制 H.264 端到端”写成 FarPane 主路径通过项。

### 5.2 键盘与鼠标矩阵

在 Viewer 内逐项执行，Mac mini 上用 TextEdit 和 Finder 观察：

- [ ] 单击、双击、右键；
- [ ] 拖动窗口 20 秒，拖动过程中按住状态不能提前释放；
- [ ] 鼠标滚轮和触控板精细滚动，上下方向正确，无零增量抖动；
- [ ] 指针到画面四角和中心，落点误差不应肉眼明显；
- [ ] 输入 `FarPane 123`、中文输入法文本、emoji；
- [ ] Return、Delete、方向键、Tab、Escape；
- [ ] Command-C/V、Command-A、Command-Z；
- [ ] Shift、Control、Option、Command 分别按下/释放；
- [ ] 按住任一修饰键时由 Host 端撤销键鼠权限或断开，再本地输入，不能出现粘键；
- [ ] 快速断开→重连后，按钮和修饰键状态全部归零。

通过指标：无错误注入、无卡住的按键/鼠标按钮、无断开后的输入泄漏；Viewer 的“拒绝输入”计数不应在正常操作时持续增长。

### 5.3 会话状态与本地主动控制

- [ ] 连接后 Mac mini 首页出现“当前远程会话”，菜单栏出现远控指示；
- [ ] 关闭 Mac mini 的主窗口，连接和画面继续；从 Dock 打开后状态恢复；
- [ ] 点击“停止键鼠控制”，画面保留但 Viewer 的键鼠立即失效；旧会话不应自动重新获得输入；
- [ ] 从 Host 首页或菜单栏点击“断开连接”，Viewer 断开且 Host 回到 ready；
- [ ] Viewer 主动断开后，Host 的会话卡和菜单栏指示消失；
- [ ] 断开期间没有残留键鼠、剪贴板、音频或文件能力。

### 5.4 临时密码与永久密码

只记录成功/失败，不记录密码内容。

1. 用临时密码连接成功。
2. Mac mini 设置一个符合 UI 要求的永久密码，输入框提交后应清空。
3. 用永久密码连接成功。
4. 更换永久密码：旧密码失败，新密码成功。
5. 清除永久密码：刚清除的密码失败，临时密码仍可连接。
6. 完全退出并重开 App/HostAgent，确认“已设置/未设置”状态与实际一致。

通过指标：密码不出现在普通日志/诊断中；设置、更换、清除都有真实 readback；连续错误密码触发冷却而不是无限快速重试；成功认证后正常恢复。不要把实际密码粘贴进测试记录。

### 5.5 入站审批 UI（出现该模式时执行）

若当前配置触发“新的远程连接请求”：

- [ ] “允许一次”只接受一次，重复点击无效；
- [ ] “拒绝”后控制端不能进入会话；
- [ ] 等待 30 秒超时后再点允许必须失败；
- [ ] 请求存在时关闭并重开主窗口，请求状态仍准确；
- [ ] 请求结束后按钮和会话卡收敛，不残留“处理中”。

若产品当前没有入口切换审批模式，则记 `NOT RUN（无可见配置入口）`，不要手工改 Rust 配置文件。

## 6. P2：权限、后台与恢复

### 6.1 Accessibility 运行中撤权

1. 保持远控连接并按住一个修饰键。
2. 在 Mac mini 系统设置中关闭 FarPane 的“辅助功能”。
3. 从 Viewer 继续点击和输入。
4. 再开启辅助功能，保持旧会话观察，然后显式断开重连。

通过指标：

- [ ] 撤权后下一次输入即被拒绝，无队列残留；
- [ ] 已按下的修饰键/按钮被清理，不出现粘键；
- [ ] UI 明确显示“受限/辅助功能未授权”，不把画面断开误报为网络错误；
- [ ] 重新授权不会静默给旧会话升权；显式重新建立会话后才恢复控制。

### 6.2 锁屏、用户会话与 Secure Input

1. 连接时锁定 Mac mini 屏幕。
2. Viewer 尝试移动、点击、输入，不输入真实登录密码。
3. 本地解锁并观察同一会话；必要时显式重连。
4. 在启用 Secure Input 的密码框中测试普通字符输入边界，不记录内容。

通过指标：锁屏/LoginWindow/off-console 时键鼠必须 fail closed，不能控制登录窗口；UI 显示 session unavailable/受限；解锁后不凭旧权限静默升权；无 stuck key。V1 不承诺远控 LoginWindow，无法操作登录窗口是预期安全行为，不是缺陷。

### 6.3 睡眠/唤醒

1. 建立连接并确认画面。
2. 让 Mac mini 睡眠 30–60 秒，再本地唤醒。
3. 观察 Viewer 是否断开/恢复以及 Host 状态。
4. 唤醒后重新连接并持续普通操作 2 分钟。

通过指标：无崩溃；睡眠期间不发送陈旧画面/输入；唤醒后 Host 最终回到 ready，重连后新画面和输入正常；旧 epoch 的迟到输入不会生效。

### 6.4 网络切换

在不修改 Hermes 服务端的前提下，连接中切换 Mac mini 的有效网络路径，例如 Wi-Fi 关闭再开启、以太网/Wi-Fi切换或 WireGuard 路径短暂中断。

通过指标：状态真实显示断线/恢复；不无限快速重试；网络恢复后 Host 回到 ready 或同一 Viewer 自动恢复；若自动恢复失败，手工重连必须成功；恢复后无黑屏、粘键或旧会话能力泄漏。

### 6.5 显示器重配置

只做当前硬件安全支持的操作：改变缩放、旋转、插拔额外显示器或更换主显示器。每次变化后等待画面恢复，再测试四角点击和拖拽。

通过指标：尺寸/方向更新正确；旧 display revision 的输入被拒绝；恢复后画面与输入使用同一显示器映射；不因热插拔崩溃。

### 6.6 后台 HostAgent

通过 FarPane UI 注册/启用后台 Host，不直接编辑 LaunchAgent plist。

- [ ] 启用后完全退出主 App，MacBook Pro 仍可连接；
- [ ] 重开 App 后读取到 Agent 的真实 ready/active 状态，不再启动第二个 Host Core；
- [ ] 连接中关闭/重开主 App，Host ID 和活动会话保持；
- [ ] Agent 被系统重新启动后，状态先显示恢复中，再收敛为 ready，不以进程存在冒充可连接；
- [ ] 关闭后台 Host 后不能再新建入站会话，且无 sleep assertion 泄漏。

如需显式模拟 Agent 重启，先确认 label 存在，再执行：

```zsh
launchctl print "gui/$UID/io.rustdesknative.viewer.host-agent" >/dev/null
launchctl kickstart -k "gui/$UID/io.rustdesknative.viewer.host-agent"
```

这会中断当前 Agent；只在 P1 已完成且本地可以恢复时执行。

## 7. P3：H6 可选能力

所有 H6 能力默认关闭。先测关闭态，再逐项显式开启；不要一次把所有能力打开后只做一次连接。

### 7.1 剪贴板

Host 首页分别控制“允许远端读取本机剪贴板”和“允许远端写入本机剪贴板”，小文本、富文本、图片也分别有开关。

测试数据：

- 小文本：英文、中文、emoji、换行混合，建议 1–10 KiB；产品上限为 64 KiB UTF-8；
- 富文本：包含粗体、颜色、列表和中文，RTF/HTML 每种不超过 1 MiB；
- 图片：PNG 和 SVG 各一份；PNG/RGBA envelope 上限 128 MiB、单边 8,192、总像素 33,177,600，SVG 上限 4 MiB。

逐方向测试：

- [ ] 开关全关时，两端剪贴板都不被远端改变；
- [ ] 只允许远端读取：Mini→MBP 成功，MBP→Mini 不成功；
- [ ] 只允许远端写入：MBP→Mini 成功，Mini→MBP 不成功；
- [ ] 小文本、富文本、PNG、SVG 内容和类型正确；
- [ ] 会话中点击“停止远端读取/写入”后，对应方向立即停止，另一方向不受影响；
- [ ] 断开重连后 session revoke 不被旧会话复用；
- [ ] 大于上限的 payload 被拒绝或忽略，无崩溃、无截断后伪成功。

通过指标：正确方向 5 秒内同步；错误方向始终不动；无自激循环、重复抖动或断开后继续轮询写入。

### 7.2 双向文件传输

在两台 Mac 分别准备只含测试数据的 `0700` 目录：

```zsh
umask 077
TEST_ROOT="$HOME/Desktop/FarPane-Acceptance-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$TEST_ROOT"
mkdir -m 700 "$TEST_ROOT/nested"
printf 'FarPane file transfer\n中文\n' > "$TEST_ROOT/small.txt"
dd if=/dev/urandom of="$TEST_ROOT/blob-20m.bin" bs=1m count=20
printf 'nested\n' > "$TEST_ROOT/nested/nested.txt"
shasum -a 256 "$TEST_ROOT/small.txt" "$TEST_ROOT/blob-20m.bin" \
  "$TEST_ROOT/nested/nested.txt" > "$TEST_ROOT/SHA256SUMS"
chmod 700 "$TEST_ROOT" "$TEST_ROOT/nested"
chmod 600 "$TEST_ROOT/small.txt" "$TEST_ROOT/blob-20m.bin" \
  "$TEST_ROOT/SHA256SUMS" "$TEST_ROOT/nested/nested.txt"
```

Mac mini 选择一个单独的空 `0700` 目录作为 FarPane 接收根，并开启“允许远端发送文件到本机”。

- [ ] Viewer“发送文件”：发送小文件、20 MiB 文件、多选和嵌套目录；
- [ ] Viewer“接收文件”：列出远端测试目录并下载到控制端新目录；
- [ ] 完成后两端 `shasum -a 256` 一致；
- [ ] 传输中点击取消，UI 收敛为取消，最终文件不伪装成完成；
- [ ] 单个大文件传输中断后重连，允许的 resume 从已确认 offset 继续，最终哈希一致；
- [ ] 接收根预先放置同名文件后再次发送：现有文件不能被静默覆盖；
- [ ] 关闭 Host 文件权限后，新传输立即失败，已断开的旧会话不能继续写；
- [ ] 断开后没有可见的 `*.farpane-part` 冒充最终文件。

通过指标：路径层级、大小、mtime/哈希合理；进度单调不倒退且不超过总量；取消/失败不覆盖现有文件；文件只落在明确选择的接收根内。

### 7.3 音频

1. Host 端保持“远程音频”关闭，Viewer 打开“本次连接接收远端音频”，确认无远端声音。
2. Host 显式开启远程音频，授权麦克风，选择“系统默认麦克风”。
3. Viewer 新建连接并打开本次音频 opt-in，用耳机监听 2 分钟。
4. Host 会话卡点击“停止系统音频”。
5. 如已安装 BlackHole 等虚拟输入，再选择该设备补测系统音频；FarPane 不会自动安装虚拟设备。

通过指标：默认关闭；只有 Host policy、麦克风 TCC、Viewer opt-in 和远端 permission 同时满足才播放；撤权后立即静音并释放播放状态；断开后 Viewer opt-in 重置；2 分钟内无持续爆音、明显累积延迟或无限重复缓冲。当前没有冻结的音频延迟毫秒硬门槛，记录主观延迟和设备名即可。

### 7.4 多显示器

只有 Mac mini 接入至少两台显示器时执行，否则记 `NOT RUN`。

- [ ] Viewer 控制条列出所有在线显示器，分辨率与名称正确；offline 项不可选；
- [ ] 选择显示器时键鼠先被释放和暂停，切换成功后才恢复；
- [ ] 每台显示器都能看到正确画面，并测试中心/四角点击、拖动、滚动和中文输入；
- [ ] 切换期间持续移动鼠标，不允许输入落到旧显示器；
- [ ] 改变缩放、旋转、主显示器后 catalog 更新；
- [ ] 拔掉当前显示器后提示重新选择，不把 stale success 当成功；
- [ ] 重新接入后显式选择可以恢复。

通过指标：显示器 identity/revision 与画面、输入映射一致；切换失败时 fail closed；无跨显示器误点、粘键或崩溃。

## 8. P4：正式性能与稳定性

本节现有 runner 绑定单个前台 Host 进程。开始 P4 前先通过 FarPane UI 关闭/取消注册后台 HostAgent，再完全退出 FarPane，随后按下面命令启动精确的 `~/Applications/FarPane.app`。如果后台 Agent 仍在运行，采样到的 App PID 不是实际 Host owner，本轮证据无效；需要另行用 Agent-scoped capture，而不能继续冒充通过。

### 8.1 硬门槛

| 场景 | 时长 | Host 平均 CPU 硬门槛 | 其他关键门槛 |
|---|---:|---:|---|
| Host ready、无画面会话 | 600 秒 | `<2%` | route/pipeline=off，所有 Host sleep assertion=0 |
| 已连接、静态 1080p/4K | 600 秒 | `<10%` | trusted dirty metadata；目标/应用 3 FPS；平均采集 `>0 && <=5 FPS` |
| 1080p30 普通操作 | 600 秒 | `<25%` | hardware encoder=true；请求 FPS≥30；队列稳定 |
| 4K30 普通操作 | 600 秒 | `<40%` | 无持续 backlog；内存稳定 |
| 4K30 高动态视频 | 600 秒 | `<40%` | 无持续 backlog；内存稳定 |
| 1080p/4K 稳定性 | 1,800 秒 | 分别 `<25%`/`<40%` | 六个 5 分钟窗口无 CPU/RSS/thread 持续上升 |

所有 active/stability 场景还必须满足：

- 硬件编码为 true，software fallback 为 false；
- raw-frame logical copy ≤1；raw queue 最大深度 ≤2，结束时为 0；
- Rust encoded queue capacity=3，深度不越界，writer queue drop=0；
- unclassified drops=0，六类 drop ledger 总数一致；
- transport unknown subscriber=0，network/RTT/transport 都有 route-scoped sample；
- active route 全程 user-idle sleep assertion≥1，display-sleep assertion=0；
- stability 场景 writer confirmation timeout=0，结束时 queue/in-flight 全部排空；
- 1,800 秒窗口中不能出现 CPU、RSS、thread 六窗持续上升；末窗 RSS 增长不得同时超过 32 MiB/20%，thread 增长不得同时超过 4/25%。

WindowServer、VideoToolbox 媒体进程也必须报告，但它们不计入 Host CPU 数值；不能把消耗转移给系统进程后宣称优化通过。

### 8.2 先跑 600 秒 idle

退出 FarPane，再在终端 1 执行：

```zsh
cd /Users/xiaobei/Documents/xiaobei/farpane
RUN_ROOT="$PWD/Evidence/HostAcceptance/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_ROOT"
STATE="$RUN_ROOT/idle-source.jsonl"
APP_BIN="$HOME/Applications/FarPane.app/Contents/MacOS/RustDeskNative"
FARPANE_HOST_STATE_OUTPUT="$STATE" "$APP_BIN" \
  >"$RUN_ROOT/idle-app.log" 2>&1 &
HOST_PID=$!
echo "RUN_ROOT=$RUN_ROOT"
echo "HOST_PID=$HOST_PID"
```

在 UI 开启 Host，等到 ready，确保没有 Viewer 连接。然后同一终端执行：

```zsh
Scripts/run-farpane-host-idle-scenario.sh \
  600 "$RUN_ROOT/idle" "$HOST_PID" "$STATE"
```

通过：命令退出码为 0，最后显示 `result=pass`；`idle.run.json` 的 `status` 为 `pass`、`hostCPUAveragePercent < 2`。

### 8.3 跑一个 600 秒 active 场景

每个场景必须重新启动一次精确 App，使 telemetry 输出与 prefix 对应。下面以 `1080p30` 为例；开始 runner 前，控制端必须已经看到画面。

终端 1：

```zsh
cd /Users/xiaobei/Documents/xiaobei/farpane
RUN_ROOT="$PWD/Evidence/HostAcceptance/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_ROOT"
PREFIX="$RUN_ROOT/1080p30"
APP_BIN="$HOME/Applications/FarPane.app/Contents/MacOS/RustDeskNative"
FARPANE_HOST_TELEMETRY_OUTPUT="$PREFIX.route.json" "$APP_BIN" \
  >"$PREFIX.app.log" 2>&1 &
HOST_PID=$!
echo "RUN_ROOT=$RUN_ROOT"
echo "PREFIX=$PREFIX"
echo "HOST_PID=$HOST_PID"
```

开启 Host，由 MacBook Pro 连接并看到画面。保持窗口拖动、文本输入和滚动。终端 2 使用终端 1 打印的实际值执行：

```zsh
cd /Users/xiaobei/Documents/xiaobei/farpane
Scripts/run-farpane-host-performance-scenario.sh \
  1080p30 600 "实际的PREFIX" "实际的HOST_PID"
```

600 秒结束后，按 runner 提示从 Viewer 断开，让 route-stop telemetry 落盘。通过：runner 退出码 0、显示 `result=pass`，`*.run.json` 中 `status=pass`。

其他场景名称只能使用：

```text
static-1080p30
static-4k30
1080p30
4k30-normal
4k30-video
stability-1080p30
stability-4k30
```

`static-*` 全程不操作桌面；`stability-*` 必须 1,800 秒并持续重复目标产品操作。显示器实际不是对应 1920×1080 或 3840×2160 时不要伪跑，记 `NOT RUN（分辨率不匹配）`。

需要 1080p 或 4K 时，先把 Mac mini 当前被采集显示器设置成对应的真实像素尺寸，再启动 App 和 route。runner 会检查 requested/capture width、height；缩放后的“看起来像”尺寸不能替代真实 1920×1080 或 3840×2160。

### 8.4 sleep assertion 生命周期专项

App 必须以 matching `FARPANE_HOST_TELEMETRY_OUTPUT=/absolute/prefix.route.json` 启动。Host ready 且尚未连接时执行：

```zsh
Scripts/run-farpane-host-sleep-assertion-lifecycle.sh \
  10 /absolute/evidence/prefix HOST_PID
```

runner 会依次要求 ready-before、连接并 active、断开后 ready-after。通过指标：三个阶段各 10 个样本；ready 前后 user-idle assertion 全为 0；active 全为 ≥1；display/system sleep assertion 全为 0；route evidence 存在且 finalized；`status=pass`。

### 8.5 日志位置与交付

FarPane 会自动写 Host 媒体 live log：

```text
~/Library/Logs/FarPane/HostMedia/host-media-live-*.jsonl
```

P4 runner 的完整证据位于：

```text
/Users/xiaobei/Documents/xiaobei/farpane/Evidence/HostAcceptance/<UTC时间>/
```

测试完成后只需要告诉 Codex：

```text
测试完成，读取 HostAcceptance 和 HostMedia 最新日志。
```

不需要停止拖动去复制 HUD 文本，也不要手工编辑 JSON/JSONL。Codex 应直接读取完整窗口并报告 pass/fail、失败门槛和对应时间段。

## 9. 明天的推荐最短路线

如果只留 90 分钟，按这个顺序：

1. P0 安装和 `H1_GOLDEN_PREFLIGHT_READY`；
2. P1 Golden Connection + 完整键鼠矩阵；
3. 关窗保持、Host 停止键鼠、Host 主动断开、重连；
4. Accessibility 撤权/恢复；
5. 剪贴板小文本双向和一个 20 MiB 文件双向；
6. 若仍有时间，跑 600 秒 `1080p30`；
7. 告诉 Codex读取日志，不手抄瞬时 FPS。

如果只有 Mac mini、第二台 Mac 仍不可用：只执行 P0 和单机 UI smoke，其余全部写 `NOT RUN（缺少控制端）`。不要同机自连冒充双机通过。

## 10. 结果记录表

| 编号 | 项目 | 结果 | 观察/失败时间 | 证据路径或备注 |
|---|---|---|---|---|
| P0-1 | 两端 build `202608111917` |  |  |  |
| P0-2 | 权限与 Golden preflight |  |  |  |
| P1-1 | 连接、画面、Refresh、teardown |  |  |  |
| P1-2 | 点击/拖拽/滚动/键盘/IME/修饰键 |  |  |  |
| P1-3 | 关窗保持、会话指示、本地主动撤销/断开 |  |  |  |
| P1-4 | 临时/永久密码设置、更换、清除 |  |  |  |
| P1-5 | 入站审批 UI |  |  |  |
| P2-1 | Accessibility 撤权与显式恢复 |  |  |  |
| P2-2 | 锁屏/session unavailable/Secure Input |  |  |  |
| P2-3 | sleep/wake |  |  |  |
| P2-4 | 网络切换 |  |  |  |
| P2-5 | display reconfigure |  |  |  |
| P2-6 | 后台 HostAgent/App 重启 |  |  |  |
| P3-1 | 小文本/富文本/图片剪贴板双向与撤权 |  |  |  |
| P3-2 | 文件上传/下载/取消/resume/no-overwrite |  |  |  |
| P3-3 | 音频 opt-in/撤权/断开清理 |  |  |  |
| P3-4 | 多显示器选择、热插拔、输入映射 |  |  |  |
| P4-1 | 600 秒 idle |  |  |  |
| P4-2 | 600 秒 static |  |  |  |
| P4-3 | 600 秒 1080p30 |  |  |  |
| P4-4 | 600 秒 4K30 normal/video |  |  |  |
| P4-5 | 1,800 秒稳定性 |  |  |  |
| P4-6 | sleep assertion lifecycle |  |  |  |

## 11. 失败时怎么记录

不要反复尝试到现象消失。第一次出现异常时：

1. 记录本地时间到秒；
2. 记录正在做的测试编号和最后一个动作；
3. 记录两端 FarPane 是否仍运行、画面是否更新、键鼠是否仍生效；
4. 截图时遮住 ID/密码；
5. 保留 `HostAcceptance` 和 `HostMedia` 原文件；
6. 若 App 自行退出，不立刻清日志，告诉 Codex“测试编号 + 时间 + 哪一端退出”。

只有安全原因需要立即终止：出现输入失控、音频回授、文件写到接收根之外，或系统无法本地操作。此时先本地断网或退出 FarPane，再保留现场证据。
