# H6.2i2 Host clipboard bootstrap and Home opt-in

## Outcome

Host 小型文本剪贴板现在具备默认关闭、逐方向显式开启的完整产品配置链。该结论是自动化源码、单元测试、机器审计与构建证据，不替代已安装双机 pasteboard 验收。

## Key evidence

- Host Agent bootstrap schema v2 增加独立 `allowRemoteRead` / `allowRemoteWrite`，schema v1 只迁移为双向关闭。
- policy 参与 projection equality 与 `configRevision`，方向变更会重新原子发布；失败时 bootstrap 进入非 ready，Host 不能开启。
- Home 两个开关只在 Host 关闭、控制状态可交互且没有 Viewer 连接启动时可改；偏好键缺失时 `UserDefaults.bool` 返回 false。
- background Agent 与 legacy foreground Host 都把同一 policy 映射到 Host Control ABI v13。
- `Scripts/audit-host-clipboard-bootstrap-home-opt-in-contract.py` 机器审计覆盖 schema 迁移、严格 Boolean、revision、Home、路由、Agent 和 legacy owner。

## Verification

- Focused Swift bootstrap、publication、product integration 与 Home routing：
  24/24，0 failure。
- Full pinned Rust `rdn-native-core,rdn-native-host` release suite：162/162。
- `Scripts/build-rust-core.sh` fresh arm64 Core 与 required-symbol checks：通过。
- Full Swift with fresh arm64 Core：917/917，0 failure、0 skip。
- ScriptTests：124/124。
- arm64 Swift Release build：通过。
- Machine audit：
  `host-clipboard-bootstrap-home-opt-in-ready`，13/13 evidence、16/16 source lines。
- Python compile、canonical/vendor Host bridge byte compare、RustDesk 与 hbb_common
  reverse-patch checks，以及 root/nested `git diff --check`：通过。

## Remaining boundary

- 需要安装新版到两台 Mac，分别验证 read-only、write-only、双向、关闭后撤权、断线 teardown 和无回环。
- 需要采样显式开启后的 pasteboard 延迟与 idle CPU。
- 富文本、图片和文件 promise 仍未实现。

## Next step

`host-small-text-clipboard-installed-two-mac-acceptance`；设备不可用时先做 rich payload 安全边界的自动审计/实现。
