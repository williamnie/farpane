# FarPane Linux GPU 媒体重构（linux-host）：Mac 中文输入修复

**2026-10-19 根因与修复（默认模式）：** 实机被动追踪证明默认模式失败的根因是 GNOME 屏幕阅读器 Orca 截走 Insert：Host 的 Shift+Insert 只有 Shift 到达应用。用户确认 Orca 并非有意开启，关闭后 Chrome 默认模式正常。按用户决定恢复 `0044` Warp 白名单，并修正其 X11 连接（复用 `clipboard_x11::connect()`）；已安装 `farpane-native-dev-12a7610123e68eed56441923`，兼容开关关闭时 Warp/Chrome 均实测正常。Mac 兼容开关打开会与 Host 粘贴叠加，建议保持关闭。不靠粘贴快捷键的提交方式继续调研。见[粘贴送达追踪](../../Evidence/LinuxHost/2026-10-19-native-paste-delivery/README.md)。以下为历史记录。

**2026-10-19 兼容模式实机结果：** 原版对照结束并恢复 FarPane 后，用户确认 Mac 的“编辑 → Ubuntu 中文兼容输入”可点击且未勾选；原版成功那次的开关状态不确定。只勾选现有开关后，用户反馈“我打开后，中文输入正常了，warp也正常了”，即当前 FarPane 的 Chrome/Warp 中文在兼容模式下可用。本次没有新安装或产品改动，仍是 GUI `0.1.0-dev.20261019.1`、`.8` 核心 `c403acbf…`；FarPane active、原版 inactive。用户可先保留该设置使用。

这验证了可用的兼容路径，**没有关闭默认模式中文失败的缺陷**。Mac 仓库源码在非 ASCII `sendText` 成功后补发 Ctrl+Shift+V，与原版捕获到的额外 Shift/Ctrl 形态吻合，但原版开关、字母 V 和实际 Mac 二进制未核对，不能把原版成功完全归因于此。没有专门验收连续提交、重复文字或重连后偏好持久化；源码按设备 UUID 保存偏好，未保存设备的快速连接可能换 UUID。后续应讨论统一文字提交及兼容设置的行为，暂停的 `0044` 应用名特判不因此恢复。证据见[对照与开关结果](../../Evidence/LinuxHost/2026-10-19-original-input-ab/README.md)，已通过 OCS seq38 交给 Claude。以下为历史修复与诊断记录。

**2026-10-19 安装更新：** 用户明确要求“你来安装吧，我来测试”，Codex 已完成 `.8`（`79e6fd6f2505d006beeb4e71`）的 stage、维护切换和用户菜单绑定。root PID 1474136 / Host PID 1474420 均为新核心 `c403acbf…`，服务正常、注册成功；ID 1000000000、固定密码/密钥与全部配置选项前后相同，旧版本保留。未重新编译、修改 Mac 或操作 RustDesk。真实 Mac 中文效果等待用户测试；Warp 与交付材料未关闭项保持原记录。见[安装证据](../../Evidence/LinuxHost/2026-10-19-native-input-install/README.md)。下面“未安装”是此前构建时的状态。

**2026-10-19 Claude 接手结果：** 新增 `0045-native-committed-text-state.patch`，内容如下：
- 把 Mac 整段 Seq（含纯 ASCII）视为字面文字：提交前先查询 Ctrl/Alt/Meta，查到按下就成对释放。
- 状态查询失败时报错，并整体丢弃这一次提交，不重放。
- 增加不含正文的阶段日志（Seq 到达、释放了哪些修饰键、剪贴板写入完成）。

不按应用名特判，粘贴快捷键不变，0044 仍暂停，没有混入。这次从冻结的 `.7` 派生 `.8`（`farpane-native-dev-79e6fd6f2505d006beeb4e71`，Deb SHA-256 `ea15afb1…`）：只重编了核心，GUI 与 `.7` 相同。

验证结果：在真实网络/root uinput 的 VM 中，`.7` 在新增的 “Control 残留 + ASCII” 用例失败；`.8` 在 Chrome、GTK4、VTE 上四个用例全部通过；Ubuntu 24.04 Deb 升级测试通过。

**未安装，真实 Mac 根因尚未确认。** 实机日志只间接表明中文进入了剪贴板路径。Warp 不接受 Shift+Insert 的问题仍待讨论。详见[修复证据](../../Evidence/LinuxHost/2026-10-19-native-input-fix/README.md)。

