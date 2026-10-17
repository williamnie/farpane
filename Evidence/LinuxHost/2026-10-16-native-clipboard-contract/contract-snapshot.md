# FarPane Linux GPU 媒体重构（hermes）：富剪贴板接口

2026-10-16。此文记录正在接入的接口，不是功能验收声明。当前 GUI/Viewer 运行路径仍是此前的双向 8 KiB 文本；新通道、类型验证和网络适配器已实现并单独测试，但尚未连接 GUI 控件、Viewer 生命周期与 Host 共享策略。不得把本检查点作为已支持富剪贴板的安装包。

## 类型与授权

对标本仓库 Mac 实现的 `rdn_bridge/clipboard.rs`、`rdn_host_bridge/clipboard.rs` 及其上限。Mac 文件只读，没有改动。共享内容限于以下类型，不传任意 MIME/Special、文件 URI 或平台格式名称：

| 类型 | 内容上限 | 额外约束 |
|---|---|---|
| 纯文本 | 64 KiB | 非空 UTF-8，不含 NUL |
| HTML / RTF | 各 1 MiB | 非空 UTF-8，不含 NUL；最多一个 HTML、一个 RTF、一个可选纯文本 fallback |
| PNG | 128 MiB | 结构完整的 IHDR/IDAT/IEND、合法尺寸/位深/色彩类型；不再套 zstd |
| RGBA | 128 MiB | 正尺寸、长度严格等于宽×高×4 |
| SVG | 4 MiB | UTF-8、规范 svg 根前缀、无 NUL/DOCTYPE；不在 FarPane 中渲染或执行 |

图片边长最多 8192，像素总数最多 7680×4320。PNG 检查用于结构和解码尺寸准入，不检查 CRC/IDAT 的完整解码正确性，不等同于图片解码成功。最终 GDK/平台粘贴测试仍须使用实际图片验证。

`Policy` 为纯文本、富文本、图片各提供本机→远端与远端→本机的独立开关，全部默认关闭。富文本中的可选纯文本 fallback 属于这份富文本的授权，不能据此允许另一份独立纯文本；这与 Mac 的 bundle 语义一致。实际 runtime 接入还需在这些开关之外同时满足认证、远端/Host 权限、会话有效性以及 GUI 焦点/生命周期约束。

## 数据与控制分离

`Linux/native/protocol/src/clipboard_socket.rs` 使用独立 AF_UNIX seqpacket 通道；沿用已验证的 SCM_RIGHTS 底层，但不进入帧通道，也不增大 64 KiB 控制消息上限。它只能由经过同 release/UID/进程身份认证的父子控制连接传递。runtime 的这一步握手尚未接入。

一份 offer 只有 serial、策略 revision、至多三个格式/偏移/长度/尺寸描述，JSON 最多 2048 字节。正文保存在一份 memfd 中，封印 WRITE/SHRINK/GROW/SEAL；描述符数量必须恰好为一，接收方先核对策略版本与类型授权，再核对文件类型、长度、封印并只读 mmap。偏移连续、无重叠、无重复格式；图片不能与文本 bundle 混装。

每个方向最多一份在途 offer。收到相同 serial+revision 的回执才能归还额度，旧回执不释放新额度；未确认前再次发送返回 WouldBlock。收到的 serial 必须递增，同方向未回执前不接受第二份 offer。通道公开超时检测，runtime 必须用有界超时停用有故障的剪贴板通道，并保持媒体会话；当前尚未接入此故障处理。

`Received` 回执仅表示接收/保留，不意味着目标应用已经粘贴。`Contents` 的已验证描述不可变，`SharedPart` 通过 Arc 持有只读映射，可作为 GBytes/Bytes 的 owner，不为每一项复制整张图片。memfd 准备、验证/解压和映射访问必须在工作线程上进行。GUI 还需限制为一份待发送/待应用候选，在选择变化、撤权、焦点变化或退出时取消旧工作。

## 网络适配

`Linux/native/clipboard_wire.rs` 在 RustDesk 的 Clipboard/MultiClipboards 与上述规范内容之间转换。它不访问桌面、配置或平台剪贴板，不打印 payload。

接收先检查类型组合和方向授权，再解压；每项同时限制线上大小与解压后大小，zstd 窗口最多 8 MiB。固定上游使用普通 zstd 压缩；大窗口非规范数据被拒绝，即使输出很小。RGBA 直接以声明尺寸的准确字节数约束解压；PNG 的第二层 zstd 拒绝。未压缩的 Bytes 直接移动，不先复制成 Vec。

发送方使用 `Bytes::from_owner(SharedPart)` 持有已验证映射；原 Contents 释放后 protobuf 仍安全持有其内容。序列化网络消息时仍会形成 wire buffer，这不是网络零拷贝，也没有消除 RustDesk 原传输上大消息对带宽的影响。两端的 policy/revision 仍需在排队、耗时工作结束以及最终发送/应用时复核。

现有 Viewer 网络队列只有 1 MiB 总额度，不可直接用它发送最大 128 MiB 图片，也不可为此把键鼠/认证的额度一并放宽。后续接入需独立的剪贴板额度和有界 latest 候选，继续与原网络发送完成生命周期绑定；这一点尚未实现。

## 已有证据与后续接入

本阶段协议测试包含富文本 bundle、重复/交叉类型、尺寸溢出、PNG 截断、SVG、非封印文件、错误 FD 数、过大元数据、撤权、旧回执和重放。真实子进程通过继承控制 socket 接收独立数据通道，再接收并验证 4 MiB RGBA memfd；控制 JSON 没有正文。已有帧通道/软件帧封印测试同时回归。

后端测试使用真实 protobuf 编解码和 zstd，验证 HTML/RTF/中文 fallback 往返、映射所有权、压缩炸弹、无效尺寸、PNG 双重压缩和先授权后解压。它不是 GDK selection、网络连接或 Host 桌面粘贴验收。

下一步必须完成：

1. Viewer 独立通道握手、类型策略事件、单份候选/回执/超时、独立网络额度，替换只抽取 Text 的旧 MultiClipboards hook；文件 worker 不启用剪贴板。
2. GUI 六个方向/类型开关、有界 MIME 流读取、ContentProvider bundle/图片发布、焦点与异步取消、来源抑制回环，避免读取未授权类型。
3. Host 持久策略、共享页控件、CM/连接撤权与后台平台适配。既有 `update_clipboard` 每次新建线程且只按大类授权，不能直接当作满足新策略的实现。需有界 owner，队列中的旧任务在实际写入前复查连接/策略版本。Host 本地读取也须按允许类型过滤，不能先读取大图再因未授权丢弃。
4. 私有 Xvfb 的 HTML/RTF/PNG/RGBA/SVG 双向内容、目标应用格式、超限/超时/撤权/回环/焦点测试；随后 Wayland 门户/数据控制与 Mac 互操作、峰值内存及媒体并发。现有服务、宿主剪贴板和真实桌面均不用于这些开发测试。

在这些工作完成前，整体 `runtime_ready=false`。本轮没有安装、提交、推送、重建 FFmpeg 或修改现有服务。
