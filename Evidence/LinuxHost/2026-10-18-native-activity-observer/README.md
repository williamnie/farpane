# FarPane Linux GPU 媒体重构（linux-host）：原生活动保护证据

2026-10-18 UTC，分支 `codex/linux-host-gpu-media`，HEAD `0b7381291f84637cb5eea557a498aced16ed5dd4` 与未提交工作区。新增的是测试侧只读观察器与 GPU runner 保护，应用及安装包没有修改。具体合同和复现见[活动保护说明](../../../Linux/docs/native-activity-observer.md)。

## 实际检查

- `unit.log`：最初 6 项协议/拒绝测试。
- `unit-final.log`：补入 runner 启动前/运行中拒绝和禁止自动降级，共 9 项。
- `unit-final-lifetime.log`：最后补入持续可读管道的绝对寿命和 EOF/半个请求检查，共 11 项，通过。审查时发现只依赖 `select(timeout=0)` 仍会在管道持续可读时继续处理，已加显式寿命检查；没有产品变更。
- `private-run/`：原始 `.2` bundle 在私有容器中的真实 Host 与两次软件 Viewer 会话。`20261018T071819Z` 完成 314 次有效观察（191 idle、123 busy），观察器 FD 恒为 5。错误 UID/exe 拒绝；真实连接与媒体资源非零；释放后 idle；进程退出查询失败。启动前不存在 endpoint 和退出期间的错误原样列在结果中，均未计为 idle。
- `installed-observer.json`：linux-host 的 5 次实际 root 只读观察，Host PID 70886；其已认证连接为 1、CM 文件工作所有者为 1、媒体所有者为 2，汇总 4 不代表四条连接或四个文件任务。观察子进程 exit 0，未常驻。
- `installed-gpu-gate.log/json`：实际 GPU runner 因非空闲而退出，尚未创建测试容器或打开 GPU；没有中断现有连接。
- `installed-observer-final.json`：补充绝对寿命检查后的单次实机观察与 EOF 正常回收。

私有集成使用原始 bundle `farpane-native-dev-67f5d1594e8961809614f4e1`。core 包内 SHA-256 为 `26147ece6e48ce42ae550f0452809227bf7c54ce8a659218a97d80456c424661`，GUI 为 `9e57d7b3540b4282bcf23837d2bd05fc082f5da45a729f9d8f0e09a61984a421`；实际二进制哈希位于 `private-run/viewer/test-binaries.json`。容器 `--network none`、4 CPU/12 GiB/512 PID，只有私有 Xvfb/D-Bus，没有 GPU/输入设备/宿主桌面或服务 socket；SYS_PTRACE 仅为 root 验证这个容器内的跨 UID 进程身份。完整运行数据留在 `Build/Linux/native-activity-smoke/20261018T071819Z`。

`canonical-sha256.json` 对应最终工具源码。集成直接使用 `observe()` 路径；随后仅给 CLI watch 的绝对寿命补检查，observe/身份/协议处理没有改变。最后两项单测和单次实机 watch 覆盖这一后续改动，没有重跑未变化的视频矩阵。

## 未验收与服务状态

本轮不是 GPU 或内存基准，不能据此将 60 MiB 首页目标或中文实机问题关闭，也不覆盖其他应用/UID 的 GPU 负载。没有为测量而关闭实际入站、打开用户桌面、改变图形后端或安装新服务。

`runtime-state.json` 与前一 Debian 13 检查点一致：FarPane `.1` 当前链接、root PID 64215、active/disabled；RustDesk inactive/disabled。应用构建记录仍有效，`.2` 候选保持暂存未激活。未重建 FFmpeg、提交、推送或发布。
