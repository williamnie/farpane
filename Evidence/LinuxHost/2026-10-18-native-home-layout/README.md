# FarPane Linux GPU 媒体重构（linux-host）：首页布局原始记录

2026-10-18；说明见 [首页布局检查](../../../Linux/docs/home-layout.md)。

- `run-pdcyab97/`：首次关于页断言失败，原始截图表明应用正常展示首屏，说明文字属于 Details 子页。保留 exit 1、7 张截图、实际执行源码与日志。
- `run-i1i044yv/`：修正测试后四组尺寸/缩放通过，exit 0，28 张截图和对应 GTK 几何 JSON；没有产品修改。
- 每轮 `inputs.json` 固定镜像、候选 manifest、十份测试输入及实际容器命令；`source/` 为当轮字节，不追溯覆盖首次失败。
- `validation.json` 记录 28 份几何复核、查看的截图和容器退出。两项边界单测 stdout 只保留在工具记录，没有伪造独立原始日志。
- 观察器二进制仅在 Build，哈希保留于 `test-binaries.json`，本目录不提交生成库。

冻结 bundle `farpane-native-dev-ec305482eaacd98258e28587`，manifest SHA-256 `ea282757ad9874d244c84fac80d72ea8ecf66c9c06126e42d3f29e54cb312db3`。GUI/core 与 `.3` 相同，本轮未构建、安装或切换服务。

无内存/字体优化、真实桌面、中文输入或 GPU 验收。用户已接受当前内存水平；应用特判输入方案仍暂停。测试里的设备 ID/配置来自隔离合成环境，与 linux-host 用户配置无关。
