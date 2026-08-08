# H4.1g product App bootstrap reconciliation

## Outcome

FarPane 产品 App 现在会在 canonical catalog 成功加载后及每个成功保存后，对 HostAgent immutable projection 做一次 App-owned reconciliation。集成层重新从 `DeviceCatalogStore` 读取已落盘 document，不接受调用方传入的内存 catalog，因此“先保存、后发布”不再只是调用约定。

`CFBundleVersion` 是唯一 Agent build ID 来源；缺失、类型错误、空白污染或不符合 H4.1b token 合同都会使后台 Host 配置状态降级，不借用 marketing version、环境变量或猜测值。

## Key evidence

- catalog 尚无完整 server 时返回 `waitingForServer`，不创建 projection。
- 已保存 server 首次发布 revision 1；仅修改未保存的内存对象后 reconciliation 仍读取旧 canonical server，并保持 revision 1。
- 新 server 成功保存后才发布 revision 2；App 的所有 catalog save 路径都在 save 与内存更新之后 reconciliation。
- publication lock busy 时返回 `degraded`；新 Viewer catalog 保持已保存，旧 Agent projection 保持 revision 1/server 旧值，锁释放后重试收敛到 revision 2。
- App 将 bootstrap degraded 作为 Host 卡片的独立错误合并呈现，不覆盖 Viewer 的 home error，也不把当前进程内 Host 状态冒充后台 Agent ready。
- 集成层与测试只使用公开 server key 的 synthetic `.invalid` fixture；不读取、记录或写入用户密钥、密码、token、server private key。

## Verification

- TDD RED：product integration/state/error 类型不存在，定向测试先编译失败。
- 定向 canonical saved catalog/build ID/busy retry：3 tests，0 failures。
- App source ordering/degraded presentation contract：1 test，0 failures。
- `swift test`：162 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Remaining boundary

本步没有注册 `SMAppService`、启动 LaunchAgent、启用 XPC 或让 `--host-agent` 读取 projection。旧 projection 在 canonical server 暂时缺失或发布失败时不会被删除；未来 Agent 注册/启动必须以 App reconciliation `ready(revision)` 和 XPC config revision 对账为门禁，不能仅因磁盘上存在旧文件就启动。

下一小步 H4.1h：为 Agent 固定 bootstrap reader 增加启动前 product reconciliation/expected-build gate，并在任何 Rust config lazy initialization 或 HostCore create 之前完成 config-root-first 与 single-writer lease 的可测试顺序；在该门禁完成前继续保持 exit 69 fail closed。
