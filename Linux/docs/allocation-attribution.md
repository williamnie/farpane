# FarPane Linux GPU 媒体重构（hermes）：首页存活分配归因

2026-10-17，使用原始 `.8` GUI/core 候选。此前首页约 78.42 MiB PSS 的测量只说明文件页与匿名页的组成，不能定位存活分配。本轮补充调用栈，未修改应用代码、分配器默认值、GUI/core/FFmpeg 或安装版本；**60 MiB 首页门槛仍未通过**。

## 方法与可信范围

固定测试镜像已包含 `libasan.so.8`。仅对私有普通用户 GUI 加载该运行库与测试观察库，20 秒后调用 `__sanitizer_print_memory_profile(100,4096)`，取得仍存活的 malloc 类分配及调用栈。没有启动 Viewer、导出截图、打开用户桌面或修改线上配置。实际 GL 身份仍为 Radeon 780M / radeonsi / ACO。

ASan 在此替换分配器，会增加 quarantine、shadow、调用栈及观察线程开销，也会改变启动时序。该轮 PSS/CPU **不是产品性能样本**，自动报告将两项预算判定设为 null。也没有将未经 sanitizer 编译的应用指令称为内存安全审计。直接 mmap、库/字体文件页、GPU 存储、分配器自身和未列出的上下文不在下面的存活 requested bytes 内。

诊断自检分配 4 MiB 与 1 KiB，释放前报告 4,195,328 字节，释放后精确剩余 1,024 字节。首次自检暴露本版 ASan 对空堆报告的断言，随后保留 1 KiB 对照，不隐藏失败。分析器还验证拒绝截断报告。

分析使用同一镜像中的 ELF，逐个核对 34 份 Build ID 和文件哈希，再解析偏移。某些发行版库已经 strip，`addr2line` 可能只给最近的导出符号；因此保留 `function_hint`，不能据此认定精确内部函数。可靠归属是 ELF、Build ID 与偏移。表格按栈中第一个非 ASan 文件汇总，表示分配调用位置，**不等同于最终对象所有者**。

## 实际结果

最终运行 `20261017T081437Z` 在第 20 秒记录 22,540,535 字节（约 21.50 MiB）、88,467 个存活块。4,096 组调用栈覆盖 21,281,774 字节，即 **94.42%**；其余 1,258,761 字节与 24,957 个小块单独保留为未列出部分，没有按比例猜测归属。

| 首个非 ASan 分配调用所在文件 | 已列出的存活分配 |
| --- | ---: |
| Mesa Gallium | 13.56 MiB |
| FreeType | 2.11 MiB |
| GLib | 1.78 MiB |
| Cairo + Pixman | 1.19 MiB |
| 其他已列出文件 | 1.66 MiB |
| 未列出的上下文 | 1.20 MiB |

直接来自 FarPane 可执行文件的已列出分配只有 3,544 字节，但 GUI 经 GTK/GLib/驱动间接触发的分配仍属于应用运行成本，不能据此声称应用总堆只有几 KiB。大部分存活调用位于图形与字体路径，当前未发现一个可以直接移除、足以填补约 18 MiB 目标差额的应用缓存。这不是 60 MiB 目标不可达的证明，也不构成降低字体/界面功能或关闭 GPU 的理由。

前序运行 `081040Z` 只列前 256 组，稳定样本覆盖约 61.7%，作为探索记录保留。`081246Z` 扩为两次完整报告后，第二次输出在原 30 秒采样结束时被截断；这是诊断夹具失败。最终改为一次 20 秒报告，并有界等待完整结束标记；外层 90 秒 GPU 探针上限不变。

两次通过的探针分别运行约 34.09/34.28 秒，分别 170/171 次现有 FarPane 视频数检查全为零。失败轮也受同一持续检查保护，但没有成功汇总，不虚构其检查总数。仅使用限定 renderD128 的单个静态私有窗口，没有实际媒体编码/解码吞吐测试。

## 复现与决定

```sh
python3 -B Scripts/linux/run-native-gpu-test.py --viewer \
  --artifact Build/Linux/artifacts/farpane-native-dev-3f68a4bc59ff54565b6a31db \
  --memory-probe allocations --home-memory
```

`allocations` 必须与 `--home-memory` 同用，不可作为普通 Viewer/产品环境配置。分析入口 `Scripts/linux/analyze-native-allocations.py RUN --artifact ARTIFACT` 在固定 `native_display_test` 容器中执行，输出 `allocation-analysis.json`，并拒绝与原始栈 Build ID 不一致的库。

本轮不再重复已做过的 allocator/trim/共享文件页对照，不凭未验优化增加新的候选版本；`.8` bundle、Deb 与源码归档保持原哈希。新增诊断代码留在 canonical Linux/Scripts，尚不在已冻结的 `.8` 源码归档中。真实桌面配对测量仍需维护窗口，方案中的 60 MiB、全部进程和 GPU 缓冲预算继续保留。

完整原始调用栈、失败、解析结果及不变性检查见[归因证据](../../Evidence/LinuxHost/2026-10-17-native-allocation-attribution/README.md)。这次没有正式性能或完整 GUI 验收结论。
