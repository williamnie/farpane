# H6.3f2b2s Viewer download picker/action lifecycle

## Outcome

live Viewer 现在在 desktop streaming 后显示一次显式“接收文件”动作。用户选择目录之前不会创建 dedicated file Core；directory-only、single-selection、alias-closed 的 picker 返回后，composition 先把目录固定为 current-euid、精确 `0700` 的 descriptor authority，再同步消费连接配置并启动 clipboard 全关、file mode 全开的独立 Core。file-ready 后才发送 recursive manifest/download。

该 action 在同一 dedicated epoch 内严格 one-shot。清单完成进入 active transfer 后按钮才切换为可取消；manifest、progress、file commit 和 terminal UI 只接受当前 transfer ID。fixture 不显示入口，desktop 非 streaming、文件连接失败或 action terminal 后入口保持关闭。

## Key evidence

- App 只长期保留 server/public-key/peer/relay 与“当前 desktop 会话确实使用或计划保存”的 Keychain device ID，不把 desktop password 放入 file action context。
- 目录选定后才读取已验证的 Keychain credential；不存在或不可读时才显示独立 `NSSecureTextField` sheet。临时 Swift String/配置引用在同步投影后立即清空，但不宣称 Swift runtime 提供可证明的底层内存抹除。
- `requestDownload` 在 idle 时先创建 destination owner，再记录 queued transfer，最后才调用 composition start；同步认证失败、queued cancel、Home/App teardown 都在 dedicated Core disconnect 前关闭 destination authority。
- 回 Home/退出先使 composition、picker 和 password completion 的 epoch/owner 失效，再取消 sheet、teardown file session/Core，之后既有 lifecycle 才断 desktop Core。
- Viewer ABI 保持 v13；Host App/Agent 仍未设置 `fileTransferEnabled` 与 receive root，所以端到端产品文件传输尚未开放。

## Verification

- RED：新增 action 回归首次编译失败，明确缺少 `requestDownload`、admission result 与 queued snapshot；实现后 focused composition tests 9/9。
- `swift test --filter ViewerFileTransfer`：50/50。
- 全量 `python3 -m unittest discover -s Tests/ScriptTests`：170/170。
- pinned RustDesk `cargo test --lib --features rdn-native-core,rdn-native-host`：230/230。
- fresh arm64 Rust Core build：通过，产物 `Build/CoreBridge/arm64/liblibrustdesk.dylib`。
- 加载该 fresh Core 的全量 `swift test`：974/974。
- 加载该 fresh Core 的 `swift build -c release --arch arm64`：通过。
- 新 action audit 状态：`viewer-download-picker-action-implemented-host-opt-in-off`；上一步 composition audit 已推进为 `viewer-product-composition-implemented-action-downstream`。
- canonical/vendor 三份 bridge byte identity、Viewer receive/digest patch reverse-apply、Rust 2021 `rustfmt --check`、Python `py_compile`、root/vendor `git diff --check`：通过。

未启动 GUI 做 Mac mini smoke：Host 产品 receive-root opt-in 尚未接入，单机启动无法覆盖新的远端 manifest/download 链，且可能干扰正在使用的 App。双机文件传输与性能仍未验证，按当前开发完成口径不阻塞后续实现。

## Next step

`host-file-transfer-host-home-receive-root-opt-in-lifecycle`：给 Host Home/Agent bootstrap 增加显式 file-transfer permission 与私有 receive root 选择/持久化/投影，使 Viewer action 能遇到真实允许的 Host；继续默认关闭并保持 schema migration fail closed。
