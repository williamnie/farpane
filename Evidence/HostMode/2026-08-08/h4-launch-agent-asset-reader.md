# H4.2h fixed signed LaunchAgent asset reader

## Outcome

CoreBridge 的产品 registration identity gate 现在只能从调用 App 的固定 LaunchAgent resource 读取 plist，不再接受调用方注入候选 bytes 或路径。读取失败、resource 缺失或任一不安全文件系统条件都会在 bundle/signature inspection 前稳定 fail closed 为 `invalidLaunchAgent`。

## Key evidence

- 产品入口固定使用 `Bundle.main.bundleURL/Contents/Library/LaunchAgents/io.rustdesknative.viewer.host-agent.plist`；没有 environment、current-working-directory、alternate filename、URL 或 data override。
- reader 先以 `O_NOFOLLOW | O_DIRECTORY` 打开 bundle root，再用 `openat` 逐级打开 `Contents`、`Library`、`LaunchAgents`，因此 bundle root、任一中间目录或最终 plist 的 symbolic link 都不能被跟随。
- 每个目录必须是 root 或当前 effective user 所有、且 group/world 不可写；最终 asset 还必须是单硬链接 regular file、group/world 不可写、大小为 1...64 KiB。
- bytes 在同一个 file descriptor 上按已验证长度完整读取；额外 EOF probe 与读取后的 device/inode/mode/owner/link-count/size/mtime/ctime snapshot 对账拒绝读取期间的替换、增长或 metadata mutation。
- identity gate 固定先读该 asset，再执行既有 plist identity、`/Applications/FarPane.app` bundle identity 与全 bundle code-signature validation；asset 缺失时不会继续 inspect bundle/signature。
- 当前仓库和 SwiftPM test bundle 仍未创建/打包这个 plist，所以产品入口动态测试真实返回 `invalidLaunchAgent`。本步建立的是未来 signed resource 的唯一读取边界，不是 registration readiness。
- 本步没有创建或打包 LaunchAgent plist，没有冻结 `RunAtLoad`/`KeepAlive`，没有调用 `SMAppService.register/unregister`，也没有修改 App、系统注册项、Host/Media ABI、Rust、Hermes、CI、根依赖、根配置或数据库；未安装、部署或 push。

## Verification

- TDD RED：新增 reader tests 先因 `HostAgentLaunchAgentAssetReader` 不存在、产品 gate 仍要求 injected data 而按预期编译失败。
- 定向 reader + identity gate：14 tests，0 failures；覆盖固定 resource、缺失、bundle/中间目录/文件 symbolic link、hard link、过宽权限、空/超大 asset，以及真实 product entry fail-closed。
- `swift test`：316 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：成功链接 `RustDeskNative`，build complete。
- `git diff --check` 与 staged diff check 作为提交前门禁。

## Remaining boundary

LaunchAgent lifecycle policy 仍未冻结：Apple `SMAppService` 没有“保持注册但停止当前 Agent”的独立 API，而 `unregister()` 会改变注册状态；这与设计中的 crash recovery 和 `stopHostAgent` 语义存在冲突。因此实际 plist、bundle packaging 和 registration mutation 继续保持未实现，下一步应推进不依赖该决策的 H4.2 authenticated XPC 边界。
