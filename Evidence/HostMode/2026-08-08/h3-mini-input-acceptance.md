# H3 Mini native input acceptance

## Outcome

2026-08-08，用户在 Mac mini 安装 arm64 Host build，并从 MacBook Pro 上的 FarPane Viewer 完成真机输入验收。用户确认此前列出的测试均通过，未发现异常：连接保持与回到可连接状态、点击、拖拽、滚动、键盘/输入法、修饰键清理和断线重连均可用。

这份证据只确认本轮人工操作结果，不替代自动合同测试，也不把尚未采集的多显示器、Secure Input、TCC/session transition 或正式性能 telemetry 标记为通过。

## FPS observation

用户同时观察到编码/呈现帧率通常为 9–12 fps，随后显示约 8.3 fps。当前 Host cadence policy 的目标档位为 idle 3、low-motion 12、interactive 30、high-motion 60 fps，因此静止或低活动画面中的该数值与自适应降档相容。

尚未取得“持续拖拽/滚动期间”的时间序列或 telemetry artifact，不能据此确认交互升档是否正常。若连续运动期间仍稳定在 8–12 fps，应回到 H2 performance scenario，分别检查 capture cadence、encoder throughput、queue pressure 与 renderer FPS；本次 H3.1b 不混入性能策略修改。

## Remaining manual boundaries

- 多显示器选择、坐标映射与显示器切换；
- Secure Input 开启/关闭时的策略与 UI；
- Accessibility 权限撤销/恢复、锁屏/登录窗口、off-console session transition；
- 带 telemetry 的持续运动帧率与 30 分钟稳定性验收。
