# H4.1i HostAgent single-writer lease

## Outcome

HostAgent 专用 Rust config namespace 现在有 process-lifetime single-writer lease。固定 lock file 的 live `flock` 是唯一活跃所有权权威；磁盘 record 绑定 Agent boot ID、build ID 与 bootstrap config revision，但文件存在本身不表示 Agent 正在运行。

Lease 只接受 H4.1b 已验证 configuration 与调用方生成的 Agent boot UUID。产品入口使用 H4 固定目录；路径注入保持 module-internal 测试边界。

## Key evidence

- 固定 `.host-agent-runtime-v1.lock` 位于私有 HostAgent directory；目录精确 `0700`，文件精确 `0600`、当前 euid、regular、单硬链接。
- record schema v1 exact allowlist 仅含 `schemaVersion/agentBootID/agentBuildID/configRevision`；UUID 必须 canonical，build/revision 复用 bootstrap strict validator。
- 未知 server 字段、非 canonical UUID、boolean revision、future schema 与超限 record 全部 fail closed。
- 获取 exclusive nonblocking `flock` 后，在同一 inode truncate/write/file fsync/readback，并 directory fsync 后才返回 lease。
- live lease 存在时第二次 acquire 返回 `alreadyHeld`，不改 live record bytes。
- release 幂等；锁释放后新 boot/build/revision 可安全覆盖 stale crash record，证明 file presence 不会造成永久卡死。
- symlink、`0644` 文件与 hard link 均返回 `insecureLeaseFile`，受保护 target bytes 保持。
- record/test fixture 不含 rendezvous、server public key、password 或 token；测试只操作 UUID 临时目录。

## Verification

- TDD RED：lease/record/error 类型不存在，定向测试先编译失败。
- 定向 strict record、acquire、contention、explicit/deinit release、reacquire、symlink/mode/hardlink：6 tests，0 failures。
- `swift test`：171 tests，4 skipped，0 failures。
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`：22 tests，OK。
- `swift build -c release --arch arm64`：Build complete。
- `git diff --check`：通过。

## Remaining boundary

本步没有让 `--host-agent` 获取并持有 lease，也没有切换 Rust config root 或创建 HostCore。下一小步 H4.1j 将 H4.1h preflight、每进程唯一 boot UUID 与本 lease 组合成不可拆分的 bootstrap context；只有 context 存活时才能继续 config-root-first，任何后续初始化失败必须先有序停止 HostCore、再释放 lease。在该顺序可验证前继续 exit 69 fail closed。