**2026-10-19 最新用户指令：** 本次真实 Chrome 测试为“英文正常，中文没有”。用户要求结束日志采集并交给新 Claude 线程继续修复；本 Codex 已停止采集和产品开发。接手说明、实测证据和边界见 [Claude 修复交接](chinese-input-handoff-20261019.md)。下面“采集窗口已开始、待回收”为此前准备时的状态，现已结束。

## 当前：准备一次真实连接的现有日志采集

用户报告 Mac mini“关于”为 **v2.0.8**，尚未核对该客户端的实际二进制，不将它改写为其他版本号。用户愿意在日志准备好后提交测试文字。本次先采用不更换服务的只读采集，不将上一节讨论中的完整阶段诊断误称为已经实现。

`Scripts/linux/observe-native-input.py` 核对当前 release、manifest 核心哈希、root/Host 的可执行文件、参数和进程代际，然后从两份实际打开的日志的 EOF 开始读取。只导出固定的输入错误分类、后端事件计数与既有 `NativeActivity` 连接计数；原日志正文只在内存中分类，不保存或输出，不读取剪贴板、输入设备、应用窗口或身份配置。最长 600 秒；进程/版本变化、日志轮转或截断会结束采集，不把历史记录混入本次结果。没有提高日志等级或改变输入行为。

8 项隐私/日志边界测试及 2 秒实机预检通过。实机预检为 `.1`、root PID 64215 / Host PID 1362864，核心 SHA-256 `bd6d8c376299fe8c5313daa06d79a1820ebfe2f9f9ef32d06b758bccfae259e3`，当时入站连接为 0。准备及实际采集记录在 `Build/Linux/native-input-observer/capture-4m7rfq1h/`；正式 600 秒窗口已开始，用户测试结果待回收。若窗口结束后用户才回来，先重新建立一次有界采集，再请用户输入，不假称一直在记录。

第一轮仅在 Ubuntu Chrome 输入框先输入 `abc`，再以 Mac 输入法提交 `中文测试`，不粘贴、不按回车。只需报告英文/中文分别是否出现。现有 `.1` 没有完整的非 ASCII Seq 收取、剪贴板成功和内核注入观测，因此 **无错误日志不能证明文字已到达 Linux，也不能证明应用已消费**。若这轮证据不足，再准备完整诊断候选；未构建/打包/安装这样的候选，未改 Mac、暂停的 0044、当前服务或桌面。

## 2026-10-19：与新 Claude 线程的两轮设计评审

用户要求通过 ocs 与新线程讨论。参与者是本 Linux owner 与 `claude-08da8438`，没有唤醒旧开发线程。第一轮源码评审后，Codex 对输入确认、IBus 可行性、失败时释放按键和修饰键修复范围提出四项修正，Claude 在第二轮同意收敛。原始消息和边界见 [讨论证据](../../Evidence/LinuxHost/2026-10-19-native-input-review/README.md)。

本轮只更新讨论文档和证据；没有改产品代码、运行输入实验、编译或安装，没有操作用户桌面、真实剪贴板或服务。当前仍为 `.1`，它不包含后来在 `.3` 核心中验证的 `0043`。后续 `.7` 只是复用该核心的 GUI 候选，也未安装。用户实际中文问题仍然开放。

### 已收敛的方向

1. **文字提交和快捷键分开。** Mac 的 `insertText → send_text → input_string → Legacy Seq` 已在表达字面文字；不应再让客户端猜目标应用需要哪个粘贴快捷键。Linux 负责将已提交文字送入目标输入链路，物理按键/热键保持各自语义。
2. **保留有证据的通用修正。** DISPLAY 地址过滤缺陷和残留 Control 的对照都成立，不能把既有代码一概否定。`0043` 的修正语义应保留，但它当前位于剪贴板路径；纯 ASCII Legacy Seq 仍有源码可见的修饰键覆盖缺口，本轮未动态复现。要先盘点 Seq、Unicode、Chr 和 Translate 的字面文字/热键分支，再决定统一清理的位置，不能简单搬一行代码而破坏其他路径。
3. **不采用应用名特判作为整体修复。** `0044`/`paste_target.rs` 继续作为暂停的实验草稿保留，不从活动树构建。Mac 的兼容开关在文字入队后补发 Ctrl+Shift+V，与服务端自动粘贴叠加有重复风险；它也不适合作为统一方案。没有在本轮移除草稿、修改 Mac 或改变用户设置。
4. **暂不承诺新的通用后端。** IBus 仅列为 GNOME 私有桌面上的可行性研究候选。必须证明正确焦点、引擎共存、不切换用户输入源、限定 UID/会话，以及跨目标应用的实际提交。应用能接受本机输入法，不等于 FarPane 能安全地通过外部 IBus 接入提交。现阶段不能据此承诺替代剪贴板或覆盖其他 Linux 桌面。
5. **不让应用改键承担主修复。** Warp 快捷键差异实验保留，但不把要求用户修改 Warp 快捷键作为 bug 修复步骤；显式选择某个粘贴快捷键也不是统一中文输入方案。

