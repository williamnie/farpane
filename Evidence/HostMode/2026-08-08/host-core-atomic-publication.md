# Host Mode release core atomic publication

- 日期：2026-08-08
- 范围：`Scripts/build-rust-core.sh` 与 repository-local ScriptTest
- 结论：release Host Core 现在只在完整复制和符号校验后，通过同目录 rename 发布为新的 inode；构建/校验失败不会原地改写已公开 dylib

## Root cause

H3.4ae 的 built-core 验证曾在 `dlopen` 处被 macOS 以 `SIGKILL (Code Signature Invalid)` 终止。crash report 显示 dyld 读取公开 dylib 时命中 invalid page；稳定后同一文件通过 `codesign --verify`，复制到全新 inode 后 133 项 Swift 测试全部通过。

时间与文件证据进一步确认，旧 `build-rust-core.sh` 在测试开始的同一秒使用 `cp` 原地覆盖已有公开路径。目标 inode 保持不变，macOS kernel 仍可能持有该 vnode 的旧 linker-signature cache，因此文件内容和嵌入签名虽已更新，紧接着的进程仍可能被内核拒绝。

## Implementation

1. release build 仍使用原 pinned RustDesk source、feature、vcpkg 和编译参数；不修改 core 内容、ABI 或依赖。
2. 在最终输出目录内以 `mktemp` 创建隐藏 staging 文件，并用 `cp -p` 保留 source dylib 的 mode 与签名数据。
3. 既有 Mach-O 与全部 Viewer/Host symbol checks 改为针对 staging 文件执行；任一步失败时 `set -e` 退出，EXIT trap 只清理该精确 staging 文件，旧公开 core 不变。
4. 全部校验通过后，以同目录 `mv` 一次性替换公开路径，得到完整的新 inode；随后清空 trap target。并发 reader 要么持有旧 inode，要么打开新 inode，不会观察部分复制。

## Red-green evidence

- RED：先增加 `test_publishes_validated_core_with_same_directory_atomic_replace`；当前脚本因不存在 staging `mktemp` 合同而 1/1 失败，并打印原始 direct-copy 路径。
- GREEN：最小脚本改动后定向测试 1/1、全部 ScriptTests 21/21 通过。
- 合同测试同时要求 validation 位于 publish rename 之前，禁止恢复为 direct copy。

## Verification

- `zsh -n Scripts/build-rust-core.sh`：通过。
- 真实 `Scripts/build-rust-core.sh`：release core 构建完成，公开 inode 从 `92835712` 变为 `98177912`，隐藏 staging 残留为 0。
- source/published dylib：字节逐一一致，mode 均为 `755`；published dylib 的 embedded ad-hoc signature 通过 `codesign --verify --verbose=2`。
- 直接以公开 `Build/CoreBridge/arm64/liblibrustdesk.dylib` 运行 built-core loader：1 passed，0 failed；不再复制到临时目录规避 cache。
- 同一路径运行 `swift test --quiet`：133 passed，0 failed，包含 Viewer ABI、Host ABI v6、Host lifecycle 与硬件 H.264/HEVC tests。
- `python3 -m unittest discover -s Tests/ScriptTests`：21 passed，0 failed。
- `swift build -c release --arch arm64`：success；`git diff --check`：通过。

## Scope

- 未修改 Host ABI/schema、RustDesk patch/core 行为、Hermes、CI、根依赖、数据库、签名身份或 TCC；未安装、未 push、未部署。
- 本步保证 build output 的原子可见性与新 inode，不替代最终 App bundle 的签名、公证或安装态验收。
