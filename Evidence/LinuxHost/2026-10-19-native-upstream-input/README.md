# FarPane Linux GPU 媒体重构（linux-host）：原版输入对照

用户确认同一 Mac 客户端、同一 linux-host、同一应用下，原版 RustDesk 中文可用，FarPane 中文失败。2026-10-19 开始以此作为回归基准，停止要求用户选择粘贴快捷键方案。

`baseline.json` 核对本机包与原始核心 SHA-256；`comparison.json` 记录从只读 Git pin 导出的五个文件与 `.8` 编译副本的哈希；四份 diff 是实际源码差异（其中 enigo 差异为空）。`original-log-stage-counts.json` 只含预设后端阶段的计数和时间，没有原日志正文。

细节与未证实项见 [输入路径比较](../../../Linux/docs/input-upstream-comparison.md)。导出工作目录为 `Build/Linux/upstream-input-i8xk7eoc`，没有写入只读 reference，没有切服务、编译、安装、提交或推送。首次导出误请求不存在的 `src/input.rs` 后停止；已完成的四文件保留并复核，后续添加实际的 `src/server/rdp_input.rs`，没有把失败导出当作完整扫描。

`post-capture-review/` 补充首次授权内核观察之后的只读复核：`.8` 剪贴板函数片段/哈希确认 PRIMARY 写失败仅记警告；过滤后的 `/proc` 数据确认 X0 公共入口与文件系统 X1 的 initfd 属于同一 Xwayland，abstract X1 由 gnome-shell 持有。没有连接这些 socket、读取剪贴板、打开输入设备或改变服务。`runtime-status.json` 使用实际的 `farpane.service`，并明确丢弃此前误查不存在的 `farpane-native.service` 的结果。上述事实不证明故障原因，原版服务 A/B 未执行。

其中 `native-clipboard-source-review.json` 是后续同步竞争假设的静态检查，包含八个冻结源码文件的片段/哈希及 0029/0040 补丁哈希。它记录 Host worker、权限/数据控制协议门槛、空消息拒绝和 owner 过滤，不包含剪贴板正文或实际竞争复现。初读 wire 登录禁用 clipboard，后续测试修改由 Claude 负责；不能把此项记录当作新测试已经通过。