### 对初稿的关键修正

- `send_text` 返回 0、剪贴板设置返回、IPC 写入、内核事件和应用消费是不同阶段。目前 `UInputKeyboard::key_down` 的错误记录后仍返回 `Ok(())`，`paste-queued` 不能表示应用已收到文字。
- SelectionRequest / Wayland send 最多是中间读取观测。必须考虑代理、管理器和缓存；有读取不能证明焦点应用插入了文字，未观察到读取也不能单独判定目标未消费。不能用它自动补发、宣称零丢字或代替最终验收。
- Claude 已收回“查询失败就无条件释放八个修饰键”的建议。后续应区分查询失败与未按下，识别输入设备/会话代际；未知状态下中止该次事务并报告失败，保留禁止自动重放的规则。成功路径也要限定 FarPane 自身虚拟输入状态，不能宣称能释放宿主物理键盘。
- 剪贴板写入后的固定等待、连续提交和入站剪贴板同步存在需验证的竞争风险。本轮没有复现这些竞争，不能作为用户此次故障的已证实根因；串行化和有界等待仍是待验证设计。
- Mac 灰色菜单由 `viewerView`、`coreClient`、`viewerRecoveryDeviceID` 三项会话条件决定。正常连接入口已创建 UUID；仅凭灰色不能归因于未保存设备或版本过旧。应核对实际构建和这三项状态，避免继续让用户盲找开关。

### 建议的下一步（未执行）

先讨论上述边界，再做最小诊断候选：Mac 记录提交次数、修饰键位掩码、菜单状态和构建版本；Linux 记录收到 Seq、输入路径、状态查询错误、剪贴板设置、IPC/内核注入的阶段结果。需要可关联的事务/会话标识；不记录正文、正文哈希、剪贴板文字或普通按键内容。读取事件仅作辅助信号。

真实诊断需要 Mac 端 owner 配合，当前 Linux 线程没有修改 Mac 的授权。候选完成后在维护窗口核对确切已激活版本，再抓取一次真实 Mac→linux-host 失败。基于结果决定修饰键覆盖和剪贴板事务修复；最终至少验证 Chrome 与 Warp 的普通中文、输入源切换后提交、混合文本、纯英文及连续提交，检查准确、无重复和无残留按键。应用消费由测试目标或用户确认，隔离 VM 通过不等于真实 Mac 已修好。

本次讨论未自动恢复中文方案的实现、打包或服务切换；内存优化仍暂停。

## 方案暂缓：用户要求先讨论输入设计

2026-10-18 最新指令，用户原话：

> 为什么会针对一个单独的程序去修复，这个感觉不符合常理，warp 他自身的快捷键是ctrl shift v 这个感觉不应该这样修，感觉不太对，你先记录下来，后面再跟我讨论下

按应用名识别 Warp、选择 Ctrl+Shift+V 的方案暂缓，不继续推进该方案的实现、测试、Release 构建、打包或安装；先保留证据和未提交代码，等待与用户讨论。最后一条已在执行的 debug 编译现已结束，2 项单测通过，1 项隔离集成测试未在这条命令中运行；没有再启动新测试。

用户质疑的是输入设计本身：Warp 的 Ctrl+Shift+V 是应用的粘贴快捷键，不能仅凭这个差异就认定远程中文提交应按应用选择快捷键。用户同时报告 Chrome 输入框也失败，因此还必须解释跨应用的实际故障；后续先讨论统一文字输入与剪贴板兼容方案的职责和边界，再决定是否需要任何应用例外。

