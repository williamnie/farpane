# FarPane Linux GPU 媒体重构（linux-host）：Viewer 布局原始记录

2026-10-19 更新（用户时区；目录及原始运行时间沿用 UTC 记录）。功能、检查范围与交付说明见 [Viewer 小窗口与缩放](../../../Linux/docs/viewer-layout.md)。

- `runs/run-c1hcptc3`：旧 `.6` 的首次探索。进程退出 0，但记录已出现 865×600，未断言窗口不变，不能作为布局通过证据。
- `runs/run-oypo2gv2`：加强逐阶段几何断言后，旧 `.6` 在失败阶段被自动撑宽至 865×600，退出 1。
- `runs/run-zhgsuhmg`、`run-47hf677w`：新 GUI 在 800×600、1020×720 的 1× 下各九项通过。
- `runs/run-1p54py87`、`run-q6b9931y`：新 GUI 在同两种逻辑尺寸的 2× 下各十项通过，额外覆盖 Tab / Shift+Tab 导航。
- `build/`：`run-iq97mg_l` 的确切 GUI/协议源码、固定构建入口、receipt 与单测/Release 日志。没有复制二进制。
- `candidate/`：新 bundle 的构建与清单记录。生成的 GUI、Debian/RPM、完整源码归档只保留在 Build。
- `canonical/`：本轮实现和测试入口；每次运行自己的输入源码另在 `runs/*/source/` 中保存。
- `layout-validation.json`：四组结果汇总与已查看截图。两项保护单测和语法检查的原始 stdout 仅在工具历史，未事后伪造日志。
- `delivery/`：`.7` Debian/RPM/完整应用源码/包装配方的命令、原始 stdout、退出码与产物哈希。
- `deb/`、`rpm/`：实际包的六/七组事务检查，以及各两次软件视频连接。不是宿主或真实 systemd/SELinux 测试。
- `source-check/`：新源码压缩包实际解出、全部清单核对和离线依赖解析。未重复全新应用编译；四项检查均通过。

全部本轮构建和容器检查已结束，保留 linux-host 当前 `.1`。真实桌面、GPU、分数缩放、跨平台中文与完整发布验收仍开放。

测试均使用独立私有 Xvfb、回环网络、软件媒体和测试身份。未改变宿主桌面、服务、GPU、ID 或密码；未测试实际 Mac 中文输入。内存与字体优化继续暂停，不将本轮布局检查归为内存优化。
