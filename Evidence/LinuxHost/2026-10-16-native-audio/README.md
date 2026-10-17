# FarPane Linux GPU 媒体重构（linux-host）：原生音频与撤权检查点

2026-10-16。这是隔离音频链路和真实 GUI 操作的检查点，尚非完整原生应用交付或真实桌面音频验收。测试代码、补丁、镜像定义在 `Linux/`，生成文件在 `Build/Linux/`；现有 RustDesk、已安装 FarPane、宿主音频/显示、FFmpeg 库均未改动。

## 实现

- `Linux/native/audio.rs` 使用已有 libpulse 依赖的异步 context/stream，禁用 autospawn；操作在音频线程中执行，连接/创建流有 2 秒等待上限，目录查询有 1 秒等待上限。源目录最多 64 项、ID/名称累计 12 KiB，按 `monitor_of_sink` 区分系统声音与其他输入，不按名称猜测麦克风。
- `Linux/src/native_audio_capture.rs` 直接接 native Host 音频服务，替代其对旧 CM `_pa` 采集进程的依赖。48 kHz 双声道、10 ms Opus 帧；自动选择仅匹配 monitor，指定源必须存在，非 monitor 需要显式 microphone 同意；录音流禁止被音频服务移到其他设备。
- `Linux/native/viewer_audio.rs` 在 native Viewer 中替代无界旧音频线程。压缩包最多 8 项、每项 16 KiB，排队超过 150 ms 丢弃；只接受 Opus 的 8/12/16/24/48 kHz、1/2 声道，解码缓冲按最大 120 ms 分配。关闭和权限变化清队列、改变代并断开播放流，停止时不 drain。音频错误单独报告；关闭后重开可以重试。关闭状态用条件变量等待。
- Pulse 播放请求 40 ms 总延迟、20 ms 预缓冲和最多 200 ms 缓冲；这些是请求值，**未测定端到端延迟或音画同步**。预缓冲由 0 修正为 20 ms，依据缓存中 `libpulse-binding-2.28.1/src/def.rs` / `stream.rs` 的缓冲语义：0 为手动启停模式，欠载后写入落在读指针之前会直接丢失。
- 共享页接真实设备目录、音源选择、麦克风确认和配置事务；Viewer 显示等待/播放中/不可用。新增 `SetHostAudio` 仍只允许 Agent/Config 角色，Viewer 不能更改 Host 设置。显式音频设置覆盖旧 full/view 总模式中的音频项，其他权限不变。
- `0021-native-cm-ready.patch` 修正已就绪的原生同进程 CM 仍等待旧 prelogin 判断的问题。native 使用 CM_READY 和原有同进程 socket 身份校验；管理通道错误/EOF 会通知连接结束。未放宽配置 helper 的会话控制权限；实际撤权由 GUI 发送。

## 实测结果

`20261016T142550Z` 使用两个私有 Xvfb、容器 loopback、私有 PulseAudio 和 null sinks。容器没有 `/dev/snd`，未挂载宿主音频 socket。默认 source 故意设为 `synthetic_mic`，Host 明确选择 `host_audio.monitor`。

- 真实 GTK 音源选择、麦克风确认取消/允许、切回系统音源清除同意、开关落盘全部通过。详情见 `runs/.../audio-ui/audio-ui.json`。
- 两次实际 Host→Opus→网络→Viewer→Pulse 输出，440 Hz 测试音输出 RMS 约 0.141、过零频率估计 439–442 Hz。实际采样来自 `viewer_audio.monitor`，不是只检查按钮或日志。
- 首次未开启、关闭后、真实授权页音频“撤销”后的采样 RMS 均为 0。重新开启后恢复测试音。撤权同时验证 GUI 按钮、后端权限确认、Viewer 事件和输出端静音。
- 第二次会话终止**测试自身创建的** PulseAudio；Viewer 报音频不可用，刷新后视频帧数由 1 增至 2。两个 Viewer 都正常回收，同一 Host 保留，身份/认证/网络/共享配置保持测试初值，只有成功连接历史更新 revision。
- 协议 21 项、GUI 3 项测试通过；真实离线配置 21 项检查通过，包括音源输入验证、持久化和继承 full 模式后单独关闭音频。core/GUI release、canonical/source/lock 校验通过。
- `20261016T142721Z` 私有 headless Wayland 的两次实际 GPU 会话回归通过，VAAPI→DMA-BUF→GTK、完成归还和退出回收正常；仅 renderD128、256×128 静态内容、虚拟输出 12 Hz。85 次采样确认已安装 FarPane 视频连接始终为 0。

## 保留的失败证据

- `140705Z` / `140747Z`：私有 Pulse 配置路径和测试使用的 pactl JSON 字段不匹配，未进入音频验收。
- `140804Z`：GUI 按需构建页面，测试未先选择共享页，测试超时；驱动修正。
- `140926Z`：虚拟 monitor 启动时采样等待不足；驱动修正。
- `141028Z` / `141131Z`：实际播放静音，后者确认源音频 RMS 0.141、路由正确，定位并修正 `prebuf=0`。
- `141719Z`：音频播放/关闭/重开已走通，但入站列表为空，定位并修正 CM prelogin 等待。
- `142329Z`：入站列表已正确；测试错误地用 Config CLI 发撤权，被角色边界拒绝。改为独立私有 D-Bus 会话里的真实授权页按钮，没有扩大 Config 权限。
- 构建中漏导入 Context/Condvar 的检查失败日志也保留；最终构建已通过。

## 剩余

实际 PulseAudio/PipeWire-Pulse 桌面、硬件麦克风、设备拔插/默认设备变化、旧命名音源升级迁移、音频服务恢复后的重试、网络抖动、音画同步/延迟、长稳和组合内存预算仍未验收。新源配置尚未消费旧 `audio-input` 的描述字符串；升级发布前必须明确迁移或要求重新选择，不能默认为已有迁移保障。

入站音频撤权已实际验证，审批/拒绝、其他权限矩阵、CM 通道故障注入及 root/login 监管仍待补齐。文件传输、富剪贴板、凭据、桌面集成、跨发行版与完整打包仍属于原完整交付目标，不因本检查点缩减。

复现：`Scripts/linux/test-native-viewer.sh audio`；该入口使用 lock 中固定的 test-only 镜像，不安装宿主包。`source-state.json` 记录最终源码及二进制哈希，`SHA256SUMS` 覆盖本目录；中间失败运行对应的差异应结合日志和本说明解释，不宣称其都使用最终源码。
