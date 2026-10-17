# FarPane Linux GPU 媒体重构（linux-host）：二进制包的依赖材料

2026-10-17。二进制打包入口现将已核对的依赖材料放入 `licenses/dependencies/`，连同 GUI、core 和媒体库一起交付。不是运行时模块，不会启动新进程；本轮只重打包，应用程序字节与此前 `.8` 相同。

`inventory/` 保留 712 个选中 Cargo 包及原生依赖的原始报告和材料，包含构建依赖，不等于最终二进制链接的运行组件数。`supplements/` 保留本地和确切上游提交的补充文本、版权声明及范围。它们继续保留 45 条原始记录、26 条完整文本位置补充及 19 条未补齐记录；没有将打包成功当成完整许可审核通过。

顶层 `manifest.json` 记录全部 2,703 个材料/说明文件的 SHA-256 与大小，绑定确切应用源码清单和 notice pin。`build.json` 记录该 manifest 的哈希。原始报告中的二进制哈希只代表被检查的构建；独立重建可以产生不同二进制，不能把旧哈希写成重建产物。源清单或 notice pin 不匹配时拒绝打包。

源码归档另带 `native-dependencies/notice-delivery/`。独立源码构建的打包入口读取这份冻结材料并校验其源归档绑定，不需要原工作区、Cargo 下载缓存或联网查许可证。Linux CI 的隔离打包容器显式只读挂载这份材料及源清单。旧源码归档没有这份材料，不用新入口宣称它已经具备这一能力。

12 项针对性测试覆盖原字节和未确认记录保留、重复输出一致、不同应用来源/pin、内容变化/新增文件/符号链接/越界拒绝，以及原缓存移除后的快照导出。独立测试入口为：

```sh
Scripts/linux/test-native-notice-delivery.sh Build/Linux/source-bundles/farpane-native-source-<identity>
```

该检查只执行源码包自带的材料导出与测试工具，断网、普通用户、无 Git/原 Cargo 缓存或宿主设备；不执行产品、安装器或重编译。实际新 bundle/Deb、独立导出检查和归档完整性范围见[交付证据](../../Evidence/LinuxHost/2026-10-17-native-notice-delivery/README.md)。

原 `.8` 包和源归档保持原字节，新候选不安装。真实桌面/Mac/硬件 GPU 与内存目标、完整依赖源码及许可审核、公开 CI 仍待完成。已确认的文本随二进制交付，不扩大此前材料对嵌套组件的适用范围。
