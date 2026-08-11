# H6.3f2b2t3 Host Home receive-root opt-in lifecycle

## Outcome

Host Home 现在提供默认关闭的“文件接收”开关和接收位置动作。用户显式选择一个安全父目录后，FarPane 只创建或复用固定的 `FarPane Receive` 子目录，并要求它属于当前 euid、权限精确为 `0700`；取消、unsafe parent、symlink 或不安全既有 child 都不会写偏好或发布开启策略。

成功选择后，canonical receive root 先持久化，再写入 enabled 标志并重新发布 bootstrap。关闭时顺序相反：先关闭 enabled，再删除 root。策略只能在 Host 关闭、控制状态 coherent 且没有 Viewer 启动中的情况下修改。Home 只显示文件夹 basename，不显示完整路径。

后台 HostAgent 与 legacy 前台 Host 都使用 `currentHostFileTransferPolicy()`：前者经 schema v5 immutable bootstrap，后者直接构造 Host ABI v17 配置；缺失、partial 或非 canonical 偏好一律解析为 `.disabled`。Host Core 启动时仍会重新执行 authoritative descriptor-relative ancestor/root admission。

## Key evidence

- picker 为 directory-only、single-selection、alias-closed；不会枚举用户目录内容。
- provisioner 只用 `open/openat/mkdirat` 访问固定 child，parent 必须由当前用户所有且不可 group/world writable，child 必须为当前用户的精确 `0700` 真实目录。
- Home 开关 on 必须完成选择才生效；cancel/reject 保持旧策略。off 会清除 receive-root 偏好，避免静默复用旧目录。
- 同一 Host-off gate 保护文件策略和 clipboard 策略；正在运行或 ownership 不一致时 UI 与 App handler 双重拒绝。
- 31 份历史 H6.3 审计的 default-off 判据已更新为真实偏好缺失回落 `.disabled`，不再把“没有产品 opt-in”当作当前事实。

## Verification

- RED：focused tests 先分别因缺少 canonical policy factory、private-root provisioner、file policy gate 和 Home/legacy markers 失败。
- private receive-root provisioner：2/2。
- file policy gate、Home/双 owner contract、canonical policy factory：各 1/1。
- 完整 fresh Swift：984/984 通过，4 skipped，0 failures。
- 完整 fresh ScriptTests：172/172 通过。
- `swift build -c release --arch arm64` 通过；`git diff --check` 通过。

未启动 GUI、未写用户目录；filesystem regression 只使用 UUID 临时目录。未安装 App/Agent，双机文件传输未验证。

## Next step

`host-file-transfer-product-development-completion-audit`：按 H6.3 的 permission、Host send/receive、Viewer action、safe root、overwrite/resume、terminal/progress 与产品 opt-in 逐项核对剩余开发缺口，再决定是否只剩单机 smoke 和双机现场验收。
