# FarPane Linux GPU 媒体重构（linux-host）：首页字体内存对照

最新决定（2026-10-18）：用户接受当前内存水平，进一步优化暂停，60 MiB 不再作为交付阻塞项。[动态回退收尾](home-font-fallback.md)已完成已有测试，交互后软件 PSS 收益约 5–10 MiB，存在字体呈现和布局差异，暂不采用产品集成。下文保留本轮静态实验与当时后续设想，硬件字体对照不再自动推进。

2026-10-18。冻结 `.20261018.5` GUI/core，在私有软件 GL 桌面完成两轮预热后的 A/B/B/A 对照。精简字体条件相对原字体的 GUI PSS 减少 **10.78–12.89 MiB**，其中字体映射减少 **10.79–10.98 MiB**。这是一项可继续验证的优化，尚未采用为产品默认；硬件桌面的 60 MiB 首页目标仍未达到，不能用本轮差值直接减去历史硬件样本。

## 方法和输入

- bundle：`farpane-native-dev-ec305482eaacd98258e28587`，manifest SHA-256 `ea282757ad9874d244c84fac80d72ea8ecf66c9c06126e42d3f29e54cb312db3`。测试前完整校验 bundle；GUI/core 不重编，暂停中的中文输入草稿未进入测试产物。
- 固定镜像：`sha256:e107f6ec93417a8d8e71ed60889972e236d94101e79de8fd2a026de8378460c1`。无网络、宿主显示/总线/配置挂载和 GPU/input/KVM 设备；4 CPU、6 GiB，两个私有 Xvfb，普通用户 GUI。
- 原始字体来自该镜像的 `/usr/share/fonts/opentype/noto/NotoSansCJK-{Regular,Bold}.ttc`；源文件哈希、SC face 2 和 FontTools 4.61.1 固定在 `Linux/tests/native-font-probe.lock.json`。输入放在 `Build/Linux/native-font-probe/input/`，版权文件来自同镜像 `/usr/share/doc/fonts-noto-cjk/copyright`，不修改宿主字体。
- `prepare-native-font-probe.py` 从 `Linux/gui/src/*.rs` 提取 463 个 CJK/全角码点，另保留普通空格与不换行空格，两个字重各 465 个码点。集合包括源码中的注释/测试文本，不声称等于全部动态界面内容。输出改名为 `FarPane UI Probe`，保留完整版权/OFL 文本；普通和粗体分别为 181,356、185,676 字节。两次生成的字体、配置、probe 和版权文件共五项逐字节一致。
- 只为私有测试子进程设置 `FONTCONFIG_FILE`，保留系统字体配置及回退。原字体条件不设置该变量。应用仍请求 GL，测试环境强制 llvmpipe；未修改产品的 renderer、字体或 allocator 默认值。

每轮先让两种条件各打开一次首页并存活五秒，再顺序执行原字体、精简字体、精简字体、原字体。每个 GUI 独立存活 20 秒，在 3/10/20 秒保存 smaps、rollup、按映射汇总和 FD；结束采样后才从 X server 截图，不调用产品截图钩子。每个 GUI 完整退出后才启动下一个，Host 配置/身份/入站状态保持相同，无 Viewer 子进程。

## 结果

下面为 20 秒 PSS，单位 MiB；完整 USS、各时间点原始映射、字体匹配/排版及实际二进制哈希随证据保存。

| 轮次 | 原字体 A1 | 精简 B1 | 精简 B2 | 原字体 A2 | 配对 PSS 减少 |
| --- | ---: | ---: | ---: | ---: | ---: |
| warm-1 | 160.56 | 148.60 | 149.57 | 160.73 | 11.96 / 11.16 |
| warm-2 | 161.25 | 148.36 | 148.82 | 159.61 | 12.89 / 10.78 |

