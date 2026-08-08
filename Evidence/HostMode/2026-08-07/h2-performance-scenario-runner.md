# H2.4.4 real-session performance scenario runner

- 日期：2026-08-07
- 范围：1080p30 / 4K30 FarPane Host 真实性能场景编排与 fail-closed 判定
- 网络：本步骤未连接 Hermes，未修改服务端
- 密钥：未读取、未输出、未写入

## Production evidence contract

`Scripts/run-farpane-host-performance-scenario.sh` 要求当前 FarPane App 已使用与 output prefix 对应的绝对 `FARPANE_HOST_TELEMETRY_OUTPUT` 启动，且远端 Viewer 已显示真实 Host 画面。runner 不猜进程、不启动连接、不注入输入，只对操作者传入的精确 Host PID 运行现有系统 sampler。默认 acceptance 模式拒绝少于 600 秒的 1080p30、4k30-normal、4k30-video 场景；短时检查必须显式标记 smoke。

采样结束后，runner 等待真实 Viewer 断开触发 production route-stop writer，再由 `Scripts/validate-farpane-host-performance.py` 读取：

- 每秒 Host、WindowServer、videotoolboxd/VTEncoderXPCService 与系统指标；
- system schema v2 中按精确 Host PID/类型记录的总 assertion、`PreventUserIdleSystemSleep` 与 `PreventUserIdleDisplaySleep` 数量；
- schema v7 route telemetry 的尺寸/FPS、首帧后硬编状态、capture/encode/send、raw/encoded queue、writer-loop wall、route QoS delay/RTT、direct/relay/unknown transport counts、drop ledger 与 runtime；
- §15.3 的 1080p 平均 Host CPU `<25%`、4K 平均 Host CPU `<40%` 上边界。
- active route 全采样窗口 user-idle assertion ≥ 1、display assertion = 0，且 typed counts 不超过总数。

输出 `*.run.json` 采用同目录临时文件、`fsync` 和 hard-link no-replace 发布；pass/fail 均保留完整原因。原始 `*.route.json`、`*.system.samples.csv`、`*.system.json`、`*.system.log` 不覆盖、不删除。run summary 不包含服务器、密码、key、peer/connection ID、payload 或画面。

## Fresh automated verification

1. `zsh -n` 检查 runner 与 system sampler；Python validator 通过 `py_compile`。
2. acceptance-duration guard：1080p30 的 30 秒默认 acceptance 以 exit 2 拒绝。
3. 1 秒 synthetic smoke pass：
   - system side 真实调用 production sampler，但显式启用 smoke-only non-FarPane PID；
   - route side 使用受控、无 payload 的 schema v7 1080p30 fixture；
   - runner 等待迟到 route 文件并原子生成 `status=pass` summary。
4. 1 秒 missing-route smoke：
   - system samples 正常保存；
   - route evidence 未出现；
   - runner exit 1，但仍原子生成 `status=fail` 且 failures 明确包含 route evidence 缺失。
5. H2.1.6b–H2.1.9b 增补 smoke：完整的 periodic+final Rust encoded queue、writer-loop、route QoS network 与 transport 字段通过；`encodedQueueFinalized=false`、`writer.finalized=false`、`network.finalized=false`、`transport.finalized=false` 或 `unknownSubscribers > 0` 时 validator exit 1，并保留明确原因的 `status=fail` summary。
6. H2.1.11a 增补 smoke：typed user-idle=1/display=0 产出 schema-v2 pass summary；display=1 时 validator exit 1，并保留 display-sleep assertion violation 的 `status=fail` summary。真实 sampler smoke 产生 27 列 system CSV 与 schema-v2 metadata。

所有 smoke 产物位于临时目录并在验证后移入废纸篓，不进入仓库。

## Boundary

- synthetic fixture 只验证编排、字段合同和失败留证，不是 FarPane route，不计入性能结果。
- 当前没有 M4 Pro Mac mini 的真实 600 秒 1080p30/4K30 数据，也没有 Instruments trace；H2 性能退出门禁仍未满足。
- active-route typed assertion gate 不替代 Host-ready/断开后零 assertion 的生命周期验收；后者需要独立阶段 runner 与 Mac mini 真机执行。
- 真机运行需要用户保持目标桌面动作并在采样结束后断开 Viewer；runner 不擅自操控 GUI、连接 Hermes 或停止 FarPane。
- Intel 仍需独立实机功能与性能证据，Apple Silicon 结果不能替代。
