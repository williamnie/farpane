# H3.3h5 global active-session indicator

- 日期：2026-08-08
- 范围：活动会话菜单栏指示、窗口恢复、exact-session 断开入口
- 结论：Host 活动会话现在拥有不依赖主窗口可见性的菜单栏指示；菜单可恢复 FarPane 窗口，并通过现有会话命令门禁精确断开当前 snapshot 会话。

## Product behavior

1. 只有成功解码的 `activeSession` snapshot 能创建状态栏项；无会话、Host stop/start reset 或 snapshot 不可用都会移除，避免 stale global control。
2. 状态栏标题固定为“FarPane 正在共享屏幕”；远端名称/ID 固定标记“对方声明（未经验证）”，不参与 action authority。
3. “打开 FarPane”恢复已保留的产品窗口；它与 Dock reopen 复用同一 bring-forward 路径。
4. “断开连接”把菜单构建时的 canonical connection ID 存在 `representedObject`，不展示该 ID；执行前仍由 `performHostSessionAction` 核对当前 snapshot ID，并复用 `HostSessionCommandGate`。
5. 断开命令入队后菜单显示“正在断开…”并禁用重复操作；只有 snapshot 会话消失/切换或 typed failure 才收敛。0.5 秒轮询在 presentation 未变化时不重建菜单。

## Red-green evidence

- RED：策略测试先失败于缺少 `HostSessionIndicatorPolicy`。
- GREEN：测试覆盖 nil/空/控制字符 connection ID fail closed、untrusted identity、空名称 fallback，以及断开中 disabled presentation。
- App target 编译覆盖 snapshot → status item → represented exact ID → typed disconnect command 的完整调用链。

## Verification

- `swift test --filter HostApplicationLifecyclePolicyTests`：3 passed，0 failed。
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test --quiet`：133 passed，0 failed（含 ABI v6 core lifecycle/loader）。
- `python3 -m unittest discover -s Tests/ScriptTests`：20 passed，0 failed。
- `swift build -c release --arch arm64`：success。
- `git diff --check`：通过；secret-shaped diff scan：0 matches。

## Security and scope

- 未记录或显示 canonical connection ID；未新增日志、身份持久化、密码、公钥、服务器配置、画面、输入或剪贴板数据。
- 未修改 Host ABI/snapshot/event/media schema、Rust、wire/protobuf、Hermes、CI、根依赖或数据库。
- 未安装到 Mini、未 push；现有 `/Applications/FarPane.app` 未改动。

## Remaining acceptance

- 自动验证不能证明 macOS 菜单栏图标的真实可见性、主窗口关闭后的点击行为或真机断开收敛；待可用控制端恢复后，用新安装包完成“连接 → 关主窗口 → 菜单栏仍显示 → 打开 FarPane → 菜单断开 → 指示消失”验收。
- H3.3 的 TCC/active Aqua transition 同步、Secure Input 决策与 H3.4 多显示器矩阵仍未完成，因此 H3 阶段保持进行中。
