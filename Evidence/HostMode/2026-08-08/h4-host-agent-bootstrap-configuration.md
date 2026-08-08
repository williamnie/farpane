# H4.1b HostAgent immutable bootstrap configuration contract

## Outcome

HostAgent 现在有一个严格、版本化、不可变且不含秘密的 bootstrap configuration 合同。它只承载 canonical Rendezvous server address/public key、正整数 monotonic config revision 和 Agent build ID；Host Rust 配置命名空间由产品常量固定，不能通过配置文档或环境变量重定向。

该合同是 HostAgent 驻留前的输入门禁，不是配置存储或后台运行实现。当前 `--host-agent` 分支仍然 fail closed 退出，不读取磁盘、不切换 Rust config root、不创建 HostCore，也不声称 ready。

## Key evidence

- schema v1 顶层只允许 `schemaVersion`、`configRevision`、`agentBuildID`、`server`；server 只允许 `rendezvousServer`、`serverPublicKey`。
- 未知字段即拒绝，因此 password、token、private key 等 credential 不能悄悄进入 bootstrap 文档。
- revision 必须是 `1...2^53-1` 的严格整数；JSON boolean、零、负数、小数、非有限值和超限值均拒绝。
- build ID 只允许有界的字母数字及 `.-_+`；server/public key 非空、有界且不得包含控制字符或空白。
- 未来 schema 返回稳定的 `unsupportedSchema(version)`，不以当前规则猜读。
- 文档上限 64 KiB；超限输入在 JSON 解析前拒绝。
- Host config namespace 固定为 `FarPaneHost` / `io.rustdesknative`，不接受磁盘或环境覆盖。

## Verification

- TDD RED：测试先因生产类型不存在而编译失败；新增类型后又暴露测试断言闭包缺少显式 error 参数，修正测试夹具后进入真实合同验证。
- 定向 `HostAgentBootstrapConfigurationTests`：3 tests，0 failures。
- 完整 `swift test`：142 tests，4 conditional skips，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，0 failures。
- `swift build -c release --arch arm64`：完成 arm64 production build。
- `git diff --check`：0 whitespace errors。

## Next boundary

H4.1c 建立 bootstrap 文件读取/发布边界：固定产品路径、拒绝 symlink/非 regular file/错误 owner 或过宽权限，并定义同目录原子 replace 与 revision 单调更新。完成该边界前不接入 HostCore；单写者 lease、config-root 应用顺序和 authenticated XPC 继续作为后续独立门禁。
