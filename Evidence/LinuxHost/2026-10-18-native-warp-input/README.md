# FarPane Linux GPU 媒体重构（linux-host）：Warp 中文粘贴差异

**最新决定：用户要求暂缓应用特判，先记录、后续讨论。** 以下实验结论保留，但不代表采纳 `0044` 方案；不继续该方案的实现、测试、Release 构建、打包或部署。具体疑问与草稿状态见[讨论记录](../../../Linux/docs/chinese-input.md#方案暂缓用户要求先讨论输入设计)。

2026-10-18 UTC，分支 `codex/linux-host-gpu-media`，基于 `0b73812` 的未提交工作。用户离开期间继续无人值守；本轮不操作宿主桌面，不安装/切换服务，不提交或推送。

## 实际发现

公开安装的 Warp `0.2026.10.14.08.27.stable.01` 在断网、空白配置、未登录账号的私有 Xvfb 中：焦点明确指向 Warp 后，**Shift+Insert 不粘贴，Ctrl+Shift+V 可以粘贴**。后者经实际 shell 执行后写出的文件精确包含 `中文测试混合A1，🙂é`。剪贴板与 PRIMARY 使用不同的合成命令；没有读取用户剪贴板，结果也不是从测试输入直接复制生成。

`probe-13` 与 `probe-14` 均复现此差异。`before-paste-windows.json` 及每项按键后的窗口记录核对实际焦点；`probe-14` 额外记录实际 WM_CLASS 为 `dev.warp.Warp\0dev.warp.Warp\0`。这是实际 Warp 的局部输入检查，尚不等于 FarPane 网络/root-uinput 或真实 Mac 验收。

因此 `.3` 中清理残留 Control 的修正仍不足以覆盖这个 Warp 版本：原函数随后依然发送 Shift+Insert。新增 canonical `0044-native-warp-paste-shortcut.patch` 与 `Linux/native/paste_target.rs`，仅在当前焦点明确属于 Warp 时选择 Ctrl+Shift+V，其他应用保留 Shift+Insert；不连续发送两组快捷键。查询不读取剪贴板/窗口正文、不改变焦点；单个工作线程、单请求队列与 100 ms 等待限制，超时不重用旧焦点结果。应用子窗口可继承父窗口 WM_CLASS，另一个带类名的窗口、None/PointerRoot/根窗口均不继承旧 Warp。

## 环境与失败记录

复用既有固定镜像 `sha256:675620953da21b80eb9d9ff13968ecc96eb6408c12f643ef2d50a8e3edc5ee51`。容器无网络、宿主显示/总线/输入/GPU，4 核/4 GiB、只读根目录、非 root、capabilities 清空；新 HOME 位于容器 tmpfs。只读挂载公开 Warp 程序、两份公开运行库和一份公开根证书；不复制用户配置、账号或密钥，不安装宿主依赖。程序目录完整清单与依赖哈希在 `warp-program-manifest.json` 和每轮 `inputs.json`；后期入口在运行前核对完整清单。

- `probe-01/02`：缺少 libxkbcommon-x11；`probe-03/04`：缺少系统 CA，Warp 启动退出。随后仅给隔离进程提供固定的公开依赖。
- `probe-05` 至 `probe-10`：逐页检查私有首次启动，采用界面明确提供的 Skip/Skip for now，未登录。没有账号阻塞，也没有绕过认证。
- `probe-11`：未明确设置 X11 键盘焦点，两组按键均无结果，不计为 Warp 快捷键结论。
- `probe-12`：误把 GDK 维护的窗口列表当作 X 服务器全列表，测试提前拒绝；修正为 XQueryTree/XGetInputFocus 后的 `probe-13/14` 才是有效对照。

第三方启动日志中自带的 OAuth/遥测静态配置整行省略，其余故障与输入日志保留。没有复制任何用户日志。早期探索轮仅记录当时 hash；`probe-13/14` 开始额外保存完整测试/入口源码快照。`probe-14/report.json` 记录新建的未登录测试 profile 的文件清单和 SHA；归档只保留在 Build，供后续独立 VM 使用，不作为用户配置或发行产物。

## 复现入口

```sh
python3 -B Scripts/linux/probe-native-warp.py
python3 -B Scripts/linux/test-native-paste-target.py Build/Linux/target/debug/deps/librustdesk-092117bf2c9dd4c1
python3 -B Scripts/linux/probe-native-warp.py Build/Linux/target/debug/deps/librustdesk-092117bf2c9dd4c1
```

第三条额外执行生产粘贴函数的 Warp 集成用例；测试二进制文件名以实际 Cargo 输出为准。实际修改范围和最终验证状态以本目录后续结果及 `Linux/docs/chinese-input.md` 为准。

已完成的生产函数用例位于 `production-01`：普通中文与残留 Control 均通过，实际 Warp/shell 写出 `中文测试控制提交混合🙂é`，最终输入后端仍是私有 XTEST，未测 Warp 网络/root-uinput。`selector` 的真实 X11 焦点/应用边界集成通过；GTK4 与 VTE 的生产函数回归通过，Chrome 未执行本轮新代码回归。首次编译的 AtomEnum 转换、后续测试返回类型错误均已修正，失败日志保留。最后增加迟到响应拒绝单测后的 debug 构建完成（2 passed、1 ignored）；用户要求暂缓后没有重新执行集成或生产函数用例，不能将此前集成结果改称该最后快照已重测。

边界：当前 linux-host 仍运行 `.1`（release `bfc1befc221061266d5f50da`，root PID 64215、Host PID 70886）；`.3` 未改变且不包含新增 Warp 修正。原始 Mac 输入法、Warp 原生 Wayland 模式、真实连接故障瞬间、灰色 Mac 菜单及维护窗口验收仍未完成。