已知事实：同版本 Warp 在空白、离线、未登录配置下，正确聚焦后 Shift+Insert 没有粘贴，Ctrl+Shift+V 能输入并由真实 shell 写出完整中文/混合文本。试验性的生产函数集成用例也通过，但最终按键以私有 XTEST 代替硬件写入，没有覆盖 Warp 的完整网络/root-uinput 或用户真实 Mac 连接。详见[本轮证据](../../Evidence/LinuxHost/2026-10-18-native-warp-input/README.md)。这个结果证明快捷键有差异，**不证明按应用名特判应成为正式修复方案，也没有关闭用户报告的中文输入缺陷**。

后续讨论应先厘清：

1. Mac 输入法提交的文字，在协议与 Linux 接收端应如何处理；文字提交和键盘快捷键是否应该分开。
2. 当前依赖剪贴板加模拟粘贴的原因与适用边界，是否有适合本项目的通用输入路径，以及 X11、Wayland 和终端的实际限制。
3. 是否需要应用例外；若确有必要，应由什么能力或明确配置驱动，而非未经设计讨论就扩展应用名名单。
4. 将协议收到文字、Linux 输入后端实际发送、目标应用收到文字分开验证，避免再把局部通过当成整体修复。

代码保留状态：`Linux/patches/0044-native-warp-paste-shortcut.patch`、`Linux/native/paste_target.rs`、`Linux/native/mod.rs`、`Linux/native/input_tests.rs` 及 `Linux/dependencies.lock.json` 中的相关接入仍是实验草稿。草稿尚在活动源码/pin 中，后续不能直接沿用它构建新候选；待讨论后再决定重做、隔离或采用。没有丢弃既有未提交文件。已安装 `.1`、既有 `.3`、ID/密码及当前服务未改变，未提交/推送。

## 先前修复与实验记录

2026-10-18 UTC。用户报告 Mac 已选定汉字，提交到 linux-host Ubuntu 终端后没有文字；Mac 的“Ubuntu 中文兼容输入”菜单为灰色，未验证开关切换成功。当前分支为 `codex/linux-host-gpu-media`，修复基于 `0b73812`，实机已安装 DISPLAY 修复候选，但中文输入缺陷仍未通过用户验收。

GNOME 50.1 的 `ibus-x11` 使用 `DISPLAY=unix:/tmp/.X11-unix/X1`，并带有当前登录的 XAUTHORITY 和 WAYLAND_DISPLAY。原生桌面发现会选择这个较新的、已按登录边界校验的桌面组件，但原 `local_display` 只接受冒号编号形式，将该 DISPLAY 删除。Host 日志因此出现 `set_clipboard_content` / `X11 server connection timed out because it was unreachable`。中文路径在写入剪贴板时已经返回，补发终端快捷键无法修复。

`Linux/native/discovery.rs` 现在接受严格的 `unix:/tmp/.X11-unix/X` 加十进制编号形式，并保留原始值。不能把它改写成 `:1`：Mutter 的 managed listener 与公开 display 共用服务器，X11 客户端对直接 socket 地址的认证处理也不同。远程主机、其他目录、路径穿越和非法编号继续拒绝；桌面 UID、登录来源、Wayland socket、会话授权及输入链路不变。

验证已通过：4 项 discovery 单测；私有 Mutter 50.1/Xwayland 下的 GTK4 Wayland 输入框与 GTK3 VTE 终端两项实际粘贴测试。两项均复现缺少 DISPLAY 的初始化失败，再使用修复后的地址和现有 `set_text_clipboard_with_owner_sync`，通过 Shift+Insert 输入“中文测试”、中英文/标点/emoji 混合和 Latin-1 字符，累计内容完全相同且没有重复。终端样本读取独立 PTY 的输入流。没有修改 Mac，也没有把这两项等同于真实 Mac 网络连接验收。

复现入口：

```sh
Scripts/linux/container.sh -c 'cd /workspace/Build/Linux/src/rustdesk && cargo test --offline --locked --no-default-features --features farpane-native,linux-gpu-media --lib farpane_native::discovery::tests -- --nocapture'
Scripts/linux/test-native-gnome-input.sh Build/Linux/target/debug/deps/librustdesk-092117bf2c9dd4c1 entry
Scripts/linux/test-native-gnome-input.sh Build/Linux/target/debug/deps/librustdesk-092117bf2c9dd4c1 terminal
```

测试二进制文件名由 Cargo 决定；使用本次编译实际生成的 `librustdesk-*`。测试镜像和 Dockerfile 固定在依赖锁中，网络关闭，仅挂载本仓库及其 Build，没有宿主显示、总线、GPU 或 uinput。初次将 managed listener 改写成 `:1` 的尝试超时，原始失败保留；改为保留原值后通过。另一个已放弃的 Mutter Unicode keysym 实验虽获 API 成功回复，但 CJK 未映射到键码，实际输入失败，其生产 hook 已移除，未构建进安装版本或修复包。

