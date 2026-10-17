# FarPane Linux GPU 媒体重构（linux-host）：设备管理检查点

2026-10-16，HEAD b01c40b，工作分支 codex/linux-host-gpu-media；未提交、未安装。

设备列表现在接真实配置后端：成功呈现第一帧后记最近连接，支持中文别名、收藏、搜索、仅收藏筛选、带确认的忘记操作与快捷连接。GTK ListView 复用行；离开首页后释放其控件。记录按 ID 服务器与公钥区分，变更中继路由不另造设备身份。保存密码/Secret Service 和远端主机名称仍未实现；本阶段显示 ID 或用户别名。

存储由 agent/离线 helper 的同一个 owner 锁、revision 与两文件持久事务执行，Viewer 只通过 GUI 请求记录。最多 128 项、序列化 24 KiB；自动淘汰最旧未收藏项，收藏不自动删除。损坏/未来版本记录拒绝覆盖。记录不含密码、令牌或远端配置文件。

## 实际检查

- 轻量协议 21 项测试通过（含服务器/公钥隔离、收藏保护、字节上限淘汰、损坏记录拒绝）；GUI 3 项测试和 Release 通过；核心 Release 3 分 26 秒完成，未重建 FFmpeg。
- 离线真实 CLI 完成设备创建、中文别名/收藏、重开读取、相同 ID 换服务器隔离、旧 revision 拒绝、忘记及身份/认证保留；原有事务故障/恢复检查仍通过。
- `host-gui/device-ui/devices-ui.json`：实际 GTK 搜索、空筛选、仅收藏、收藏按钮、编辑对话框、编辑后搜索、删除确认均通过；结果由同一 Host agent 持久保存并再次读取。私有 Xvfb 日志有无法找到 DRI3 的 EGL 诊断，无 GTK CRITICAL。
- `host-gui`：两个 GUI 打开/关闭循环和离线配置 helper 通过，同一 Host 保留，未加载旧 GTK3/Flutter/Sciter。
- `gpu-viewer`：私有 Xwayland 上两次网络登录、错密码重试、VAAPI DMA-BUF 呈现、共享 GLES context、完成归还和 worker 回收通过。新历史记录递增 revision；ID、认证、服务器、共享和 GPU 设置保持不变。GPU GUI 日志无报错。
- canonical overlay/hash 验证 PASS。初次协议测试之后 GUI 构建命令的相对目录写错，原始失败日志保留；修正命令后 GUI 编译与实际测试通过。

全部测试在私有容器中，网络为 loopback-only，独立测试配置与不可变测试 release。GPU 测试仅 renderD128、256×128 静态内容，既有 FarPane 连接持续为零；没有原 RustDesk/安装 FarPane/宿主桌面写入。

源文件与已测二进制哈希见 source-state.json。原始截图、日志和 JSON 保留。后续重连开发另行记录；本检查点不包含重连、20 轮泄漏、真实桌面、Secret Service、全部共享能力、文件、音频或完整安装发布验收。
