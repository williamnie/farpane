# FarPane Linux GPU 媒体重构（hermes）：首次激活

日期：2026-10-16 UTC。用户明确授权：“现在启动并开启 GPU”。

- 复用已安装 `farpane-p1-e9bb38076782-90876510-551585f0`，没有重编或更换产物。
- 核心 SHA256：`e9bb380767828b911c6ec5434ce5009d0991930833aba3aeb4a029284548248d`。
- 系统版本 root-owned，未发现 group/other 可写文件。
- 执行 daemon-reload、启动独立 farpane.service；未 enable。
- 服务 active/running、NRestarts=0；主进程 PID 3070914。
- 同版本用户 server PID 3070965、tray PID 3070972、GUI PID 3072023。
- GUI 使用用户 server 的显示环境启动，Flutter main 初始化完成，出现 active window changed: {0}；没有截图或操纵其他窗口。
- 主 IPC、service IPC、DRM IPC socket 均存在。
- 用已安装程序的 root CLI 设置 `linux-gpu-media=Y`；CLI 回读 Y，用户 FarPane2.toml 中同项为 Y。
- 只读主 IPC 返回 GPU `{ "backend": "idle", "enabled": true, "generation": 0, "reason": "" }`。
- 只读 OnlineStatus 返回在线且 key_confirmed=true；未输出 ID、密码或密钥。
- FarPane 没有自建 ID/中继服务器配置；没有从原 RustDesk 导入身份或配置。

启动日志有一条 GTK/GDK 诊断：`gdk_device_get_source: assertion 'GDK_IS_DEVICE (device)' failed`。
GUI 进程持续运行，Flutter main 初始化完成；未把这一检查称为人工界面或输入验收。
完整原始 GUI 日志留在 `Build/Linux/logs/farpane-first-launch.log`，此处不归档可能含本机标识的完整日志。

没有建立远程测试连接，没有采集桌面图像，没有测量运行中 GPU 媒体路径的 CPU/画质/延迟。
idle 只表示已启用并等待兼容连接。没有改显示模式、操作现有 RustDesk 服务/进程/配置/ID/密钥，
没有 commit/push，没有调用其他代理。此前 P1 集成证据和两轮旧实验目录未修改。