原始日志、失败与测试范围见[本轮证据](../../Evidence/LinuxHost/2026-10-18-native-ime/README.md)。修复包随后已在维护窗口安装，Mac 对 linux-host 的 Warp 和 Chrome 仍未通过验收；GUI 内存目标与其他未完成验收不在本次修复范围内。

修复候选已完成：`Build/Linux/debian/farpane-native-candidate_0.1.0~dev.20261018.1_amd64.deb`，SHA-256 `9960dfb15c170d66c23677c006f9c37633f4c9ccf47cd72ab0e1809e8fc353e9`。Release 及 canonical 来源检查通过，GUI 原始字节不变。完整 bundle manifest、Deb 解包/安装器源码比较和包内核心启动探针通过；已完成 stage/plan，并在用户批准后激活及绑定用户入口；新 release 确为 `bfc1befc…`，核心进程可执行文件哈希已核对。新包内带本次 canonical 修改与构建记录；旧的完整独立源码归档并未重打包，不将其称为包含本次修复。

## 2026-10-18 复查与无人值守回归

用户补充 Warp 与 Chrome 都无法输入，并要求离开期间继续无人值守推进。复查确认原 DISPLAY 修正有依据，但上一轮测试直接调用剪贴板写入，另用手写按键与额外延迟驱动私有桌面，绕过了生产粘贴函数、网络消息分发和 root uinput。它不构成实际中文输入验收。

对当前安装版的只读检查：身份注册与已认证入站均存在，键盘权限开启；FarPane 标记的 X11 和 GNOME/Wayland 剪贴板都可读取含 CJK 的数据。诊断只保存格式/布尔值，不保存正文。GNOME `SelectionOwnerChanged` 的 `mime-types` 在此版本实际套有 `(as)` 元组；第一次元数据脚本误判为空，修正解析后撤销了“X11 到 Wayland 未交接”的判断。此轮没有新增 GNOME 剪贴板后端。

新隔离回归调用真实 `input_text_via_clipboard_server`、保留其 50 ms/20 ms 时序，使用产品 uinput 键码映射，仅将最终硬件写入替换为私有 Mutter 键盘。没有预先写入剪贴板，也没有人为延长按键间隔。GTK4、VTE 和独立 Chrome 在普通状态下均通过。

加入“提交期间 Control 尚未释放”后，修正前测试稳定出现：剪贴板已变为第二段中文，焦点仍在输入框，输入框内容却未增加；发出的实际组合为 Control+Shift+Insert。Mac `input_string` 的 Legacy Seq 默认 `down=false`，不会经过普通 key-down 的修饰键同步，现有粘贴函数也未清理修饰键。`0043-native-committed-text-modifiers.patch` 在原生 Linux 的字面文字粘贴前复用已有 `fix_modifiers` 清理残留键，再执行 Shift+Insert；没有补发第二次粘贴。另加入不含文字正文的 clipboard-ready/paste-queued debug 日志；queued 不是目标应用确认。

相同测试修正后在 GTK4、VTE PTY 和 Chrome 155 的 Wayland 输入框全部通过：中文、中英/标点/emoji 混合、残留 Control、后续 Latin-1 文本及无重复检查。Chrome 使用只读程序目录、空白私有 profile、容器内回环页面；没有连接网络或用户桌面。完整 GNOME Shell 的隔离焦点夹具未建立成功，未计为通过。

这是已复现并修正的输入缺陷，但尚未抓到用户实机失败瞬间的修饰键状态，不能断言就是此次实机故障的唯一原因。网络输入、root uinput、Warp 本身和真实 Mac 仍需验收。原始失败、修正后结果与范围见 `Evidence/LinuxHost/2026-10-18-native-ime/review/`。Mac 源码与配置未修改。

本轮增量 Release 构建与源码一致性检查已通过：core SHA-256 `5b670364c6ae7b299985f8a4eb3463ae26b9cfb1b33a03b8e4dbe6116755d434`，GUI 与上个候选逐字节相同。计划 Debian 候选版本 `0.1.0~dev.20261018.2`；当前运行的 `.1` 不包含修饰键修正。配套源码/二进制以随后生成的产物清单为准，不能把候选回归写成已安装验收。

