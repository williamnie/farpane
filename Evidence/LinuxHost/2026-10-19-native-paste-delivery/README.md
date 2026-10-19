# 2026-10-19：GNOME 实机粘贴送达追踪与 Warp 粘贴键修复

北京时间 2026-10-19 下午，linux-host 真实 GNOME Wayland 桌面，Mac mini FarPane 客户端连接。

## 方法

`Scripts/linux/observe-paste-delivery.py` 只连接 Xwayland 显示，被动记录：

- CLIPBOARD/PRIMARY 归属变化（XFixes），按进程标签区分；
- ConvertSelection 请求（RECORD）：请求进程标签与目标类型；
- Xwayland 收到的 Shift/Control/Insert 键，以及按住 Control 时的 V（只有 X11 焦点可见）；
- Host 核心日志中的固定阶段行（提交编号、字符数、阶段时间）。

不读取剪贴板内容，不记录其他按键，不写入显示、剪贴板、输入设备或服务。7 项单元测试覆盖日志白名单、正文不外泄、Xauthority 与 RECORD 解析和分组。原始 JSONL 只保留在 `Build/Linux/native-paste-delivery/`。

| 抓取 | 记录 | 粘贴 | Xwayland 收到的按下事件 | events.jsonl SHA-256 |
|---|---:|---:|---|---|
| round1（Orca 运行） | 1202 | 50 | Shift_L 98，Control_L 47，V 47，**Insert 0** | `71fc8e5b8b26b1322c40ce379c89628e7ffb2b8c84f76dfbdc9fb8afd835a926` |
| round2（Orca 关闭） | 1548 | 62 | Shift_L 109，**Insert 59**，Control_L 50，V 50 | `3e60300c70e35eff46d5d9fe9f064cf370d6658091ce55d9085593331e11d645` |

## 结论

1. **默认模式失败的根因是 Orca 截走 Insert。** `org.gnome.desktop.a11y.applications screen-reader-enabled` 为 true，Orca 自登录起运行，无用户配置，默认把 Insert 作为 Orca 修饰键。round1 中 Host 的 Shift+Insert 只有 Shift 到达应用，Insert 一次都没有；此前 `2026-10-19-original-input-ab` 已证明 Insert 到达内核 uinput。用户确认并非有意开启。经用户同意执行 `gsettings set … screen-reader-enabled false` 后 Orca 退出，round2 中 Insert 正常到达。
2. **剪贴板链路正常。** 每次 Host 写入后，Mutter 立即以 TARGETS/UTF8_STRING 从 FarPane 取走内容供 Wayland 侧使用；Warp 收到 Ctrl+Shift+V 后 1–3 ms 内读取 UTF8_STRING。Chrome 通过 Mutter 缓存读取，本工具看不到 Chrome 的按键和读取。
3. **Orca 关闭后的用户结果：** 兼容开时 Chrome 出现两份（Host Shift+Insert 与 Mac Ctrl+Shift+V 叠加），Warp 一份；兼容关时 Chrome 正常、Warp 无输入（Warp 默认不绑定 Shift+Insert）。
4. **按用户决定恢复 Warp 白名单（0044）。** 首个候选 `farpane-native-dev-5fa249cc80da8383e325acd9` 日志始终为 `paste shortcut ShiftInsert`：Host 的 `DISPLAY=unix:/tmp/.X11-unix/X<n>` 无法被 x11rb 0.12 解析，焦点查询连接失败后按设计回退。`paste_target.rs` 改为复用 `clipboard_x11::connect()` 并对连接失败记日志。修正版 `farpane-native-dev-12a7610123e68eed56441923`（核心 SHA-256 `4aa000d6a27fa99e441a5cbcb2d45ff598c2bf472b132bcbf778e047f438c85b`）在当前安装版上只替换核心，GUI/媒体未重编；`paste_target` 2 项、`input_service` 7 项测试通过。
5. **修正版实机结果：** 兼容关闭，用户确认 Warp 与 Chrome 都正常出中文；日志中 Warp 4 次 `ControlShiftV`、Chrome 2 次 `ShiftInsert`。

## 边界

- 应用名白名单只覆盖 Warp（精确 WM_CLASS `dev.warp.Warp`），焦点查询 100 ms 超时或失败时回退 Shift+Insert；原生 Wayland 应用不经过 X11 焦点判断。
- Orca 再次开启时，任何依赖 Insert 的粘贴都会失效；不靠粘贴快捷键的提交方式仍待调研。
- Mac 兼容开关打开时仍会与 Host 粘贴叠加，当前建议保持关闭。
- 没有做连续提交、重连持久化、其他应用或其他桌面的专门验收。
