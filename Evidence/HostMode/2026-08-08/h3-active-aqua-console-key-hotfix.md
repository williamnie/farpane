# H3.4h active Aqua on-console key hotfix

## Outcome

Mini 已开启 FarPane Accessibility 权限，但 Viewer 仍收到远端 input-disabled。安装态核验确认 `/Applications/FarPane.app` 为 build `20260808084627`、arm64、稳定开发签名且只有一个进程。只读 `CGSessionCopyCurrentDictionary` 探针随后确认 runtime 提供 `kCGSSessionOnConsoleKey=true` 与 `kCGSessionLoginDoneKey=true`，而实现读取了不存在的 `kCGSessionOnConsoleKey`，使 active Aqua gate 错误 fail-closed。

修复仅将 on-console lookup 改为 canonical `kCGSSessionOnConsoleKey`，同步 vendor projection 与 canonical patch，并增加 Swift contract 防止缺字母版本回归。Host ABI、protobuf、Hermes、TCC 数据库和权限配置均未修改。

## Verification

- canonical patch 在当前 vendor projection 上通过 `git apply --check --reverse`。
- Rust `native_host_active_aqua_session_fails_closed_on_unknown_or_unavailable_states`：1 passed，0 failed。
- `Scripts/build-rust-core.sh`：arm64 release core 构建成功。
- `RDN_CORE_LIBRARY=... swift test`：110 passed，0 failed；新增 canonical CGSession key contract 执行通过。
- 修复包内已签名 core：Host ABI/lifecycle 3 passed，Viewer ABI load 1 passed。
- `FarPane-arm64-20260808092002.zip`：arm64 executable/core、稳定 designated requirement、严格 deep codesign、ZIP integrity 与解压后复验全部通过；凭据类文件 0。

## Remaining manual gate

需要用户在同一 Mini 上替换旧 App、保留 Accessibility 授权、完整退出并重启，然后重新建立连接，验证点击、拖拽、滚动和键盘真实 CGEvent 注入。未取得这份真机证据前，不把 H3 输入验收声明为完成。
