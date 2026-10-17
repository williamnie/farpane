# FarPane Linux GPU 媒体重构（hermes）：真实 ID 与中继检查

2026-10-17，`codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。同一 `.6` 原生 GUI/core 通过实际 hbbs/hbbr 的 ID 直连、错误服务器公钥拒绝与强制中继。没有修改产品源码、重编、安装、切换服务或操作用户桌面。

## 通过的运行

`runtime/20261017T071937Z/result.json`：最终退出码 0。GUI/core 哈希逐项匹配 `.6` bundle；直接连接 157,664 个远端色块像素，中继连接 157,680 个。两名 Viewer worker 均回收，同一 Host 保留。拒绝用例未提交密码、无远端帧和入站连接。正确设置恢复后中继成功，设备历史和配置保留。

`relay/transport-sockets.json` 记录 Viewer/Host 分别连接 hbbr 21117，hbbr 两个相反端点逐项对应；`hbbr.log` 记录同 UUID 配对、raw 转发与关闭。直连的两端端点互相对应，hbbr 连接列表为空。截图为私有 Xvfb 的合成色块，不是用户桌面。

`network-capabilities.txt` 记录应用启动前 orchestrator 的五组 capability，NET_ADMIN 均已移除。容器使用 `--network none`，仅初始化自身 `lo` 的 `198.18.0.1/32`；无宿主网络或设备映射。Host/Viewer/server 分别为私有 UID 2101/2102/2103。

## 保留的前序失败

| 运行 | 原因与处理 |
| --- | --- |
| `20261017T070815Z` | 全局 21118 检测误计 hbbs WebSocket，改为检测 Host 自有监听 socket |
| `20261017T070929Z` | 默认容器 root 无法跨 UID 读取 proc FD，改为相同 UID 的只读 helper；未添加 SYS_PTRACE |
| `20261017T071047Z` | 错误公钥在约 47 ms 内被拒绝，漏观测短命 Viewer；改用实际终态日志、hbbs 拒绝和无子进程证明 |
| `20261017T071211Z` | hbbr loopback TCP 管理入口关闭中继握手 |
| `20261017T071528Z` | 同一失败；新增保留私有 HOME 的核心日志后定位握手关闭 |
| `20261017T071821Z` | 两个相同 UUID 在相同时间均成为新请求，未配对；私有 hbbr 限定一个 Tokio worker 后通过 |

上述运行完整文件按时间归档；整体 runner 输出在 `logs/`。最后一项是测试使用的服务器并发边界，不是 GUI/core 修复，也没有调整正在运行的 hermes hbbr。正式网络/NAT、服务器并发与跨平台仍需独立验收。

## 文件与范围

- `canonical/`：本轮测试、固定服务器文件哈希、准备和运行脚本、文档快照。
- `runtime/`：七次运行的原始日志、截图与 JSON，包含失败。
- `host-state.json`：当前版本、两个服务的 PID/状态、FFmpeg 静态库与原检查点相同。
- `deliverables.json`：现有 `.6` tar/Deb/源码包大小与 SHA，未生成或重写新候选。
- `final-check.json`：二进制、路由端点、源码语法、文档链接和未验收范围。
- `SHA256SUMS`：归档逐文件哈希，生成后全部复核。

测试复现与服务器官方源码依据见 [ID/中继合同](../../../Linux/docs/id-server-connections.md)。`.6` 源码归档保持冻结，本轮新增测试源码位于仓库，不声称已写入旧归档。

这关闭实际 ID/relay 连接检查，未关闭真实 desktop/GPU、1440p、长稳、首页 60 MiB、正式发布许可审计或公共 CI；未执行宿主维护切换。现有 RustDesk/FarPane 以及两个线上 hbbs/hbbr 容器保持运行。
