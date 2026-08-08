# H4.1z Agent startup media-control delivery

## Outcome

禁用的 HostAgent 产品组合现在会保留 Core event callback 安装后、process-owned media pipeline 激活前到达的 typed media control，并在 pipeline owner 完成 runtime binding 后按原顺序同步交付。这样 route authority 已经接受的 `startCapture` / `reconfigure` 不会因为 owner 尚处于 idle 而静默丢失，也不会让后续同 epoch 控制落入不可恢复的“状态已前进、媒体未启动”分叉。

## Key evidence

- `HostAgentMediaControlDeliveryGate` 是唯一 startup/active delivery authority；激活前只保留已经由 bounded event journal 解码出的 `HostMediaControl`，不复制 raw JSON、encoded frame、屏幕内容、server 或 credential。
- startup queue 固定最多 16 条；第 17 条清空全部 pending control 并进入 terminal `overflowed`，pipeline owner startup 返回 false，不能把不完整 route 当成 ready。
- `activate` 只允许一次，在 capability probe/timer 启动前同步排空 startup controls；active 阶段沿同一个 gate 串行交付，因此并发 callback 不会重排 reconfigure/IDR/stop。
- pipeline owner 不再用 `state == active` guard 静默忽略已经 accepted 的 control；gate 拒绝与 route 语义拒绝都进入同一个脱敏 saturating rejection counter。
- termination 先 terminal cancel control gate、丢弃 queued controls 并等待唯一在途 delivery，再停止 periodic log、drain route 和失效 runtime binding；cancel-before-activation 与重复 cancel 均安全。
- component snapshot 只暴露 gate lifecycle、pending/delivered/rejected counts 和 in-flight bit，不暴露 control payload 或 route identity。
- 本步只修复未来真实 `--host-agent` 入口所需的启动竞态；入口仍 exit 69，因此不宣称它解释或修复了当前 GUI 进程在 Mini 上的自退，也没有访问用户真实日志。
- 不修改 C Host/Media ABI、Rust、Hermes、XPC wire、SMAppService、CI、根依赖或数据库；未安装、部署或 push。

## Verification

- TDD RED：delivery gate 类型尚不存在时，4 个新增测试按预期编译失败；owner 尚未接线时，6 个 source-contract 断言按预期失败。
- 定向 gate tests：4 tests，0 failures。
- 定向 product composition contract：1 test，0 failures。
- `swift test`：274 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

下一小步继续 H4.1 actual-entry preflight：审计 process runner 的 terminal result、run-loop/事件源所有权和 startup failure 映射，保持入口 fail closed，先补齐可以自动验证的生命周期缺口。H4.2 SMAppService、H4.3 authenticated XPC，以及 Mini GUI 自退的真实 crash/exit 证据仍是独立边界。
