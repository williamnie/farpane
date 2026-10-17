# FarPane Linux GPU 媒体重构（hermes）：RGBA 剪贴板边界

2026-10-17，后续开发检查发现并复现一个保留量遗漏：旧 GUI 将收到的 RGBA 映射交给 `GdkMemoryTexture`/`ContentProvider::for_value`，没有经过自定义字节 provider 的 256 MiB 存储登记和四路输出额度。私有 Xvfb 中，三个 7680×4320 RGBA provider 均被接受，针对既定保留限额的断言失败。该场景由旧粘贴消费者继续持有 provider 触发；不把它泛化成普通首页内存泄漏。

修复已加入 canonical 源码：Viewer 使用已有剪贴板 worker 和 Host 平台已经使用的纯 PNG 编码函数，按行转换、检查取消和三秒总期限。格式/尺寸/授权先校验，转换结束及准备 IPC 后再次检查有效性；出站交付仍受既有 policy/revision/credit 控制。PNG 输出最多 128 MiB。GUI 只接收转换后的 PNG，由现有分块 provider 处理；直接 RGBA offer 明确拒绝。没有增加依赖、线程或更改网络协议，没有降低图片尺寸或字节限额。

RGBA 输入和 PNG 输出在转换期间是两份存储，封印 IPC 也有成本；256 MiB 是当前/旧 GUI provider 正文的累计保留限额，不能当作整个 GUI、worker 或应用总内存。外部粘贴消费者解码后的像素也不属于该 provider 正文统计。

Release 核心和私有 GDK 测试已通过，原始运行目录为 `Build/Linux/native-rgba-smoke/20261017T035316Z` 和 `20261017T035826Z`。每轮包含两项核心测试和一项有实际图形环境的 GUI 测试：透明小图无损、最大像素图逐像素一致、中途取消、畸形长度拒绝、实际封印通道/GDK PNG 读取、卡住的四个输出/第五个拒绝、超时恢复、第三份 128 MiB PNG 保留拒绝及释放后恢复。第二轮使用普通消费者的 `Clipboard::read_texture_future`，验证只提供 PNG MIME 时仍可正常粘贴为图片。

7680×4320 夹具的 RGBA 为 132,710,400 字节，转换为 4,172,903 字节 PNG。两轮转换、IPC 准备和通道交付约 0.626/0.624 秒，实际三秒期限检查保持启用。PNG 解码后的全部像素一致；GUI 通过真正的剪贴板图像读取接口再次逐像素验证。夹具使用确定的颜色图案，不代表不可压缩图片、日常应用、慢网络、跨平台会话或整个应用的峰值内存。

首次修复编译遇到 `Part::new` 仅接受 `Vec` 的类型错误，已改为保留 `Bytes` 所有者的结构体构造，没有为通过编译增加正文副本；失败日志保留。上述 provider/转换测试不能替代实际远端 RGBA 网络会话。

修复已纳入[当前 `.4` 测试候选](native-test-candidate.md)。新 core/GUI Release 构建、两轮各 22 项实际剪贴板检查、Ubuntu 24.04/26.04 包内连接及限定 renderD128 GPU 回归通过。对应源码归档的 88,608 个条目逐项验证，空缓存/断网环境中的依赖图、38 项协议测试和完整 GUI Release 编译通过；没有重建已有 FFmpeg，也没有安装到 hermes。`.3` 和其证据保留原样。全部原始记录见 [RGBA 修复证据](../../Evidence/LinuxHost/2026-10-17-native-rgba-budget/README.md)。