八个测量进程的 FD 均保持 10，SwapPss 均为零，无子进程。字体映射从约 14.59–14.73 MiB 降至 3.75–3.83 MiB；后者仍包含部分原始系统 CJK 字体映射，不能声称完全移除了原字体。总 PSS 差额含分配/共享页波动，不全部归因于字体文件大小。软件 GL/LLVM 的成本使这里的绝对 PSS 高于之前硬件桌面样本；本轮没有测 CPU 优化、GPU 内存或连接性能。

每轮均验证 regular/bold 优先选择测试字体；Latin、Greek、未收录汉字 `龘` 和韩文 `한` 的单字匹配仍是相同系统文件和 face。进一步使用运行镜像真实 Pango C API，检查字形全集、中英混排、普通/不换行/em/窄空格和回退文字，共 16 项排版结果：无缺字，样本宽高与原字体一致，回退样本的完整序列化排版相同。

这些检查不等于整套 GUI 逐像素一致：第一轮正式首页截图仍有 20,629 个 RGB 像素差异，已目视核对两张首页有实际文字和控件，字体呈现和少量布局差异仍存在。固定 SC face 与该环境默认 JP face 的区别也需要纳入正式设计。动态设备名、错误提示、其他语言、用户自选字体/缩放/辅助功能及全部页面尚未验收。

## 保留的失败与测量修正

1. 首轮 `run-7aztrmdl` 没有预热和 Pango 排版检查。首次原字体 GUI 堆约 72.5 MiB，末次约 48.1 MiB；首次冷启动多出的驻留不能算作字体收益。该轮虽通过当时检查，不作为最终正确性或稳态结论。
2. `run-157ftur2` 发现固定镜像没有可用 Python GI 绑定。之后改用镜像已有 Pango 的公开 C API，没有安装主机包或更换测试镜像。
3. `run-_37d9s4u` 和补齐原始输出的 `run-ey3hfkvu` 发现 CJK-only 子集在混排中缺少空格：Pango 把尾随空格留在 Han run，实际 glyph 为 `0x10000020`。单码点 `fc-match` 全部通过仍不能排除此问题。两个字重均出现缺字，检查因此拒绝继续；保留 U+0020/U+00A0 后，正式两轮才通过全部排版检查。

未为通过测试放宽缺字条件，也未把排版测试称为远程中文输入验收。Warp 的按应用快捷键方案继续暂停。

## 复现和后续

将固定镜像中的上述两个 TTC 与版权文件只读提取到 `Build/Linux/native-font-probe/input/` 后：

```sh
python3 -B Scripts/linux/prepare-native-font-probe.py
python3 -B -m unittest discover -s Linux/tests -p test_native_home_fonts_guard.py -v
python3 -B Scripts/linux/test-native-home-fonts.py \
  Build/Linux/artifacts/farpane-native-dev-ec305482eaacd98258e28587 \
  Build/Linux/native-font-probe/fonts.wfzkyn6s
python3 -B Scripts/linux/analyze-native-home-fonts.py \
  Build/Linux/native-font-probe/run-lkkbg99m
```

生成器会打印新的字体目录，测试器会打印新的运行目录，复现时替换最后两个随机目录名。两项入口测试包含 12 个拒绝检查：宿主显示、设备、非私有 HOME/runtime、错误模式/root/容器标记，以及在任何配置调用或进程创建之前拒绝不合格环境。

下一步应在 Host 空闲且受原生活动检查保护时，用同一候选做低负载硬件/相同文件页对照，并验证动态字体回退后的内存、实际 UI 字体选择与布局。只有收益和功能都成立，才考虑应用范围的字体集成与打包；不能直接把本轮全局 prepend 测试配置带入产品。

本轮只增加测试、pin、生成/分析入口和证据。生成字体留在 Build，原始报告在[字体对照证据](../../Evidence/LinuxHost/2026-10-18-native-home-fonts/README.md)。`.5` 候选、已安装 `.1`、ID/固定密码和现有连接均未修改，没有新的应用构建、安装、提交或推送。
