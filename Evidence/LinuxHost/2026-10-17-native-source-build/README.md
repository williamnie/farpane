# FarPane Linux GPU 媒体重构（linux-host）：完整源码构建与隔离连接

本阶段证明固定 `6464d1ae…` 开发源码快照可以在公开 Ubuntu 24.04 编译环境中，使用新编译的原生依赖、空 Cargo/target 缓存完成媒体库、原生核心及 GTK4 GUI 构建。新二进制在两个发行版环境中完成短时软件视频连接。未替换 `.4` 候选或线上服务，不等于正式发布、真实桌面或性能验收。

## 输入与构建

源码 manifest SHA-256：`6464d1ae0ddf72e154ec4431b91816a75942a7557e00ce243abe89ce3a17aff3`，88,608 条逐项校验。此前独立非 FFmpeg 前缀的 209 条文件清单 SHA-256：`80d5c1ed47b3c31ddc4c91d2821969fb3d160cbdc72009092d64e3052e5556ad`；再次逐项核对后复制到新前缀，不读取旧媒体二进制缓存。

Builder：`sha256:d0923a2040628a31f2048eb01704030bed22b5ae35e61726378565ff557b710d`，来源、包版本、公开基础镜像查询见[上一阶段](../2026-10-17-native-bootstrap/README.md)。Rust 1.89.0 SDK 只读复用；不声明从源码编译 Rust/GCC 工具链。构建普通 UID、断网、4 CPU、12 GiB，没有宿主服务/桌面/音频/GPU/凭据或产品前缀挂载。

输出 `Build/Linux/native-bootstrap/application.fQLWLQG3`。四阶段全部成功：新 FFmpeg 9.0.2 37.195 秒、libdrmtap 1.617 秒、原生核心 522.089 秒、GTK4 GUI 59.863 秒；不含镜像/复制/校验耗时。`build/stages.json` 绑定完整日志和命令。AMF 头文件及 Meson wheel 来自已固定归档。新 `.a`、libdrmtap 和两个程序哈希在 `build/result.json` 中。

- 核心：`74ec25af68e3ea487453e22b934973f153f027fa518f93891566f5bc2a5fc13d`
- GUI：`482a3d8d69a31199de48b2d4a368c21101d79a1bb902404223282990f6221cc0`
- 构建结果 JSON：`c6dbcbaa7ff0866088465a1f178c58760affc85019ea5966cbdaf6476014561b`

两个程序的 `--build-info`、协议版本、实际动态依赖及解析通过，仍 `runtime_ready=false`。源码中的旧 GUI 默认 feature 关闭；没有动态 FFmpeg、Flutter/Sciter/GTK3 依赖。新输出不要求与 `.4` 旧编译器/库环境生成的二进制按位相同。

## 汇总器失败与修复

第一次运行已经完成四个编译阶段，但最后的 glob 同时匹配 `libdrmtap.so.0.5.8` 和 Meson 中间目录 `libdrmtap.so.0.5.8.p`，因此汇总失败（handle 78213 exit 1）。修正为只统计普通库文件，并增加“只验证已完成编译”的入口。验证模式要求同一镜像、四阶段成功、原命令和日志哈希一致，重新核对所有原源文件内容；只允许上游重新生成 `src/version.rs`。

handle 85773 验证成功 exit 0，未执行编译。实际源内容比较也确认只有上述生成日期文件变化。修正前入口、首次失败日志和修正后验证日志均保留，不能把首次运行改记为一遍通过。新验证模式不会覆盖已有成功结果。

## 新程序实际运行

`build/runtime-result.json` 绑定构建结果与两个实际运行目录；`test-binaries.json` 与上面两个新程序哈希完全一致。

| 环境 | 目录 | 结果 |
| --- | --- | --- |
| Ubuntu 24.04 纯运行镜像 | `runtime.IhtPGB2B` | 九类检查通过，两次会话各呈现 1 帧 |
| Ubuntu 26.04 环境 | `runtime.ZbNmFUDZ` | 九类检查通过，两次会话分别呈现 2、1 帧 |

检查覆盖回环认证、真实软件视频解码、GTK 呈现、错误密码重试、Viewer 退出回收、第二次连接、Host 保留、身份/媒体/认证/网络设置保持和成功历史。只用两个私有 Xvfb、loopback、容器自己的 `/opt` 和 `/run`。这是短时功能检查，不是吞吐、长稳、GPU 或真实桌面验收；两种容器共享 linux-host 内核。

运行 handles 66627、39686 均 exit 0。日志、事件、smaps 与真实二进制标识留存；8 份私有夹具 PNG 只留大小/哈希，不复制图像负载。smaps 来自该软件夹具，不将其作为真实 GPU 首页内存目标的重新验收。

## 边界与后续

`host-state.json` 与上一阶段逐项一致：当前 FarPane release、FarPane/RustDesk 服务状态和 PID，以及四份既有 FFmpeg `.a` 大小/mtime/hash 均未变。原产品构建 receipt 验证通过。没有安装、服务切换、桌面/显示/密码/身份/网络修改，没有 commit/push/deploy。维护确认仍待回复。

canonical 变更仅为构建/验证入口、独立依赖清单自动输出及文档；本阶段没有改变现有 GUI/Host/Viewer 的源运行路径。清单函数对已完成 209 条前缀产生与旧留存清单完全相同的字节，未重建已有成功依赖。

`.4` 候选和冻结源码归档保持原样；新增 bootstrap 入口尚未纳入该归档，后续证明以原 manifest 哈希单独绑定。公开 Linux CI、可移植打包入口及完整发布许可审计仍待完成；真实 GNOME/KDE/Wayland、systemd/logind、Mac 互操作、GPU/硬件音频、长期稳定与配对性能等仍待验收，60 MiB 首页目标此前未过。本阶段不缩小这些未完成范围。

`SHA256SUMS` 是本地文件证据索引，不是发布者签名。
