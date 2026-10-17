# 原生 GUI 的 ID 直连与真实中继检查

2026-10-17。候选 `.6` 在隔离环境通过实际 hbbs/hbbr 的 ID 查询、直连、错误公钥拒绝和强制中继。测试使用原始 GUI/core 二进制，由外部 XTest 操作真实控件，没有产品 smoke 开关。本轮只新增测试及文档，没有重编应用、核心或 FFmpeg，也没有安装到 hermes。

## 已验证的路径

| 场景 | 实际结果 |
| --- | --- |
| ID 直连 | 输入新生成的 Host 数字 ID，认证后显示 157,664 个匹配远端色块的像素；Host 未开启 IP 直连端口，Viewer/Host 的 TCP 端点互相对应，hbbr 没有配对连接 |
| 错误服务器公钥 | 只改变 Viewer 的公钥；hbbs 报告 invalid key，GUI 到达 Failed，未出现密码挑战、未提交密码、未显示远端画面；无残留 Viewer/Host 入站或中继连接 |
| 强制中继 | 恢复正确公钥并设置 force_relay，认证后显示 157,680 个匹配像素；Viewer 和 Host 各有一条通往 hbbr 21117 的连接，hbbr 日志确认同 UUID 配对，其两个套接字与客户端端点匹配 |
| 退出与配置 | 主动断开后 Viewer 被回收，Host 入站列表与 hbbr 已建立连接归零；关闭 GUI 后同一个 Host 仍存活，设备历史、身份和服务器设置保留 |

运行目录：`Build/Linux/native-id-server-smoke/20261017T071937Z`。GUI SHA-256 为 `c9be8ed4976da5f5659d5834b9b2a70d4a5612d72f098574d6b19767b6c8f659`，包内核心为 `7c363f0e24fa7f71f0e6e16fb012b4a7c2942c646993025b4e3cc23dcb1c48b3`；均匹配 [`.6` 候选](two-factor-authentication.md)。原始记录、前序失败与校验和见[证据归档](../../Evidence/LinuxHost/2026-10-17-native-id-server/README.md)。

## 复现入口和隔离边界

```sh
bash Scripts/linux/test-native-id-server.sh \
  Build/Linux/artifacts/farpane-native-dev-5de72addbd45d21a01a6ea3c
```

`Linux/tests/native-id-server.lock.json` 固定已缓存的 rustdesk-server 1.1.15 镜像及 hbbs/hbbr 文件哈希。准备脚本仅从自己创建、未启动的容器导出两个已锁定文件，不拉取镜像、不读取已运行服务器。缓存放在 `Build/Linux/rendezvous-test-tools/`，不随应用安装。

运行器使用 `--network none`、4 CPU/12 GiB，没有发布端口，不挂载宿主桌面、音频、GPU、D-Bus、Docker socket、配置或身份文件。Host、GUI 和服务器使用三个不同普通 UID，以及独立 HOME/XDG、私有 D-Bus 和 Xvfb。ID、服务器密钥和测试密码均为临时生成或合成数据。

该 hbbr 的 TCP loopback 入口用于管理命令，因此容器初始化阶段只在自身网络命名空间的 `lo` 上增加 `198.18.0.1/32`，随后通过 `setpriv` 从 capability bounding/effective/permitted/inheritable/ambient 集合移除 NET_ADMIN。应用启动前断言只有 `lo`，且五组 capability 均不含该能力。没有修改宿主地址、路由或网桥。[固定版本的服务器源码](https://raw.githubusercontent.com/rustdesk/rustdesk-server/bd3e73fd5168f099969788c50d3188537f9d4792/src/relay_server.rs)解释了 loopback 分支。

同机同时到达的两条中继请求曾触发 hbbr 配对竞态：相同 UUID、相同时间出现两条 `New relay request`，没有 `got paired`。最终夹具仅对私有 hbbr 设置 `TOKIO_WORKER_THREADS=1`，避免该并发时序；服务器和产品二进制均未修改。此限制明确保留，不将本轮作为服务器并发/压力验收，也不修改 hermes 现有 hbbr 设置。

## 失败记录与范围

六次前序失败全部保留：全局 21118 端口断言误计 hbbs WebSocket；跨 UID `/proc` 访问缺权限；错误公钥快速拒绝导致短命进程漏观测；两次 loopback 管理入口导致中继握手关闭；一次上述 hbbr 配对竞态。前两项分别改为检查 Host 自有 socket、以目标相同 UID 读取 `/proc`，没有添加 SYS_PTRACE。快速拒绝改为核对新一轮终态日志、服务端拒绝记录与子进程清空。

本轮关闭的是实际 ID/中继协议路径检查。它使用 640×480 Xvfb 软件画面、单路会话和同机隔离网络，不代表公网 NAT、真实 DNS/网络切换、多连接中继、Mac 互操作、GPU、1440p 或真实桌面性能。`.6` 二进制与冻结源码归档保持原样；新增测试源码保留在 canonical `Linux/`、`Scripts/linux/`，没有伪称已包含在旧冻结归档中。真实桌面、首页 60 MiB 目标、长期稳定性及完整发布验收仍未完成。
