# .8 实机失败后的只读定位（2026-10-19 UTC 约 01:00–01:15）

全部为只读或纯元数据检查：没有读取剪贴板正文，没有注入按键，没有改动桌面或服务。

- Host 日志（17:57 -07:00）中，3 次非 ASCII 提交都走完了以下阶段：`Native committed text`（released_modifiers=0b000）→ `clipboard written 0 ms` → `clipboard ready` → `paste key sequence queued`，期间没有任何 WARN/ERROR。说明文字确实到达，提交时也没有残留的 Ctrl/Alt/Meta。
- GNOME 选区元数据（Mutter RemoteDesktop 的 `SelectionOwnerChanged`；不调用 Start/SelectionRead）：当前选区包含 `dyn.com.rustdesk.owner` 标记及 `text/plain;charset=utf-8`、`UTF8_STRING`。说明 Host 写入的 X11 剪贴板已经交接到 GNOME/Wayland 一侧。
- `/proc/bus/input/devices`：只有一个 “RustDesk UInput Keyboard”（event7），KEY 位图包含 Insert(110)。
- 真实 Chrome 为 155.0.8059.84，运行在原生 Wayland（`--ozone-platform=wayland`），启动参数为默认值；IBus 在运行（`ibus-daemon --panel disable` + engine-simple），输入源 `[('xkb','us')]`；没有剪贴板管理器，只有 Ubuntu 默认扩展。
- 假设“IBus 异步处理按键导致粘贴组合键乱序”：先确认 GNOME Shell 50.1 的 `inputMethod.js` 确实以 `process_key_event_async` 过滤按键；随后构建同版本的 IBus VM 变体（`Linux/packaging/native-input-vm-ibus.Dockerfile`，ibus 1.5.34~rc2-1 / gnome-shell 50.1 与 linux-host 一致；锁定于 `native-input-vm.lock.json` 的 `ibus_variant`；`prepare-native-input-vm.py --ibus`）。`.8` 的 Chrome wire 测试在该变体中四例全部通过（`Build/Linux/native-input-vm/run.hts6tq9g`），**这个假设没有得到支持**。
- 期间 linux-host 已切换到 `farpane-native-dev-9a76a6c2af66e3955470ea24`（core 仍为 `.8` 的 `c403acbf…`，GUI 来自 Codex 版本号任务），root PID 变为 1497504。此后 Host 日志没有新的提交记录。

结论：剪贴板写入与 Wayland 交接都已确认正常；失败位于“粘贴组合键 → 真实 Chrome 执行粘贴”之间，具体原因仍未知。下一步需要用户做一次拆分测试来区分。
