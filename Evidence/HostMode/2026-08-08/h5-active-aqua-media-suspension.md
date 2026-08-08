# H5.2a active Aqua media suspension

## Outcome

运行中的 in-process Host 现在只会在当前进程属于已登录、on-console 且未锁屏的 Aqua session 时采集画面。锁屏、LoginWindow、Fast User Switching 后的 off-console session、缺失/异常 `CGSession` 状态或 Host snapshot 暂时不可用时，本地 ScreenCaptureKit/VideoToolbox pipeline 会 fail closed 停止；Rust media route 与远端订阅保留。同一 Aqua session 恢复后，App 用原 route 参数重新建立 pipeline，控制端不需要重新连接。

这一步是 H5.2 的媒体暂停/有界恢复子边界，不代表 H5.2 整体完成。后台 Agent 的顶层 `hostAvailability`、LoginWindow readiness、菜单栏在无键鼠/TCC 已拒绝时的独立 session 状态，以及锁屏/FUS 真机 transition 仍待后续。

## Key evidence

- `HostActiveAquaSessionAuthority` 直接读取 `CGSessionCopyCurrentDictionary`，使用与 pinned Rust platform gate 相同的三个 canonical key：
  - `kCGSSessionOnConsoleKey == true`；
  - `kCGSessionLoginDoneKey == true`；
  - `CGSSessionScreenIsLocked != true`，仅允许 macOS 在 unlocked session 省略 lock key。
- required key 缺失、非 CFBoolean、dictionary failure 全部视为 unavailable；判断不依赖键鼠 capability，因此 view-only、本机关闭输入、远端关闭输入与 Accessibility denied 会话也不会漏掉锁屏媒体门禁。
- App 每次 authoritative snapshot refresh 都同步媒体状态；snapshot 无 active session 或读取失败同样暂停。暂停会同步取消 encoded submission、异步停止 SCK stream，并保留 exact `HostMediaControl` route；恢复重新创建 encoder，首帧沿既有 pipeline 规则生成 IDR/parameter sets。
- Host media live log schema 升至 v3，新增 final lifecycle event `captureSuspended`。严格 analyzer 继续兼容 v1/v2，且只在 v3 接受该事件，旧 schema 不会误接受新语义。

## Verification

- TDD RED：新增 Aqua policy 测试先因缺少 `HostActiveAquaSessionPolicy` 编译失败；新增 analyzer 测试先得到 `validationStatus=fail`。
- `swift test`：136 tests，4 conditional skips，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，0 failures。
- `swift build -c release --arch arm64`：完成 arm64 production build。
- `git diff --check`：0 whitespace errors。

## Manual follow-up

在 Mini + Viewer 恢复后验证：保持远端连接并锁屏至少 5 秒，确认画面不再更新；解锁回到同一用户，确认无需重连即可恢复画面。随后读取 `~/Library/Logs/FarPane/HostMedia/` 的相邻 v3 JSONL：锁屏前文件应以 `captureSuspended` 结束，恢复后应产生新的 `routeStarted` 文件。Fast User Switching 需要单独重复同一矩阵。
