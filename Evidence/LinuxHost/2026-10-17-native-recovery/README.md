# FarPane Linux GPU 媒体重构（linux-host）：系统事件与后台注册恢复

分支 `codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。本阶段已完成，完整 GUI 目标仍进行中。没有安装、提交、推送或发布。

## 最终检查与产物

- Release core/GUI：离线、locked 构建及 pin/patch/overlay/source receipt 核对通过；62 个 staging 文件与 canonical 一致。
- 单测：恢复 3 项、协议 38 项、GUI 6 项通过；1 项原有图形单测需隔离图形环境，未在该普通测试命令中执行。recovery 新帧报告之后通过实际 GTK 运行验证。
- Feature 检查：`--no-default-features --features farpane-native --lib` 与保留默认 features 的 `--features flutter,hwcodec,drm,farpane-linux,linux-gpu-media --lib` 均通过。
- `20261017T013412Z`：12 项实际 Host/GUI/Viewer/UDP 与私有 D-Bus 检查通过。保存当前/旧 owner、无响应/拒绝、有限预算、Host 开关、实际新帧、回收和配置保留结果。
- 同一开发包：Ubuntu 26.04 `20261017T013714Z` 与 Ubuntu 24.04 `20261017T013752Z` 各通过 8 组库/包检查及两次真实软件视频连接；错误密码重试、同 Host 保留与退出回收通过。
- 宿主只读前后核对：安装版本、FarPane/RustDesk 服务状态及 PID、分支/HEAD 相同；四个 FFmpeg 静态库大小/mtime/SHA256 相同。只剩原有四个容器。

开发包：`Build/Linux/artifacts/farpane-native-dev-9499d664fb2ccb3e841cb98f`，280 项，tar.gz 23,707,436 bytes。

SHA-256：`4861d256630f23dd863a5921d72cc7e4ae252794fa71c3269f54dd849bff47fd`。

`runtime_ready=false`，不是已验收 Release。正式 deb/RPM、完整第三方许可证/对应源码、跨桌面/性能/完整功能验收仍未完成。文档在包验证后更新以记录结果，编译代码和二进制没有变化。以前的产物保留。

## 证据读取

`recovery-runs/` 包含两次失败和最后通过的实际运行；`logs/` 保存单测、feature、构建、打包、receipt、原始失败实现和前后宿主状态；`package-runs/` 为最终包的两个发行环境。`source-state.json` 保存 canonical 哈希与实际路径；`SHA256SUMS` 覆盖本归档。截图保留于对应原始 Build 运行目录；实际检查了拒绝状态的 `rejected/page-0.png` 与等待网络首页。

## 复现入口

```sh
python3 -B Scripts/linux/verify-sources.py --reference /home/user/services/rustdesk-host-perf-20261015
python3 -B Scripts/linux/prepare-native.py --check
Scripts/linux/build-native-app.sh /home/user/services/rustdesk-host-perf-20261015
Scripts/linux/test-native-viewer.sh recovery
python3 -B Scripts/linux/package-native.py
Scripts/linux/test-native-package.sh Build/Linux/artifacts/farpane-native-dev-9499d664fb2ccb3e841cb98f
Scripts/linux/test-native-package.sh Build/Linux/artifacts/farpane-native-dev-9499d664fb2ccb3e841cb98f ubuntu-24.04
```

该入口仅适用于既有隔离缓存；不是宿主安装/服务切换命令。不要因本归档重复已完成构建或 FFmpeg 构建。

## 实现、回归范围与限制

本轮只实现 Host 注册恢复与 GUI 状态，不将受控 D-Bus 信号等同于机器真正休眠、驱动重建、真实网络切换或 Viewer 自动重新连接。

实现及回归范围：
- 新增 `Linux/native/recovery.rs`：只读 logind/NetworkManager 监听，当前 unique owner 校验、有界事件队列、配置/Host 开关复核、三次快速恢复预算。
- `Linux/native/mod.rs` 仅在普通用户 `--server` 启动监听线程；root/config/Viewer 不启动。线程不可用保留核心重试。
- `Linux/native/config.rs` 将恢复状态接入已有快照，并在同一个配置事务锁内复核 revision/Host 开关后请求重新注册；等待/休眠/恢复失败不误报注册在线。没有新增配置写入、采集或服务重启。
- `Linux/native/protocol/src/lib.rs` 增加默认可用的只读恢复状态；`Linux/gui/src/host.rs` 首页展示等待网络、休眠、恢复中和等待服务器。
- 共享 `src/rendezvous_mediator.rs` 只有 patch 0039 的 8 行原生 cfg 钩子：UDP/TCP 连接前捕获代、回执确认。feature off 仍执行旧路径，不改变共用结构/函数签名和无关调用者。
- `Linux/gui/src/desktop_smoke.rs` 和 `viewer.rs` 只扩展既有隔离测试入口（recovery 模式延长会话并在帧数变化时刷新报告）；普通 Viewer 路径没有新增自动重连行为。
- 既有测试脚本增加 recovery 分支；新 `Linux/tests/native_recovery_smoke.py` 驱动私有总线提供者、实际 UDP/protobuf、Host/GUI/Viewer 和私有 Xvfb。事件记录有界，注册记录不保存 ID/公钥。
- pin/overlay 哈希、文档同步。未增加依赖、变更上游 pin 或重建 FFmpeg。

实际失败保留：第一次运行 `20261017T011838Z` 在明确拒绝注册后失败，日志为 `Rejected registration was reported as ready`。原核心会在拒绝回包时也更新线上延迟；修正使本模块发起的恢复只有收到当前代的成功回执才可完成。该轮此前已走过真实视频、唤醒/网络重新注册与无响应耗尽；整体仍记失败。初次普通注册与取消恢复后的核心语义未全面重写，范围见合同。

验证限制：UDP 实际报文路径已纳入测试；TCP 钩子仅编译与源码验证。真实 logind/NetworkManager、suspend/resume、GNOME/KDE、网络切换、驱动/合成器恢复、跨机连接、GPU 及长期内存未在本轮验收。没有替换宿主安装、停止服务、访问用户密码库或操作显示/网络/电源。

第二次运行 `20261017T012808Z` 的新帧检查也保留为失败。检查依赖 `viewer-progress.json`，但原报告仅在控制事件数量变化时更新，无法用它持续判断视频是否停住。改为仅在 recovery 隔离模式将帧数纳入报告变化依据，正式 Viewer 逻辑不变；后续实际重跑才决定视频检查结果。

最终 `20261017T013412Z` 完整 12 项检查通过：恢复后的新帧已记录，Viewer 正常回收，拒绝时实际首页截图为“等待服务器”。不再使用过期进度值作为新帧依据。打包第一次误用了缺少 patchelf 的 GUI builder，日志保留；随后按文档使用已有宿主 patchelf 的生成脚本，只写 Build 副本，没有安装任何宿主依赖。
