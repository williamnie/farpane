# FarPane Linux GPU 媒体重构（linux-host）：中文输入缺失

日期为 UTC 2026-10-18，基础提交 `0b73812`，分支 `codex/linux-host-gpu-media`。本轮复现的是 Mac 提交汉字后 Ubuntu 终端无文字；兼容输入菜单灰色，未验证切换成功。

- `host-clipboard-errors.log`：仅摘录现有服务日志中的固定错误，不保存实际输入文本、密码或身份配置。
- `display-unit-tests-3.log`：修复后的 4 项 discovery 单测通过，私有桌面测试在普通环境中明确 ignored。
- `entry/`：私有 Mutter 50.1、Xwayland、GTK4 Wayland 输入框；缺少 DISPLAY 的初始化失败已复现，保留 managed socket 原始地址后，三次中文/混合/Latin-1 粘贴通过，累计内容精确匹配。
- `terminal/`：同一环境，GTK3 VTE 2.91 终端与独立 PTY；相同三次输入进入真实终端输入流，未重复。
- `display-mutter-test.log`：初次把私有 socket 改写为 `:1` 的超时，原样保留。`display-mutter-test-2.log` 与 `display-terminal-test.log` 为修正后成功的入口输出。
- `rejected-keysym-experiment/`：先前尝试直接使用 Mutter Unicode keysym；API 回复成功但 CJK 丢失，真实测试失败，已撤下全部未发布的生产 hook。完整实验草稿只留在 Build，不进入修复产物。
- `scope.json`：来源、环境与限制。网络输入、实际宿主键盘设备和真实 Mac→linux-host 验收尚未执行；本轮测试不改变宿主显示或输入。

完整说明见 [中文输入修复](../../../Linux/docs/chinese-input.md)。构建、打包和维护安装状态将追加记录，不覆盖旧失败。

Release 构建与前后 canonical 源码校验通过，GUI 原始字节与旧版一致，未重建 FFmpeg；详见 `release-build.log`、`build-receipt.json` 和 `build-comparison.json`。712 个包、45 条未解决的材料记录保持不变，notice pin 仅重新绑定当前来源/二进制清单，不表示完成许可审计。

修复候选为 `farpane-native-candidate_0.1.0~dev.20261018.1_amd64.deb`，18,768,716 字节，SHA-256 `9960dfb15c170d66c23677c006f9c37633f4c9ccf47cd72ab0e1809e8fc353e9`。Bundle 为 `farpane-native-dev-bfc1befc221061266d5f50da`，归档 SHA-256 `e200d513061ce62e7ed9a0dc6ef3b5979079a2f4e2a979a010d58314eeb1dcc9`。完整 manifest、Deb 解包 payload 与安装器源码逐项比较、包内 core 的 `--build-info` 均通过。未在宿主执行 dpkg，也未重复未改变的 GPU/完整连接矩阵。

安装器已完成 stage 和 plan；`display-stage.json` / `display-activation-plan.json` 证明当前仍为旧原生 release，服务 active、开机 enabled=false、两个 PID 未替换，配置未改。维护窗口确认与真实 Mac 终端中文验收仍待进行。代码尚未 commit/push。

## 后续维护与失败验收

上文“尚未激活”是当时的历史记录。用户随后批准安装，2026-10-18 10:05（北京时间）激活 `bfc1befc…` 并绑定用户入口；实际新进程及哈希、身份配置逐项不变、外部服务不变见 `maintenance/`。之后用户在 Warp、Chrome 均报告中文无文字，手动 Control+Shift+V 也未解决。此缺陷仍开放，不能把先前局部通过当作实机通过。

## 复查回归

`review/` 保留实际生产粘贴函数的 Control 残留失败、GTK4/VTE/Chrome 三个修正后结果、只读剪贴板元数据和范围。`scope.json` 明确实际 linux-host 触发条件仍未证实；没有把私有键盘替身当作 root uinput 或 Mac 网络验收。

本轮 `.2` bundle `67f5d159…` 已打包/校验、在 Ubuntu 24.04 完成私有软件连接并 stage/plan；未激活。完整源码 `e5ee1c6b…` 也已交付，全部归档条目及空缓存断网依赖解析通过。详情与完整哈希见 `review/` 的 package/deb/source-package/verification 文件；`final-runtime.json` 记录 `.1` 仍运行。
