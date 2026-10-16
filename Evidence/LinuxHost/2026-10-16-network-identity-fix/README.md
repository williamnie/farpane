# FarPane Linux GPU 媒体重构（hermes）：同机 ID 冲突修复

用户报告：此前给出的 FarPane ID 与原 RustDesk 相同，连接落到原 RustDesk。
根因：配置/IPC/进程名称分离不改变上游基于 MAC 的自动 ID 和 machine-id 注册 UUID。
之前交付把本地配置隔离当作独立网络身份，检查不足；此记录修正先前结论。

修复保存在 `Linux/src/app.rs`、`Linux/patches/0014-farpane-network-identity.patch` 及依赖锁。
随机新 ID 只迁移一次；网络 UUID 加应用命名空间；本地加密仍使用原机器 UUID。
未使用 `--set-id` 或远端 old_id 更名；没有读取或控制现有 RustDesk 的配置/密钥/进程。
FarPane 自己的配置在各自私有目录备份；原密钥、永久密码存储和 salt 与备份一致。

验证：

- 新增命名空间单元测试 1 项通过。
- 无 FarPane 特性的完整核心 cargo check 通过，2m08s。
- GPU Release 核心构建通过，1m39s；FFmpeg 静态库未重建。
- Flutter Release bundle 打包成功；Dart 未变化。
- 无网络/显示/GPU/宿主配置容器中的实际程序测试通过：路径诊断无副作用、新 ID 持久化、旧 ID 迁移、重启稳定、GPU/服务器设置保留。
- pinned 源码重建/补丁/overlay 字节一致性、prepare 重入通过。
- 新产物 root-owned 安装；首次在线注册确认，ID 与报告中的旧 ID 不同，root/user 身份一致、GPU 保持开启。
- 独立服务重启及最终状态见 `identity-restart-ready.json`；GUI 从新版本重新启动。

产物：`farpane-p1-a7c58f13c07d-90876510-551585f0`。
核心 SHA256：`a7c58f13c07d32f82a8dea38d6cdc1c8ad728a495c35a34cd0fb486d66fa5ba1`。
旧版本保留，但在线 CPU 对照应使用修复版关闭 GPU；旧版缺少身份修复，不应再次启动。

未自动建立远程视频连接；GPU 实际工作、画质、CPU 和端到端延迟仍待用户测试。
没有修改显示模式、Mac/xuanwu、主机 FFmpeg、现有 RustDesk；没有 commit/push。
证据不保存临时密码、密钥、完整用户配置或完整应用启动日志。
