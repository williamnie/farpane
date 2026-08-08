# H2.4.7b Host-ready/no-screen-route idle performance contract

- 日期：2026-08-08
- 范围：Host ready、无 screen media route/pipeline 的严格 600 秒 idle runner 与 validator
- 网络：本步骤未连接 Hermes，未修改服务端
- Core 合同：未修改 Rust HostSnapshot、C ABI 或 wire schema
- 密钥：未读取、未输出、未写入

## Outcome

新增 `Scripts/run-farpane-host-idle-scenario.sh` 与标准库判定器 `Scripts/validate-farpane-host-idle.py`。runner 复用现有 system sampler，但使用独立、固定的 `host-ready-no-screen-route` 场景，不要求也不接受 production media route evidence。

FarPane App 必须先以一个全新的绝对 `FARPANE_HOST_STATE_OUTPUT=<source.jsonl>` 启动。runner 在系统采样前记录 source 的 byte offset 与 inode，结束后只把窗口内新增记录以 no-replace hard-link 发布为 `<prefix>.state.jsonl`；source 被替换、截断或无法读取时保留 fail evidence，不猜测状态。system CSV/metadata、bounded state JSONL 与 run summary 共用同一 prefix，所有最终产物拒绝覆盖。

system sampler 现在会在第 N 个样本之后继续等待到请求的 N 秒 wall-clock window 完整结束，避免把 t=0…N-1 的 N 个样本误写成已覆盖 N 秒。该修正适用于全部既有性能场景，不改变 CSV 字段或 schema v3。

## Gates

runner、sampler 与 validator 独立执行时长和合同检查：

- acceptance 至少 600 秒；短时 preflight 必须显式使用 smoke；
- system schema 至少 v3、scenario/mode/duration 一致、`completed=true`、exit status 0、每秒一行，metadata 的实际 wall-clock duration 覆盖请求窗口；
- Host 平均 CPU 严格 `<2%`，同时在 summary 报告 Host peak、WindowServer 与 videotoolboxd/VTEncoderXPCService 平均 CPU；
- 整个窗口 Host total/user-idle/display sleep assertion 都为 0；
- runtime-state 每行必须是精确 schema v1 allowlist，sequence 连续、monotonic time 严格递增、wall time 不倒退；
- 首尾状态覆盖 runner 窗口，任意相邻状态 gap `<=2.5s`，记录数不少于 `duration-2`；
- 每条状态都必须 `hostRuntimeActive=true`、`hostState=ready`、`registrationStatus=ready`、`mediaRouteActive=false`、`mediaPipelineActive=false`；
- snapshot observed timestamp 不得陈旧超过 3 秒，也不得相对 captured time 不合理地位于未来。

run summary 使用 `farpane-host-idle-run` schema v1，并固定写入：

- `authenticatedConnectionCoverage=screen-media-route-only`；
- `allAuthenticatedConnectionsProvenAbsent=false`。

因此 `status=pass` 只表示这个有意命名的 no-screen-route 合同通过，不表示 §15.2“所有类型无人连接”已完成。

## Fresh automated verification

1. runner/sampler 通过 `zsh -n`，validator/tests 通过 `python3 -m py_compile`。
2. 6 个标准库测试覆盖 ready/no-route pass、Host/registration/route/pipeline transition fail、CPU `<2%` 严格边界、任意 Host assertion fail、sequence/gap/stale snapshot fail、短 acceptance/incomplete sampler fail 与原子 no-replace。
3. 真实 macOS system sampler 以明确 smoke-only non-FarPane PID 运行 3 秒；runner 保存 3 条 bounded state、3 条系统样本并生成 `status=pass`，wall-clock window 为 3 秒以上。
4. runner 独立以 exit 2 拒绝 599 秒 acceptance；已有 run artifact 时也 exit 2，原字节保持不变。
5. 所有 synthetic/smoke 产物只位于系统临时目录，验证后移入废纸篓；它们不是 FarPane 或 Mac mini 性能数据。
6. `Tests/ScriptTests` 全量 13/13、Swift 全量 104 项（4 项按条件跳过）0 failure；`swift build -c release --product RustDeskNative` 成功。

## Mac mini handoff

确保 Viewer 未连接，选择尚不存在的 source 与 prefix：

```zsh
EVIDENCE_DIR="$PWD/Evidence/HostMode/<date>"
STATE_SOURCE="$EVIDENCE_DIR/macmini-idle.source.jsonl"
PREFIX="$EVIDENCE_DIR/macmini-idle"

FARPANE_HOST_STATE_OUTPUT="$STATE_SOURCE" \
  /Applications/FarPane.app/Contents/MacOS/RustDeskNative &
HOST_PID=$!

# 等 App 显示“可被连接”，且保持没有 Viewer 连接：
Scripts/run-farpane-host-idle-scenario.sh \
  600 "$PREFIX" "$HOST_PID" "$STATE_SOURCE"
```

真实结果包括 `*.state.jsonl`、`*.system.samples.csv`、`*.system.json`、`*.system.log` 与 `*.run.json`。失败同样保留这些产物，不删除重跑来隐藏结果。

## Boundary

- 当前未在 Mac mini 产品 App 上运行 600 秒，因此不声明 §15.3 idle CPU 门禁通过。
- App-local state 能权威证明没有 screen media route/pipeline；Rust `AUTHED_CONNS` 仍未通过 HostSnapshot/C ABI 导出 aggregate count，file/port-forward 等非屏幕认证连接是否为零不在本合同证明范围。
- WindowServer 与媒体服务是系统级进程，summary 如实报告其 CPU，但不把其他 App 的系统服务活动错误归因于 FarPane。
- 本步骤没有自动操控 GUI、TCC、Viewer、Hermes 或远端机器。
