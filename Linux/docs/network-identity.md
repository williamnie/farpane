# FarPane Linux GPU 媒体重构（linux-host）：网络身份修复

用户首次连接发现 FarPane 的 ID 与 RustDesk 相同。之前仅验证了配置目录、IPC、D-Bus 和安装路径隔离；
这些检查不能证明服务器上的身份隔离。上游桌面端从网卡 MAC 低位生成 ID，注册 UUID 又来自同一 machine-id，
因此同机共存时即使没有复制任何配置，仍会得到相同网络身份。

## 修复行为

- `Linux/src/app.rs` 在配置/日志/网络正常初始化前设置 FarPane 名称，并检查自己的身份版本标记。
  没有 v1 标记时，用已有随机 ID 生成接口设置新 ID、清除注册确认状态、保存标记。
  使用上游冲突恢复已有的 1000000000–1999999999 范围；重启后保留 ID。
- 迁移仅改 FarPane 自己的本地 ID，没有向 ID 服务器发送 `old_id` 重命名请求，避免更名原 RustDesk 的注册记录。
- 注册用 UUID 为原机器 UUID 加固定 FarPane 命名空间后的 SHA-256 摘要，取前 128 位十六进制 ASCII。
  同机 root/user 进程保持一致，同时与未加命名空间的 RustDesk 身份分离。
- `hbb_common::get_uuid()` 和本地密码/ID 加密逻辑保持原实现。新增客户端网络 UUID 入口，限定 Linux + farpane-linux 才变换。
- GPU 选项和服务器选项保留；路径诊断 `--farpane-paths` 仍在身份初始化之前返回，不写配置。
  `--farpane-identity` 执行本地身份初始化并打印诊断，不启动网络、服务或 GUI；不输出密码和密钥。

## 必要改动面

`0014-farpane-network-identity.patch` 只增加身份入口和替换相关 UUID 来源：

- `common.rs`：网络 UUID 入口及联网使用的设备 HWID。
- `rendezvous_mediator.rs`：注册公钥的 UUID。
- `ui_interface.rs`：界面/API UUID、部署注册及显式改 ID；后者原来直接调用 machine_uid，必须一并处理。
- `core_main.rs`：CLI 设备分配请求。
- `hbbs_http/sync.rs`、`server/connection.rs`：设备同步、心跳和连接审计，保持 API 与实际注册身份一致。

没有改 shared trait/函数签名、FFmpeg、GPU 媒体循环或本地密码加密。
没有改 hbb_common 源码；FarPane 特性关闭和其他平台返回原 UUID，原桌面改 ID 分支保留。

## 验证入口

`Scripts/linux/test-identity.sh <artifact>` 在无网络、显示、GPU、宿主配置挂载的临时容器中运行实际程序：
检查新配置的 ID 持久化；注入报告中的冲突 ID 后迁移；重启 ID 稳定；GPU/服务器选项保留；不生成 RustDesk 配置。
另有 namespace_uuid 单元测试，验证同机身份不同、重复调用稳定和不同机器不同。

首次修复前仅停止 FarPane 的服务及精确匹配系统安装路径的 GUI，未控制任何 RustDesk 进程。
FarPane 的 root/user 配置分别备份在各自私有配置目录的 `identity-backup-20261016T060208Z/`。
实际安装产物、注册和重启检查结果以同日 network-identity-fix Evidence 为准。
旧产物仅归档；在线回退到 CPU 路径应关闭修复版的 GPU 开关，不重新启动缺少网络身份修复的旧版本。
