# H2.4.5 connected-static performance contract

- 日期：2026-08-08
- 范围：真实 FarPane Host 已连接静态桌面的 1080p30 / 4K30 性能场景合同
- 网络：本步骤未连接 Hermes，未修改服务端
- 密钥：未读取、未输出、未写入

## Outcome

现有 real-session runner 新增 `static-1080p30` 与 `static-4k30`。两者沿用同一 production route-stop schema v7、精确 Host PID 系统采样和 no-replace run summary，不建立第二套媒体证据；本步骤让 run summary 增加 `performanceProfile` 与 cadence 结果并升为 additive schema v3，后续 H2.4.6 已在保留这些字段的基础上升为 v4。

静态场景默认 acceptance 仍要求至少 600 秒，且必须保持 Viewer 已连接、Host 桌面整段不操作。validator 不接受以更小画布冒充静态结果：1080p profile 精确要求 1920×1080，4K profile 精确要求 3840×2160；两者 negotiated FPS 仍需至少 30，只允许 production cadence 在 route 内自行降低实际采集频率。

## Gates

除 H2.4.4 已有的硬件编码、capture/encode/send、queue drain、writer/network/transport final sample、drop ledger、active user-idle-only assertion 与完整 runtime 门禁外，connected-static profile 额外要求：

- Host 平均 CPU 严格 `<10%`；
- route 最终 `cadence.contentState=idle`，且 dirty metadata 是 trusted；
- target/applied cadence 均为 3 FPS；
- 整段 route 平均 capture FPS `>0 && <=5`，因此不能只在断开前瞬时切到 idle；
- 至少有一次 configuration update 成功应用；
- configuration failure/cancellation 均为 0，route stop 时没有 update in flight。

## Fresh automated verification

1. runner、sampler 通过 `zsh -n`，validator 通过 `python3 -m py_compile`。
2. 1080p synthetic static fixture 以 schema-v7 production allowlist 合同得到 `status=pass`；summary 为 schema v3、`performanceProfile=connected-static`、idle/3 FPS。
3. 4K synthetic static fixture 只有精确 3840×2160 得到 `status=pass`。
4. final state 未降到 idle 且 route 平均仍为 30 FPS 时 validator exit 1，并同时保留 idle-state 与 average-FPS 两项失败。
5. Host CPU 恰为 10% 时 exit 1，证明 `<10%` 是严格上边界。
6. dirty metadata untrusted、configuration failure/cancellation 与 update still in-flight 各自 fail closed 并保留原因。
7. 既有 1080p active profile 使用 highMotion/30 FPS fixture 仍得到 `status=pass`，新增 static gate 未污染 active 合同。
8. no-Viewer runner smoke 实际采集一行新 static scenario system sample，随后因缺 production route exit 1 并原子保存 fail summary；默认 30 秒 acceptance 以 exit 2 拒绝。
9. 对已有 summary 重跑 validator exit 2，原文件字节保持不变。

所有 synthetic/smoke 产物仅位于系统临时目录，验证后移入废纸篓；它们不是 FarPane 性能数据。

## Mac mini handoff

App 与 runner 的 prefix 必须完全一致：

```zsh
PREFIX="$PWD/Evidence/HostMode/<date>/macmini-static-4k30"
FARPANE_HOST_TELEMETRY_OUTPUT="$PREFIX.route.json" \
  /Applications/FarPane.app/Contents/MacOS/RustDeskNative

# 远端 FarPane 已显示 3840×2160 Host 桌面后，不再操作该桌面：
Scripts/run-farpane-host-performance-scenario.sh \
  static-4k30 600 "$PREFIX" <HOST_PID>
```

采样结束后按 runner 提示断开 Viewer，使 production route-stop writer 发布 `*.route.json`，随后 validator 生成 `*.run.json`。

## Boundary

- synthetic fixture 只证明 schema、runner 编排与判定合同，不证明真实静态 CPU/FPS。
- 当前没有 Mac mini 600 秒 connected-static 数据，因此不声明 §15.3 静态门禁通过。
- route aggregate FPS 与 final cadence state 能拒绝“全程 30 FPS、断开前才短暂 idle”的明显假通过；它仍不是逐秒 cadence timeline。若真机证据暴露无法解释的中途振荡，再单独增加有界 timeline，而不先扩大 schema。
- 本步骤没有自动操控 Viewer、桌面输入、TCC、Hermes 或远端机器。
