# FarPane Linux GPU 媒体重构（hermes）：目录与多文件检查点

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40b`。完整 GUI 开发仍在进行，此处是文件功能检查点，不是完整应用或用户测试包。没有安装、部署、提交、push，原 RustDesk 与现有 FarPane 保持原状。没有操作宿主桌面、音频、GPU、显示或系统包，也没有重建 FFmpeg。

## 实现

- `outgoing::Plan`、canonical `0024/0025` patches 和 native 文件适配器接通多选文件上传、分批目录上传/下载。GUI 增加发送文件夹与接收文件夹，保留分页、单文件、进度和取消入口。
- 一次目录传输只有一个任务和一次批准。每批至多 128 项/16 KiB，扫描不收集整棵树，最多 64 层目录游标和一个预读条目；一次仅打开当前文件并读写 128 KiB 块。
- 子目录下载仍持有 Host 原私有共享根的权限，绝不重新打开为权限较宽的本地选择源。所有名称经过描述符相对寻址和分量校验；符号链接/特殊对象不跟随，跳过计数以明确终态显示。
- 上传/下载分批能力分别协商。路径、页码、逐项索引和确认状态必须吻合；每批保存后才回 Done ACK，发送端等待确认再继续。普通旧式单文件下载在 Host 仍只报告“已发送”。详细合同见 `Linux/docs/file-transfer-protocol.md`。
- 本地同名目录需显式合并/覆盖确认。逐文件 staging + 提交，不承诺整目录事务；取消保留已提交内容，删除当前未完成文件。
- 存储/源文件/任务清单失败仅结束该任务；网络队列失效、连接/权限失效仍结束整个文件 worker。GUI 在退出后更新未完成任务状态。

## 实际验证

测试仅在临时容器、loopback 与两个私有 Xvfb 中运行；故障测试使用容器内单条有界限速转发链路。源数据、账号、共享根和密码均为临时合成测试值。

- 301 个文件跨至少三批上传并下载，源端、Host 和下载结果逐项 SHA-256 相同；嵌套空目录和独立空目录保留。三项文件选择（包含空文件和跨块文件）作为一个任务成功。上传/下载都明确报告跳过符号链接。
- 目录下载的同名目标在实际 GTK 覆盖对话框允许前保持原内容；确认后完整替换对应文件。跨批次没有重复批准。
- 32 MiB 下载和上传在传输中修改源文件，任务失败且未提交不完整目标；同一个文件 worker 随后完成正常下载。实际取消另一项进行中的目录下载，无临时文件残留。
- 普通文件覆盖/拒绝与真实 GUI 入站撤权回归通过。中间的 `165837Z` 发现回归：按任务错误处理吞掉网络队列失效，任务停止但 worker 未退出，测试在 stage 16 超时。最终修复将发送通道错误标记为连接失效，重新完成撤权及源文件故障两组测试，未绕过测试或批准逻辑。
- 每轮 Host 配置、身份和进程保留，测试 worker 回收；最终轮有独立 `test-binaries.json`，与 `source-state.json` 中两个开发二进制匹配。

| 原始目录 | 测试结果 | 版本范围 |
| --- | --- | --- |
| `20261016T163733Z` | pass / stage 23 | 中间版本；不作为最终二进制结果 |
| `20261016T163843Z` | pass / stage 17 | 中间版本；不作为最终二进制结果 |
| `20261016T165145Z` | pass / stage 28 | 中间版本；不作为最终二进制结果 |
| `20261016T165734Z` | pass / stage 35 | 中间版本；不作为最终二进制结果 |
| `20261016T165806Z` | pass / stage 28 | 中间版本；不作为最终二进制结果 |
| `20261016T165837Z` | fail / stage 16 | 中间版本；不作为最终二进制结果 |
| `20261016T170445Z` | pass / stage 17 | 最终二进制，逐 run 哈希一致 |
| `20261016T170515Z` | pass / stage 35 | 最终二进制，逐 run 哈希一致 |
| `20261016T170532Z` | pass / stage 28 | 最终二进制，逐 run 哈希一致 |

`runs/` 包含原始事件、结果、Host 终态、实际截图、进程 maps/PSS 和日志。中间失败原样保留。可再生数据文件记录大小与哈希，不复制内容，也不跟随 fixture 符号链接。

存储 21 项、协议 21 项、GUI 3 项测试通过；staging 5 项检查通过，46 个 canonical 文件一致。native core/GUI Release、旧 Flutter/GPU feature 组合 check、pin/patch/overlay/lock 重建核对通过。该轮新增的存储测试实际检查私有根权限变化后已打开 reader/遍历器拒绝继续。

## 未验收

完整 Mac/旧 RustDesk 互操作、目录跨批畸形消息/磁盘故障/超时/中途撤权的所有组合、文件与媒体并发、实际桌面和长期资源目标仍待完成。新目录扩展不能当作旧客户端已有能力。

文件窗口与首页同时打开的 PSS 样本见各 run 的 `file-ui/process-sample.json`；不含 root 服务、视频或 GPU，不表示首页 60 MiB 或媒体组合预算达标。完整 GUI 的 Secret Service、富剪贴板、桌面集成、全部 HUD/诊断、跨发行版 ABI、完整包和用户验收仍未完成。`runtime_ready=false`，不安装这个未完成原型。

```sh
python3 -B Scripts/linux/prepare-native.py --check
Scripts/linux/test-native-viewer.sh files-tree
Scripts/linux/test-native-viewer.sh files-tree-fault
Scripts/linux/test-native-viewer.sh files-matrix
Scripts/linux/native-container.sh -c 'cd Build/Linux/native/files && cargo test --offline --locked'
```
