# H2.4.6 30-minute stability performance contract

- 日期：2026-08-08
- 范围：真实 FarPane Host 1080p30 / 4K30 目标产品工作流的 30 分钟稳定性合同
- 网络：本步骤未连接 Hermes，未修改服务端
- 密钥：未读取、未输出、未写入

## Outcome

`Scripts/run-farpane-host-performance-scenario.sh` 新增 `stability-1080p30` 与 `stability-4k30`。默认 acceptance 至少 1800 秒；runner 和底层 sampler 分别执行同一时长门禁，validator 还会从 system metadata 独立拒绝短 acceptance，不能绕过 runner 伪造 30 分钟结果。system sampler schema v3 无论完整结束还是 Host 中途退出都会原子保存 `completed`、`samplerExitStatus` 与实际 sample count；runner 不再因 sampler 非零退出而丢失统一 run summary。

两个 profile 继续要求精确 1920×1080 或 3840×2160、negotiated FPS 至少 30、硬件编码、完整 production route/system evidence 和对应 active CPU 上边界。run summary 在 H2.4.5 schema v3 基础上升为 additive schema v4，保存六窗口趋势与完整 drop counts，不包含 PID、peer/server、凭据、payload 或画面。

## Six-window trend contract

1800 个每秒样本按时间顺序等分为六个连续 5 分钟窗口，每个窗口取中位数。使用中位数而非单个首末样本，避免一次调度尖峰或采样抖动左右结论。system CSV 的 elapsed time 必须有限、非负且严格递增；CPU 必须有限且非负，Host RSS/thread count 必须为正。

下列条件判为持续上升：六个窗口中位数全部非递减，且末窗相对首窗增长超过 material noise floor：

- Host CPU：`max(2 percentage points, 首窗 20%)`；
- Host RSS：`max(4096 KB, 首窗 5%)`；
- Host threads：`max(2, 首窗 10%)`。

即使序列不是全程单调，末窗相对首窗若超过 `max(32768 KB, 20%)` RSS 或 `max(4 threads, 25%)`，仍作为明显泄漏趋势失败。阈值是自动化初筛合同，不替代 Instruments Allocations/Leaks；任何失败保留原始窗口数据，不通过提高阈值或缩短运行规避。

## Route convergence gates

除 H2.4.4–H2.4.5 已有门禁外，stability profile 额外要求：

- 六类 drop reason 全部 `instrumented=true`、count 为非负整数，且求和等于 classified total；unclassified 继续必须为 0；
- final Rust encoded queue depth 为 0；
- writer confirmation timeout 为 0；
- route 结束时 response-delayed subscriber 为 0；
- cadence configuration failure/cancellation 为 0，且无 update in flight；
- route 内 process telemetry 至少采样两次。

允许出现已归因的 classified drops；稳定性合同禁止的是未分类或 ledger 不完整，而不是把 production bounded-drop 行为伪装成绝对零丢帧。

## Fresh automated verification

1. 1080p 与 4K 六窗口稳定 fixtures 均得到 `status=pass`、schema v4 与完整六类零值 ledger。
2. CPU 六窗持续上升、RSS 六窗持续上升、threads 六窗持续上升分别 exit 1 并保留明确原因。
3. 非单调但首末 RSS 增长 40 MB 的 fixture 触发 excessive-growth gate，同时不会被误标为 monotonic rise。
4. 缺失 network-backpressure instrumentation、classified sum 不一致、final encoded queue 未 drain、writer timeout、response-delayed、cadence failure/cancellation/in-flight、process sample 不足均 fail closed。
5. 既有 1080p active profile 在不含 stability-only fields 时仍得到 `status=pass`，稳定性门禁没有污染旧场景。
6. validator 独立拒绝 6 秒 acceptance；runner 与 sampler 均以 exit 2 拒绝 1799 秒 acceptance。
7. 真实 system sampler 以明确 smoke-only non-FarPane PID 采集 6 行 stability samples；无 Viewer/route 时 runner exit 1，并保存六窗口 summary 与 route-missing 原因。
8. 受控短生命周期进程在采样窗口中退出时，sampler 保存 schema-v3 partial metadata，runner 跳过 route wait 并生成包含 incomplete/nonzero-exit/row-count/route-missing 的 `status=fail` summary。
9. 对已有 run summary 重跑 validator exit 2，原文件字节不变。

所有 synthetic/smoke 产物位于系统临时目录并在最终验证后移入废纸篓；它们不是 FarPane 稳定性数据。

## Mac mini handoff

```zsh
PREFIX="$PWD/Evidence/HostMode/<date>/macmini-stability-4k30"
FARPANE_HOST_TELEMETRY_OUTPUT="$PREFIX.route.json" \
  /Applications/FarPane.app/Contents/MacOS/RustDeskNative

# 远端 FarPane 已显示 3840×2160 Host 桌面后，持续重复目标产品工作流：
Scripts/run-farpane-host-performance-scenario.sh \
  stability-4k30 1800 "$PREFIX" <HOST_PID>
```

采样结束后按 runner 提示断开 Viewer，使 route-stop writer 发布 `*.route.json`；validator 随后生成 `*.run.json`。

## Boundary

- 当前没有 Mac mini 或 Intel 的真实 1800 秒数据，不声明 §15.3 稳定性门禁通过。
- synthetic 六样本 fixture 只验证“六窗口算法”与 fail-closed contract；正式 acceptance 每窗是 300 个真实样本。
- 本合同能发现系统采样窗口内的 CPU/RSS/thread 趋势与 route-stop backlog/drop 异常，但不替代 Instruments Leaks、System Trace 或实际 crash report。
- runner 不自动操控 GUI、输入、Viewer、TCC、Hermes 或远端机器。
