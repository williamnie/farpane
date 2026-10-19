# Mac 剪贴板同步竞争：隔离 VM 补测（模拟时序）

- 镜像：IBus 变体（`--ibus`），Chrome 155 使用 GTK4 + libim-ibus；bundle 为 `.8`（`79e6fd6f…`，core 为 `c403acbf…`）；场景 `--clipboard-sync`：登录选项 `disable_clipboard=No`（原测试端固定为 Yes，此前四例从未覆盖剪贴板同步）。
- 测试端发送的 Clipboard 消息：Message.clipboard(16){content, format=Text}，不压缩。发送时序是**模拟**的；真实 Mac 在 IME 提交前后发包的时序从未被观测过。
- 第一关正控制（`run.q2tpaj1z`）：先提交“基线”（Host 剪贴板被写为基线），再发 Clipboard“同步探针”，最后发 Ctrl+V。结果贴出的是“基线”：Ctrl+V 有效，但**Host 没有应用对端剪贴板**。原因与源码一致：0029 的 Link.receive → host_clipboard 的 Writer 在 Wayland 下只能用 clipboard_wayland，而它需要 ext/wlr data-control，GNOME 不提供（linux-host 实机 Host 日志中 arboard 也报告该协议不受支持）。`run.v3_migif` 是缺少基线的第一版探针，结果有歧义，保留。
- 在对端同步不可能写入的前提下，5 种顺序（无同步、仅前、仅后、前后都有、空值在后）全部只出现提交文字，没有被覆盖。
- 结论：在 GNOME（含 linux-host）上，.8 的 Mac→Host 剪贴板同步**不具备覆盖条件**。这属于“前提条件不满足”，不是“已证明竞争不存在”的通用结论。对照：原版走上游 update_clipboard → arboard X11，在 GNOME 上会应用 Mac 剪贴板（日志 `clipboard updated on host`）。这是原版与 .8 的一项实际语义差异，但它是否与中文粘贴成败有关，尚未证明。
