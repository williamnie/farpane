# FarPane Linux GPU 媒体重构（linux-host）：界面版本标识

2026-10-19（北京时间）。用户反馈连接一直未见断开，怀疑新包没有安装，要求在界面直接显示版本。已完成 GUI 增量构建、隔离布局检查和授权窗口中的安装。

Ubuntu 首页标题下方与“关于 FarPane”显示 **v0.1.0-dev.20261019.1**，侧栏底部显示 **主机核心 c403acbf**。Mac 客户端未修改。版本来自这个 GUI 实际 executable 所在不可变 release 的 `release-info.json`，读取一次；不会跟随 `/opt/farpane/current` 变化而让旧窗口显示新版本。缺少有效元数据时明确显示“构建未标识”。后台连接协议继续核对同一安装目录。

当前 release 为 `farpane-native-dev-9a76a6c2af66e3955470ea24`。它只替换 `.8` 的 GUI，core SHA-256 仍为 `c403acbf2caa5d49d531f1f8cff30ebc248605a0e852c8367d4b14f9eeb4ee01`；未重建媒体库。GUI SHA-256 为 `cef5148a1ea52255ee24c5ffa8a6b7199a7e89b619ded884232eb5d59db3c0dd`。Deb `0.1.0~dev.20261019.1` SHA-256 为 `ef4e6f23032fbe7a8e7bdb640ad56f680c469d4542edc31cce2eca15dfa72366`。

`build-native-gui-update.py` 从兼容的冻结 `.5` 构建 GUI；新增 `repackage-native-gui-layer.py` 校验实际 `.8` 与编译输入之间只有已有 GUI Rust 文件差异，协议、桥接、Cargo 和资产必须一致。组合后相对 `.8` 仅 main.rs/app.rs 变化，先前 viewer.rs 工作保留。原 GUI/core 来源记录保留，并追加本次构建记录；未放宽原许可审计。继承 `.8` 的 notice source map 未重绑、完整 source archive 未更新，仍为私有开发候选，不能作为公开 Release 已就绪的证据。

验证：GUI 单测 9 通过、1 项图形夹具测试按环境忽略；打包输入边界 3 项通过；1020×720 / 800×600 与 1× / 2× 四组隔离页面导航检查通过，完整版本和核心标签均可见且不省略。Deb 解包 payload 与封存 manifest 一致，161 项源码哈希一致。布局测试使用私有软件显示，截图中的 ID 为测试身份，不是 linux-host。

真实安装通过现有 stage/plan/activate/bind 事务完成，未使用 dpkg 写入宿主 /usr。旧 root 1474136、Host 1476403、GUI 1479920 已退出；安装后首次核对 root 1497504、Host 1497613 均运行新 release 内的上述核心字节。PID 仅为观察时刻记录，不作为持续状态。root/用户身份字段、固定密码与全部 options 保留；ID 1000000000、允许连接、已注册与固定密码已设置均经只读接口确认。RustDesk 服务状态保持原样，旧 FarPane release 保留回退。桌面入口已绑定新 release，没有自动打开用户窗口。

用户此前“没看到断开”的原因仍未确认，不能据此断言客户端连错或发生了自动重连。`.8` 实机中文测试已失败，非 ASCII 提交到达 Linux 且剪贴板/排队日志成功，不等于目标应用消费成功；见[输入安装证据](../../Evidence/LinuxHost/2026-10-19-native-input-install/README.md)。本次没有更改中文路径，仍由新 Claude 线程继续处理。

**后续打包要求：** 更新 GUI 或 core 时，必须同步更新并封存 `release-info.json` 的产品版本与实际 core SHA-256；不得把父包的版本元数据原样带入新核心。普通构建缺失该元数据会显示“构建未标识”。此轮新增组合器只接受已有 unrebound core 候选，不支持重复叠加 `gui_layer`；后续组合须显式维护来源链，不能绕过校验。

原始证据：[2026-10-19-native-visible-version](../../Evidence/LinuxHost/2026-10-19-native-visible-version/README.md)。没有 commit/push；真实用户窗口观察、中文输入验收与公开发布材料仍未关闭。
