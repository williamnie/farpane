# 2026-10-19：经 IBus 提交中文（不用剪贴板和粘贴键）

linux-host 真实 GNOME 50.1 Wayland 桌面（IBus 1.5.34，输入源只有 xkb `us`），Mac mini FarPane 客户端连接，Mac 兼容开关关闭。

## 调研

| 方案 | 结论 | 依据 |
|---|---|---|
| RemoteDesktop 门户 `NotifyKeyboardKeysym` | 不可行 | Mutter 50.1 `meta-virtual-input-device-native.c` 的 `notify_keyval_in_impl` 只在当前布局中查找 keysym，找不到时记 `No keycode found for keyval` 并丢弃；中文不在 `us` 布局中。 |
| IBus 面板扩展 `CommitText` | 可行 | IBus 表情面板（`ibus-extension-gtk3`）就是这样提交文字：守护进程把扩展连接上的 `CommitText` 信号转给当前焦点的输入上下文（`bus/panelproxy.c`、`bus/inputcontext.c`）。 |

`ibus-extension-gtk3` 以 `ALLOW_REPLACEMENT | REPLACE_EXISTING` 持有 `org.freedesktop.IBus.Panel.Extension.Emoji`；被替换后留在队列中，名称释放或连接关闭时由守护进程自动交还（`bus/dbusimpl.c`）。守护进程启动时最先创建焦点占位的 fake 上下文，所以它固定是 `InputContext_1`；焦点停在那里表示当前应用不是 IBus 客户端，提交会被丢弃。

原型实测（Python，用户身份）：Chrome、Zed、GNOME 文本编辑器出字，Warp 不出字且文字没有进入其他窗口。Warp 当前进程环境没有 `XMODIFIERS`，公开问题 warpdotdev/warp#9383、#11524 也报告 Warp 在 Linux 上不启用输入法。每次提交后名称都回到原扩展进程。

## 实现

- `Linux/native/ibus_commit.rs`：在用户身份的 `--server` 进程内按 libibus 规则找到 IBus 地址，私有连接后取得面板扩展名称，读取 `CurrentInputContext`；不是 fake 上下文时发送 `CommitText`（`IBusText` 序列化与 libibus 相同）。一段连续输入保持名称，静默 1.5 s 后关闭连接交还。日志不含正文。
- `Linux/patches/0047-native-ibus-committed-text.patch`：只在 `input_text_via_clipboard_server` 开头增加调用；提交成功即返回，否则（无 IBus、焦点为 fake、出错）原样走剪贴板粘贴，Warp 仍用 `0044` 的 Ctrl+Shift+V。
- 观察脚本新增 `ibus_committed`、`ibus_no_client`、`ibus_unavailable` 阶段，并以 IBus 提交作为分组锚点。

## 验证

- 单元测试：`ibus_commit` 2 项、`input_service` 7 项通过（2 项需私有环境的按设计忽略）；观察脚本 8 项通过。
- 制品 `farpane-native-dev-b70112f157f588d4ea83f44b`，以 `farpane-native-dev-12a7610123e68eed56441923` 为父版本，只替换核心（SHA-256 `6dc10529c4c5a1c3ad3d28a45e0eab6ddcb1e066671423be3541ec8337f1365a`），GUI/媒体未重编。经用户同意已安装切换，上一版保留。
- 用户实测：Chrome、Zed、文本编辑器、Warp 中文均正常；复制内容在打中文后仍可粘贴；Chrome 快速中英混输顺序正确。
- 核心日志（测试时段）：`IBus commit sent` 9 次；`no IBus client focused; using paste` 5 次，均随后 `paste shortcut ControlShiftV`；无 `IBus unavailable`。测试后面板扩展名称已回到 `ibus-extension-gtk3`。

## 边界

- 只覆盖运行 IBus 的会话；fcitx 或无 IBus 时回退剪贴板。
- 连续输入期间及其后 1.5 s 内 IBus 表情面板（Ctrl+.）不可用。
- 读取焦点与发送之间焦点若切换，文字随 IBus 焦点走；未做专门验收。
- 没有验收密码框、重连后、其他桌面或长时间使用。