最终 `.2` 已构建并暂存，未激活。Deb SHA-256 `986b9c13d94347d88069351f951e1c96ea8abb2701a86c3cbeecb64c4482d148`；release `farpane-native-dev-67f5d1594e8961809614f4e1`。3,114 项 bundle 校验、Deb payload 与 7 份安装工具源码核对通过；Ubuntu 24.04 容器的包探针及两次软件视频连接通过，未重新跑 GPU/完整发行版矩阵。

配套完整源码归档 `farpane-native-source-e5ee1c6b1f0b19bec4af4b35.tar.gz`，SHA-256 `32d8d63b446de5c465e8f5a2a7f86c74b4747866aa9f0e32b86e0aef4f0715ad`。归档全部 91,461 条目逐项校验通过，空 Cargo home、无仓库/旧编译缓存挂载的断网容器中，core/GUI 依赖图均解析至归档内。未重复完整源码编译，也未重建 FFmpeg。712 个审计依赖、45 条未关闭材料记录与此前相同。

维护计划仍要求窗口：当前 `.1` 服务和连接保持运行，`.2` 切换与真实 Mac→Warp/Chrome 验收未执行。当前工作区改动未提交或推送。

后续无人值守工作新增[独立内核回归](native-input-vm.md)，已验证 guest 内核 uinput 往返及真实 root/Host 设备建立，尚未覆盖完整网络中文到应用的结果。过程中另复现并修正 Linux Viewer 对 Wayland 屏幕选择提示的错误状态映射；`.3` 包含该修正及 `.2` 的输入代码，已生成但未安装。它没有证明本次 Mac 中文缺陷已修好；当前 `.1` 服务和连接仍保留。

进一步已建立真实 GNOME/logind 的私有 VM：原始 `.3` GUI、网络、Host、root 特权 IPC、内核键盘与 Wayland 应用连成完整链路，VTE PTY 和 Chrome 均实际收到“中文测试”，旁读 evdev 的四次粘贴序列完整且无重复。GTK4 结果、六项入口保护和全部环境失败记录集中于[真实 GNOME 回归证据](../../Evidence/LinuxHost/2026-10-18-native-input-vm-desktop/README.md)。未替换按键后端，未直接写目标文本；未安装新候选。Linux GTK 逐字 Seq 不等于 Mac 多字单次 `input_string`：后者及残留修饰键的完整网络对照、Warp 和用户实际连接仍待验证，缺陷保持打开。

随后已补齐 [Mac 式整段 Seq 与旧版对照](native-input-vm.md#mac-式-seq-与旧版对照)：正常多字 Seq 在 `.1` 可用；Control 被真实内核确认按下后，`.1` 的 GTK4/Chrome 有焦点却不增加文字，VTE 则仍能粘贴但留下 Control。`.3` 在三类目标均先释放 Control，再准确粘贴整段中文及混合 emoji/Latin-1，无重复。这是原始包的实际认证 TCP→Host→root/uinput→GNOME 对照，未用虚拟键盘替代生产输入；测试端复制 Mac 的消息构造，没有运行 Mac GUI。仍缺用户实机失败瞬间的按键状态，故不宣称唯一根因或已完成 Mac/Warp 验收。8 项入口保护、3 项协议检查通过；本轮不修改产品，也未激活 `.3`。

## 2026-10-18 输入后恢复剪贴板（0046）

剪贴板路径输入中文时，每次提交都会把文字写进 CLIPBOARD 再发送粘贴键，上游刻意不恢复原内容，用户此前复制的内容（包括 Mac 同步过来的内容）因此被最后一个输入的字覆盖。`0046-native-committed-text-clipboard-restore.patch` 仅在 `farpane-native` 构建中：

- 一段连续输入开始时，用 `ClipboardContext::get` 读取 CLIPBOARD 的全部已支持格式作为快照；读取失败或为空时不恢复。
- 最后一次提交后静默 1.5 秒再恢复；期间新的提交顺延，不在连续输入中途换回旧内容，避免目标应用读到旧剪贴板。
- 仅当 CLIPBOARD 仍然恰好是 Host 刚粘贴的那段文字时才写回，期间本机或远端复制的新内容不会被覆盖。
- 写回内容带 RustDesk owner 标记，Host 剪贴板 Reader 照常排除，不会回发给远端。

限制：1.5 秒是经验值，目标应用若在静默期后才读取剪贴板，仍会读到恢复后的内容；文件 URI 剪贴板不在快照格式内，不会恢复。
