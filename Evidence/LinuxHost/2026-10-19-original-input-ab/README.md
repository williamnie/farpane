# FarPane Linux GPU 媒体重构（linux-host）：原版输入对照与兼容模式验证

本目录先记录准备，随后新增用户明确授权的真实 A/B 与恢复。`preparation.json` 是执行前状态，冻结的 `preparation-plan.md` 与其中历史文档哈希一致；最新结果以 `real-capture/` 为准。

`preparation.json` 保存实际通过的 10 项新保护测试、11 项既有过滤测试、三文件只读基线命令和 canonical 源码哈希。原版 launcher/core/unit 的固定 SHA 在观察脚本中；`--check-baseline` 在本机退出 0，没有打开 evdev。底层九键过滤与服务 FD 绑定复用此前通过私有 KVM 的实现，未重复 VM 或执行原版真实 CLI。

`runtime-status.txt` 为准备后的只读状态：FarPane active、root 1497504、NRestarts 0；原版 inactive，二者均保留 disabled。原版既有 GUI 1360261 不匹配其当前 ExecStop 的宽泛模式，但窗口执行时仍须重新核对，不能把本次结果当永久保证。

`real-capture/` 保存 20 份过滤后的记录：两次 30 秒均 exit 0，原版进程/映射核心/虚拟设备归属已验证；用户 A 无中文有空格、B 中文成功。A 有一组 Shift/Insert，B 每组 Shift/Insert 后约 20.6ms 均多出一组 Shift/Ctrl 事件。没有采集普通字母键，不能直接把第二组认作粘贴操作。B 后续的两次剪贴板同步日志在观察结束后，另存为启动至停止区间，不能冒充窗口内对应证据。

北京时间 10:08:14–10:11:33 临时运行原版，之后恢复 FarPane root1604687 / Host1604822；release 与 core/GUI 哈希不变，原版 inactive，两边 disabled。原版自身重建过 GUI；恢复的首次保护拒绝后，对辅助 sudo、新 --no-server 和 --cm 逐一验证 PID/start/UID/exe，再按授权流程停止。GUI 未保留，但没有改服务单元或用户配置。元数据的错误 GUI 路径假设、原版时间戳解析差异及保护拒绝均在记录中说明。

恢复后用户重新连接 FarPane，确认 Mac“Ubuntu 中文兼容输入”可点击、未勾选，原版成功时开关状态不确定。只勾选现有开关后，用户反馈 Chrome 与 Warp 中文输入正常，记录在 `compatibility-toggle-user-result.json`。这次没有新安装、产品改动、服务切换或输入采集；02:22 UTC 只读服务核对仍为 FarPane active / root1604687 / NRestarts0、原版 inactive。

`mac-source-hypothesis.json` 保存此前只读源码推断及哈希：Mac 的兼容模式在非 ASCII 提交成功后补发 Ctrl+Shift+V，与 B 的额外修饰键形态吻合。它仍不是实际 Mac 二进制、B 偏好或普通 V 的观测。用户结果证明当前兼容模式可用，不证明默认模式缺陷已修复，也未专门验收连续提交、重复文字或重连后的设置持久化。已通过 OCS seq38 同步 Claude。

执行顺序、恢复与未验证边界见 [短时对照窗口](../../../Linux/docs/original-input-ab-window.md)。尚无新修复包，默认模式失败根因未确认。没有原始日志、凭据或剪贴板正文；用户反馈只作为测试结果记录，不是输入内容采集。
