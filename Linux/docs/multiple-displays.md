# FarPane Linux GPU 媒体重构（linux-host）：显示器选择与坐标

2026-10-17。原生 Viewer 的显示器下拉框连接真实核心命令；认证后取得显示器目录，切换时使用所选屏幕的原点与尺寸映射输入，按实际帧比例保留黑边。每次切换继续使用同一 Viewer worker。

## 本轮修复

固定上游的 X11 `DisplayIter` 在获取 RandR 迭代器后立即释放 reply，而迭代器的数据仍位于该 reply 内，后续枚举发生释放后读取。`Linux/patches/0041-x11-monitor-reply-lifetime.patch` 让当前屏幕的迭代器持有 reply，切换屏幕或提前结束枚举时由 `Drop` 释放；空 reply 不再传给迭代器函数。补丁与 SHA 固定在 `Linux/dependencies.lock.json`，生成 checkout 由 canonical 补丁重建。

旧 `.7` 在普通分配器下已通过以下双屏测试，这不证明释放后读取安全。修复的依据是指针所有权与释放顺序；运行测试和分配器诊断的结果分别保留，不能把普通双屏通过写成该缺陷不存在。

随后对旧 `.7` Host 启用 glibc 释放填充与关闭 tcache：认证后、显示器目录返回前 Host 意外退出（退出码 0，GUI 仍存活）。相同诊断环境下新核心通过全部九项双屏检查。原始两次旧版失败与修复后通过均保留；没有将正常退出码写成 SIGSEGV，也没有更改生产分配器设置。

## 隔离测试

`Scripts/linux/test-native-multidisplay.sh ARTIFACT` 使用固定镜像、断网容器、私有 D-Bus/Xvfb、独立合成身份与密码。它不挂载主机桌面、GPU、物理输入、服务或真实配置。私有 Host 根窗口为 960×480：

| 显示器 | 原点 | 尺寸 | 图案 |
| --- | --- | --- | --- |
| Left | 0, 0 | 640×480 | 红色 |
| Right | 640, 80 | 320×400 | 蓝色 |

原始 GUI 通过外部 XTest 操作首页、密码对话框和显示器下拉框，不使用产品内部 smoke 操作入口。实际连接内完成 0→1→0→1；从截屏颜色提取实际显示区域，检查比例和远端像素。四次点击分别在远端落到 `(160,360)`、`(720,380)`、`(160,360)`、`(720,380)`，黑边点击不改变远端指针。最后检查 worker 回收、Host 保留与身份不变。

可选 `FARPANE_MONITOR_ALLOCATOR_CHECK=1` 仅对私有 Host 设置 glibc 释放内存填充并关闭 tcache，用于暴露悬空读取；它不是产品分配器设置，也不是性能测量。

前序失败保留：一次夹具 Python 语法错误；一次 Xvfb 在没有连接时自动重置，导致先前设定的 RandR monitors 消失。夹具修正为私有 Xvfb `-noreset`。没有修改宿主显示模式或把夹具失败称为产品缺陷。

## 范围

这里只覆盖小尺寸、静态、软件编码/解码的 X11 双屏连接。真实多显示器、负原点、HiDPI 混合缩放、热插拔、Wayland、GPU、1440p、颜色与长时间稳定性仍待维护窗口验收。坐标函数已有负原点单测，但不能将它称为物理多屏验收。

新 `.8` bundle 在正常分配器下通过全部九项；Ubuntu 24.04 与 26.04 各通过 `.7 → .8` 的六组实际 dpkg 检查和升级后两次软件视频连接。原生无 GPU、原 Flutter/GPU feature 检查通过。新 raw core SHA-256 为 `b518ffc5b37859b1ac9e0f6b0e7d4a39c8d3e6dc57c9e8bbdbf452e826b5de62`，打包副本移除 RPATH 后为 `2ae7709345c3a251dde76ea71db23506dd27e2c56e256b7aeaaf6c4dbbf7766e`。GUI 未变。

本轮构建、最终候选与原始结果见 [显示器证据](../../Evidence/LinuxHost/2026-10-17-native-multidisplay/README.md)。现有 FarPane/RustDesk 保持运行，候选未经宿主安装与正式发布验收。

完整源码快照为 `farpane-native-source-8e3f3b50ccce30332f505a3f.tar.gz`，SHA-256 `1786e3c42954ac3ff8dae7ae27e4fbf6a16d2ae6d1570213b13b352cafaf945d`，88,658 个条目、1,082 个 vendor 目录。绑定本轮新核心与原 GUI；本轮没有重复完整媒体冷构建。归档文档为打包时快照，最终归档哈希在外部记录，不反向重写旧归档。
