# FarPane Linux GPU 媒体重构（linux-host）：音源迁移与文件基础层

2026-10-16，`codex/linux-host-gpu-media`，基线 `b01c40b`。完整 GUI 开发目标仍在进行，本检查点不是安装包交付。原 RustDesk、已安装 FarPane、宿主桌面/音频、FFmpeg 静态库均未改动。

## 音源迁移

旧 `audio-input` 存在非空描述、但没有原生稳定 ID/选择标记时，快照标记 `audio_needs_selection`，采集入口拒绝启动。GUI 显示“请选择共享音源”，在明确选择前不允许直接切换共享开关。用户选择会经原配置事务记录 `farpane-audio-choice`，保留旧描述用于后续回退处理；不猜测描述对应哪个设备。

- core Release 构建通过（3m25s）；GUI 3 项测试和 Release 构建通过。离线配置 22 项检查通过，包括旧描述触发待选择、选择后清除待选择、关闭音频覆盖继承 full 模式但不修改其他权限。
- `runs/20261016T150045Z` 首轮真实 GUI 测试在“旧音源未选择”的断言失败，日志和报告保留。随后用明确占位选项代替空选择，并补上选择变化后 Apply 按钮即时更新。
- `runs/20261016T150356Z` 真实 GTK 待选择状态、麦克风取消/同意、切回 monitor 清除麦克风同意、音频开关落盘全部通过。旧配置是测试容器的合成配置。
- 同一轮两次实际 TCP/Opus/Pulse 播放再次通过；测试默认 source 故意设为合成麦克风，显式选择 monitor。440 Hz 测试音实际输出，关闭/真实 Host GUI 撤权后静音、重开恢复，私有 Pulse 服务终止后视频仍可刷新。细节见各 `audio-result.json` / `audio-observations.json` / `revoke-ui.json` / `viewer.json`。

本轮在建立媒体连接**之前**完成 GUI 音源选择；已有连接请求采集时的迁移阻断尚未实测。真实硬件、PipeWire-Pulse、设备拔插/默认设备变化、回退迁移、音画同步、音频服务恢复和长稳仍待验收。本轮没有新增 GPU 改动或重复 GPU 探针，之前的 GPU 检查点继续保留。

## 文件存储与任务 owner

canonical 新 crate 在 `Linux/native/files/`，仅依赖固定 libc；生成源码和 target 位于 Build。它**尚未接入 RustDesk 网络、Host 配置或 GTK 文件页面**。

- private Root + Linux openat2 描述符相对寻址，拒绝路径越界、符号链接、非普通文件及不受支持的硬链接；显式本地上传 Source 仅提供读取能力，允许普通 0755 目录。
- 128 KiB 分块、128 项/16 KiB 目录页及接收批次，深度有界的流式遍历。接收写临时文件，足量后 fsync/rename；取消保留旧文件，已完成批次前缀保留，不能宣称目录整体原子。
- 每个 Owner 最多八个任务和一个目录游标，独立代际/局部任务键、一次性本地确认/显式覆盖、取消/撤权、60 秒确认和 120 秒空闲期限。`expire` 必须由未来事件循环驱动；当前不是系统定时任务。
- 18 项真实临时文件系统测试通过，包括未确认无文件创建、取消/撤权清理、旧任务/游标拒绝、任务上限/超时、1000 项分页/递归、源文件变化、权限变化阻止已打开句柄继续操作。见 `logs/native-file-owner1.log`。
- 文件 I/O 调用仍需集成到专用执行线程并连接有界队列，认证、真实撤权路由、网络分页/旧客户端行为、双向传输、GUI 确认与进度都未验收。完整范围未缩减。

## 源码与复现

`prepare-native.py` 现在包含 files crate，`--check` 只读核对 GUI/protocol/files 的源码和锁；5 项 staging 测试通过，最终 42 文件校验通过。core pin/patch/overlay/lock 重建核对通过，日志见本目录。`source-state.json` 记录最终源码和两个开发二进制哈希；中间失败轮的源码状态不同，不能当作使用最终二进制。

```sh
python3 -B Scripts/linux/prepare-native.py --check
Scripts/linux/test-native-viewer.sh audio
Scripts/linux/native-container.sh -c 'cd Build/Linux/native/files && cargo test --offline --locked'
python3 -B Linux/tests/test_native_prepare.py
```

音频测试只用私有容器 loopback、两个 Xvfb、私有 Pulse null sinks，无宿主音频 socket 或 `/dev/snd`。约 33 MiB 的可再生测试音不重复归档，哈希见 `excluded-generated-files.json`。本目录其余文件由 SHA256SUMS 固定；更早音频证据未修改。
