# FarPane Linux GPU 媒体重构（hermes）：真实二次验证与 `.6` 修复候选

2026-10-17，`codex/linux-host-gpu-media`，HEAD `b01c40bd7da588f0ec2add2947a9368289006792`。

实际 `.5` 在字母验证码后隐藏输入框、无法重试；原失败 JSON/截图保留。修复后视频与文件 GUI 在格式错误时保留输入，正确验证码后分别显示实际远端像素和完成文件操作。没有改变 Host 的验证码校验、权限或重试时限。

实现、复现命令、候选与范围见[二次验证合同](../../../Linux/docs/two-factor-authentication.md)。

- 视频 `20261017T065223Z`：取消不出帧/不保存密码；错误数字重试；字母与 17 位数字可修改；正确验证码后实际呈现 157,664 个匹配远端色块像素；两个 worker 回收，Host 保留。
- 文件 `20261017T065243Z`：真实 TOTP、错误和格式重试、认证前无目录、保存连接密码而非 OTP；12 项正常文件测试包括批准、取消、上传下载 SHA 一致、退出与配置保留。
- GUI Release 编译和 9 项单测通过，1 项既有图片夹具测试按原条件跳过。核心、FFmpeg 未重编，复用核心的源码/二进制与旧 receipt 一致；更新 receipt 绑定新 GUI。
- Ubuntu 26.04/24.04 分别通过八类 bundle 检查和两次软件连接；`.5 → .6` 在两个环境通过六类 dpkg 事务检查及各两次升级包连接。不是宿主安装或真实 systemd 激活。
- `.6` Deb SHA-256 `5ab02646e1d414f1d81da5f75b23869aebdfbdea717bf12efddfb41fabda0140`；GUI `c9be8ed4…`，packaged core `7c363f0e…`。来源与原始二进制哈希完整保存在 build receipt 和结果中。
- 新源码 `b22702a3…` 归档 SHA-256 `bc161bed654b53d83207cfbd3a8000fda8ae3c9f60d570aec5b6fd92fb026433`，88,645 条目；绑定当前 GUI 修复，不声称新一次完整媒体冷构建。

早期三个夹具失败、`.5` 实际产品失败、源码生成时旧清单二进制绑定失败均留证。新审计清单 `d61fef7c…` 保持 712 个包、45 条待核对记录及全部依赖材料，仅更新二进制/构建 receipt；完整许可审计仍未完成。

全部测试在断网容器内，以私有 loopback/Xvfb/D-Bus/密码库和公开合成 TOTP 向量完成；没有 GPU、宿主桌面或凭据访问。旧 `.5`、源码快照及 FFmpeg 库保持不变。未安装、未提交、未推送、未发布，两个现有服务 PID/current 不变。

尚未验收：真实用户维护切换、2FA enrollment 界面、跨平台/真实桌面、GPU/故障长稳及原内存目标、完整发布审计。`runtime_ready=false`；本轮结果不替代 `.5` 的 GPU 或生命周期证据。

`SHA256SUMS` 索引本目录原始记录及 canonical 副本。未复制的大型图像/既有运行映射等列入 `retained-in-build.json`；原始文件继续留在 Build。最终检查范围在 `final-check.json`。
