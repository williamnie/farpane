# H2.4.7a app-local Host runtime-state evidence

- 日期：2026-08-08
- 范围：Host-ready / no-screen-route idle 场景的脱敏产品状态证据源
- 网络：本步骤未连接 Hermes，未修改服务端
- Core 合同：未修改 Rust HostSnapshot、C ABI、wire schema 或 Hermes
- 密钥：未读取、未输出、未写入

## Outcome

新增 `HostRuntimeStateEvidenceWriter`。只有显式提供绝对 `.jsonl` 路径 `FARPANE_HOST_STATE_OUTPUT` 时启用；默认完全关闭。writer 在配置时拒绝已存在文件，随后以单次 append 写入版本化 JSON Lines。普通 Host poll 最多每秒一条，Host/route/pipeline start/stop transition 使用 forced record，不会因 1 Hz 节流消失。

App 在以下 production 生命周期边界写入：

- application launch 后的初始状态；
- 每次 0.5 秒 Host snapshot poll（writer 内部节流到 1 Hz）；
- Host start failure 与 Host stop；
- media route/pipeline 建立；
- capture start failure 清理 route/pipeline；
- media route/pipeline stop。

写入失败后 App 禁用该 writer，只输出不带路径或底层错误的稳定消息；不会为继续采集而覆盖旧 evidence。

## Schema and privacy

schema `farpane-host-runtime-state` v1 只包含：

- sequence、ISO captured time、monotonic nanoseconds；
- `hostRuntimeActive`；
- allowlisted `hostState` 与 `registrationStatus`；
- Rust snapshot 的 observed timestamp（可空）；
- `mediaRouteActive` 与 `mediaPipelineActive`。

不包含 local/host instance ID、peer/connection ID、server/relay、密码/key/credential、错误详情、输出路径、媒体 payload 或画面。未知 host/registration 状态拒绝写入，不把底层字符串原样持久化。

## Fresh automated verification

1. `HostRuntimeStateEvidenceTests` 4/4：
   - schema/keys 精确 allowlist 与敏感字段排除；
   - 1 Hz periodic throttle；
   - forced false→true→false route transitions 全部留存；
   - default-off、相对路径、错误扩展名、已存在文件、未知状态 fail closed。
2. 全量 `swift test`：104 项执行、4 项按条件跳过、0 failure；包含 H.264/HEVC、CoreBridge、pipeline 与既有 H2 telemetry 回归。
3. `swift build -c release --product RustDeskNative` 成功，production App 接线通过 release 编译与链接。
4. writer 测试只在 UUID 临时目录创建产物并清理，不写入仓库。

## Boundary

- 本步骤提供了“产品 Host 正在运行且 ready、没有 screen media route/pipeline”的权威 App 状态源，但尚未提供 600 秒 idle runner/validator；后者是 H2.4.7b。
- Rust `AUTHED_CONNS` 是“所有认证连接数量”的权威源，但当前 HostSnapshot v1 未导出 aggregate count。把计数加入 HostSnapshot 会修改共享 Core ABI/schema；本 bounded step 遵守 babysit 边界没有擅自实施。
- 因此当前 JSONL 可以证明无屏幕采集，不能单独证明 file/port-forward 等非屏幕认证连接也为零；在共享合同明确扩展前，不把 H2 §15.2“无人连接”写成全部完成。
- 尚未在 Mac mini 产品 App 上保存真实 JSONL，不把单元测试或 App 编译冒充 idle 性能数据。

## Next step

H2.4.7b 将把 JSONL、system sampler schema v3 与严格 600 秒窗口绑定，门禁 ready 全覆盖、route/pipeline 全为 false、snapshot freshness、Host CPU `<2%`、零 sleep assertion、videotoolboxd/VTEncoderXPC idle 与无 route telemetry。结果名称保持 `host-ready-no-screen-route`，避免在缺少 `AUTHED_CONNS` count 时声称所有连接为零。
