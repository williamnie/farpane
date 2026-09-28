# 代码精简结果

基线：`4a9fa17`（2026-09-28）。以下统计可用
`python3 Scripts/measure-code.py --base 4a9fa17` 复现。

## 规模与口径

第一方 Swift、Rust、C/header、Python、shell、Metal 源码，包含运行时代码、测试、工具和 benchmark。
固定上游的补丁 diff/context、Vendor/Build、文档、图片、二进制与原始验收数据不计为代码。

| 指标 | 基线 | 重构后 | 降幅 |
| --- | ---: | ---: | ---: |
| 物理代码行 | 182,069 | 121,290 | 33.38% |
| 非空代码行 | 169,200 | 110,499 | 34.69% |
| 代码文件 | 581 | 521 | — |

| 范围 | 基线代码行 | 重构后代码行 |
| --- | ---: | ---: |
| `Benchmarks` | 170 | 170 |
| `CoreBridge` | 21,984 | 21,859 |
| `Package.swift` | 52 | 56 |
| `Scripts` | 37,400 | 12,651 |
| `Sources` | 62,089 | 48,890 |
| `Tests` | 60,374 | 37,664 |

这里的 LOC 包含统一排版。用同一 `.swift-format` 配置格式化基线中的 Swift 文件，
会单独减少 **27,426 行**；其余净减少 **33,353 行**。
因此 33.38% 是物理 LOC 降幅，不能表述为同比例减少了算法或业务逻辑。
排版使用标准 `swift-format`、100 列宽和四空格缩进，不通过压缩语句或删除空行凑数。

## 具体变化

- 退役 91 个逐阶段源码标记审计及 91 个包装测试。它们通过字符串存在与固定声明推断开发完成，
  无法证明行为，又会阻碍正常重命名与拆分。原始 `Evidence/` 保持原样。
- 移除 109 个 Swift 源码拼写检查；混合测试中的真实行为断言保留。
  增加实际 HomeView 导航/开关、偏好隔离、编码器错误兼容性、动态库加载、源码同步及模块边界测试。
- 合并五类 XPC 信封的严格 JSON 基础处理，各自 schema、字节上限、错误类型和关联校验保留。
- H264/HEVC 共用 VideoToolbox 生命周期，保留 codec 特有 profile、参数集要求和错误映射。
- 统一 56 处 StackView 构造；剪贴板六方向共用明确的偏好映射和单一开关处理，原持久化键不变。
- 命令名称、标题与目标分类集中在 action 上，能力撤销使用显式表驱动，保留动作顺序和拒绝条件。
- C shim 的 38 个符号由一个清单生成声明及加载检查；类型直接来自 ABI 头文件。
- 12 个 Python 证据工具共用 17 个 helper；combined-role 校验按合同、系统、Host、Viewer 分成模块。
- 移除误提交的 `mbp:/...app` 生成包（34,098,959 bytes），并阻止同类路径再次进入 Git。

## 大文件拆分

| 原入口 | 基线行数 | 当前入口行数 |
| --- | ---: | ---: |
| `Sources/RustDeskNative/RustDeskNativeApp.swift` | 6,330 | 461 |
| `Sources/RustDeskNative/HomeView.swift` | 2,883 | 304 |
| `Sources/CoreBridge/CoreBridge.swift` | 2,157 | 368 |
| `Sources/CoreBridge/HostControlClient.swift` | 2,186 | 404 |
| `CoreBridge/RustDeskPatch/rdn_bridge.rs` | 8,088 | 114 |
| `CoreBridge/RustDeskPatch/rdn_host_bridge.rs` | 10,647 | 156 |

入口行数不代表相关实现被删除。Swift 按职责拆为普通类型和 extension；
Rust 使用 topical `include!` 维持同一 ABI 编译单元，全部非空原始源码行在展开后逐行相同。
Rust tests 继续共享原有锁和模块作用域。canonical 同步及只读 verifier 递归覆盖所有职责文件。
代码之间如何连接见 [架构地图](architecture.md)。

## 验证记录

- `swift test`：968 tests，0 failures，5 skipped。
- Python unittest discovery：113 tests，全部通过；包含逐个缺失 Viewer/Host 符号和 ABI 不兼容的真实 dylib 测试。
- Rust release bridge tests：135 passed，0 failed；123 个非 bridge 上游测试被过滤。
- arm64 与 x86_64 的 `swift build -c release --arch ...` 均通过。
- 严格 Swift 格式检查、`git diff --check`、shell syntax、canonical source verifier 均通过。
- 基线 Python 套件的 10 个失败涉及本机 cpal 补丁未准备；使用既有 preparation 脚本准备依赖后，
  保留的 source verifier 与脚本测试通过。没有修改该补丁或绕过 verifier。

本次未安装、部署或重跑双机 Direct/Relay、系统授权、睡眠/网络恢复与性能验收。
GitHub Actions 仍遵循仓库既有的 release-only 策略，普通 PR 不触发 CI。
