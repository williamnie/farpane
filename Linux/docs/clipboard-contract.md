# FarPane Linux GPU 媒体重构（hermes）：富剪贴板接口

2026-10-16。GUI/Viewer 已接入专用数据通道、六个类型/方向开关和后台 owner。Host 已接入持久分类策略、有界 X11 读写和 Wayland data-control 后台适配；原 arboard 输出已替换为原生 provider。Wayland 已有私有 Sway/Weston 协议测试，完整桌面与网络链路仍待验收，整体 `runtime_ready=false`。本文件不是完整安装包验收声明；具体测试结果以运行证据和 `gui-status.md` 为准。

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

`Policy` 为纯文本、富文本、图片各提供本机→远端与远端→本机的独立开关，全部默认关闭。富文本中的可选纯文本 fallback 属于这份富文本的授权，不能据此允许另一份独立纯文本；这与 Mac 的 bundle 语义一致。Viewer 同时检查认证、远端权限、会话有效性与策略 revision；GUI 发送还需窗口激活。窗口未激活时不发新内容，接收只保留最新待应用内容，重新激活后复查并应用。Host 六向策略与每连接 master 权限取交集；旧配置只继承文本双向权限，富文本/图片须显式授权。显式 native 策略损坏时全部关闭，不回退到旧权限。

## 数据与控制分离

`Linux/native/protocol/src/clipboard_socket.rs` 使用独立 AF_UNIX seqpacket 通道；沿用已验证的 SCM_RIGHTS 底层，但不进入帧通道，也不增大 64 KiB 控制消息上限。它只能由经过同 release/UID/进程身份认证的父子控制连接传递。GUI 在 Connect 请求后交付专用通道，文件 worker 不创建剪贴板通道或线程。

一份 offer 只有 serial、策略 revision、至多三个格式/偏移/长度/尺寸描述，JSON 最多 2048 字节。正文保存在一份 memfd 中，封印 WRITE/SHRINK/GROW/SEAL；描述符数量必须恰好为一，接收方先核对策略版本与类型授权，再核对文件类型、长度、封印并只读 mmap。偏移连续、无重叠、无重复格式；图片不能与文本 bundle 混装。

每个方向最多一份在途 offer。收到相同 serial+revision 的回执才能归还额度，旧回执不释放新额度；未确认前再次发送返回 WouldBlock。收到的 serial 必须递增，同方向未回执前不接受第二份 offer。后台 owner 在等待回执时检查 5 秒超时；通道失败只停用共享并报告状态。空闲/关闭策略时在 poll 中休眠，不做周期 payload 扫描。

`Received` 回执仅表示接收/保留，不意味着目标应用已经粘贴。`Contents` 的已验证描述不可变，`SharedPart` 通过 Arc 持有只读映射，可作为 GBytes/Bytes 的 owner，不为每一项复制整张图片。memfd 准备、验证/解压和映射校验在工作线程上完成。每端只有一个 owner、一份排队的最新 prepare 闭包、一份准备后的候选和一份待应用内容；在途额度与这些候选分别计数，不宣称整个进程始终只保留一份图片。选择/策略/焦点变化取消旧发送工作，重处理后再次复查 epoch/revision。GUI 控制线程在旧 owner 释放后才允许重试，GTK 主线程不 join。

GDK 使用有上限、3 秒总超时的异步 MIME 流读取，仅请求已授权类型；不读取文件 URI。PNG/SVG 原字节及 HTML/RTF bundle 由自定义分块 ContentProvider 提供。2026-10-17 的后续修复将收到的 RGBA 在已有 Viewer 剪贴板工作线程按行编码成 PNG，受 128 MiB 输出上限、三秒处理期限及撤权/取消检查约束，再通过封印通道交给 GUI 的同一分块 provider。GUI 拒绝未经转换的 RGBA offer，避免 GDK MemoryTexture 内置序列化绕过保留量和输出额度。不会给原 PNG 再做解码/编码；网络 RGBA 能力、像素和字节上限没有降低。该修复的当前验证状态见[RGBA 边界记录](clipboard-rgba.md)。

弱 provider 身份抑制自身回声，不额外持有旧图片。已写入本机剪贴板的内容在关闭共享后保留；当 GDK 仍是 selection owner 时，当前 provider 的内容内存也会保留，必须计入 GUI/剪贴板内存预算。

GUI 的原字节 provider 每次向 GIO 异步写最多 64 KiB，避免一次向 GDK 提交整幅图片；GDK 按它的请求大小门槛输出，并在 provider 完成后关闭流。所有此类 provider 共用 4 个输出额度；每步最多 3 秒、一次输出总计最多 30 秒。取消后仍未返回的 GIO callback 保留额度及至多一段 64 KiB 副本，不把整份 memfd 留在该 callback 中。当前/旧 provider 的独立正文总保留限额为 256 MiB，MIME 别名不重复计数；超限保留原剪贴板并报告本次未同步。GDK 本身的 stream 缓冲、纹理序列化和图形资源另计，不能把这个上限当作 GUI 总内存。局部 GIO 管道测试已覆盖四个卡住读者、第五个拒绝、超时取消及之后恢复。

## 网络适配

`Linux/native/clipboard_wire.rs` 在 RustDesk 的 Clipboard/MultiClipboards 与上述规范内容之间转换。它不访问桌面、配置或平台剪贴板，不打印 payload。

固定上游会同时发送 PNG 和 RGBA，并可能附带文本表示。网络适配器先限制六种已知候选、无重复类型与 128 MiB 线上总量，再根据授权选择单一图片（PNG、RGBA、SVG 顺序）、富文本 bundle 或纯文本；任意 Special/未知格式拒绝。内部通道仍只允许至多三个条目的单一类别。选中的内容先检查组合和方向授权，再解压；每项同时限制线上大小与解压后大小，zstd 窗口最多 8 MiB。固定上游使用普通 zstd 压缩；大窗口非规范数据被拒绝，即使输出很小。RGBA 直接以声明尺寸的准确字节数约束解压；PNG 的第二层 zstd 拒绝。未压缩的 Bytes 直接移动，不先复制成 Vec。

发送方使用 `Bytes::from_owner(SharedPart)` 持有已验证映射；原 Contents 释放后 protobuf 仍安全持有其内容。序列化网络消息时仍会形成 wire buffer，这不是网络零拷贝，也没有消除 RustDesk 原传输上大消息对带宽的影响。Viewer 在排队、耗时工作结束以及从网络队列取出时复核 policy/revision；GUI 在消费控制事件后才应用数据，撤权优先于尚未消费的 offer。已经交给原网络传输的发送不能追回。

Viewer 原键鼠/认证队列保持 256 项、1 MiB。剪贴板另有单项、128 MiB 加 protobuf 开销额度，credit 保持至真实异步网络发送结束。等待额度最多 2 秒，仅阻塞剪贴板 owner；错误不调用会话 fail。独立额度不意味着原网络连接上的大图片不会占用带宽或造成传输等待。

2026-10-17 [传输内存改进](clipboard-memory.md)：native Host/Viewer 解析时共享 protobuf 正文字节，且大消息发送完成后释放已空的 TCP 写缓冲。相同 128 MiB PNG 双向夹具的三进程同时 PSS 峰值下降约 24%；仍有接收/加密/平台缓冲，未降低限额，也未据此标记首页或完整剪贴板内存预算通过。

## X11 监听修复

实际双向测试暴露固定 `clipboard-master` 的 X11 事件遗漏：每次回调后休眠，再清除/重建订阅并提高 sequence 门槛，使休眠期间排队的下一次 owner 变化被过滤。失败实验中新的 Host selection owner 已成功持有剪贴板，却没有收到 Host 读取请求。

`0027-clipboard-x11-events.patch` 保持一次订阅和初始序号门槛，只处理对应 CLIPBOARD 的 XFixes SelectionNotify；`0028-clipboard-source.patch` 使用隔离构建目录内的固定源码。依赖 commit 仍为 `522fafb65edfe7939cf63fa797f916569ecab595`，canonical pin/patch/lock 在 Linux/，生成 checkout 在 Build/Linux/src/clipboard_master，原缓存和旧实验只读。它修复通知遗漏，不替代后续 Host 分类授权和有界内容 owner。

## 已有证据与后续接入

本阶段协议测试包含富文本 bundle、重复/交叉类型、尺寸溢出、PNG 截断、SVG、非封印文件、错误 FD 数、过大元数据、撤权、旧回执和重放。真实子进程通过继承控制 socket 接收独立数据通道，再接收并验证 4 MiB RGBA memfd；控制 JSON 没有正文。已有帧通道/软件帧封印测试同时回归。

后端测试使用真实 protobuf 编解码和 zstd，验证 HTML/RTF/中文 fallback 往返、映射所有权、压缩炸弹、无效尺寸、PNG 双重压缩和先授权后解压。它不是 GDK selection、网络连接或 Host 桌面粘贴验收。

后续必须完成：

1. Host Wayland 的完整桌面/网络链路、最大像素 RGBA 转换与整个应用的内存预算。X11 INCR 与 Wayland data-control 已实现最大字节内容的有界输出，限制见下文；不能从带填充的两像素 PNG 推断最大像素图片或跨平台解码已验收。
2. 扩大实际桌面测试至故障/慢 owner/快速选择变化、远端撤权、失焦、Wayland 与 Mac 互操作、最大图片峰值内存及媒体并发。PNG 与 SVG 的双向真实连接、RGBA 的 GDK provider 检查需分别记录，不能把局部 provider 测试说成跨平台网络验收。
3. 完整 GUI、后台生命周期、打包/兼容与低内存目标仍按主方案推进。现有服务、宿主剪贴板和真实桌面不用于这些开发测试。

整体 `runtime_ready=false`。开发产物留在 Build/Linux；本轮不安装、提交、推送、重建 FFmpeg 或修改现有服务。


## Host 分类策略与 X11 后台接入

`SetHostClipboard` 只修改 `farpane-clipboard-policy` 和 generation，不覆盖音频、文件或旧 `enable-clipboard`。同一 durable 配置事务验证 revision；离线与在线均使用现有鉴权接口。共享页提供三类 × 两方向实际控件，方向以 Host 本机为准。旧版回退保留它自己的原权限值，native 新授予的富文本/图片不会隐式扩大旧版权限。

Native Host 连接不再订阅上游通用剪贴板服务，也不走每次更新新建线程的 `update_clipboard`。一个后台工作线程保留一份最新输入；网络线程先按类别授权及已知线上限额准入，后台进行有界解压，实际写入前复查连接 epoch 与策略 generation。显式 CM 撤销在控制线程立即使该连接失效，连接内撤销保持到连接结束，旧选项事件不能重新授予；全关也撤销现有连接。重新开启策略适用于新连接，不自动恢复已撤销的连接。

X11 使用独立未映射窗口与一次 XFixes 订阅，不显示窗口或改变焦点。先读取最多 4 KiB 的 TARGETS，筛除文件 URI 和自身/旧 RustDesk 的来源标记，只请求已授权的具体表示；PNG/SVG 优先保留原字节，HTML/RTF 可携带文本 fallback。单次属性回复最多 64 KiB，INCR 声明长度、累积内容和每格式上限均校验；3 秒是整个 selection 内容请求的期限，不随分块刷新。取消/超时销毁 requestor；读取期间变化使候选失效并保留新变化通知。该期限约束其他剪贴板应用的响应，**本地 X server 的同步请求/回复仍是平台依赖**，不能据此声称 X server 整体冻结时也能自动恢复。

出站每连接仅保留最新 watch 候选，所有 Host 连接共享一份网络发送额度，覆盖实际 protobuf 序列化及 TCP 发送。未获额度的连接保留最新值，额度释放后通知重新检查；serial 防止重复发送。相同一轮候选的 Bytes 共享存储，不给每个连接复制图片。权限变化清除排队候选，实际网络发送前再次检查。已经交给平台或网络的操作不能撤回；控制响应等待已开始的本机写入结束，最多 4 秒，超时报告未确认，而非伪称撤权完成。

没有获准发送的连接时不创建/保留 reader；全关没有平台内容轮询。当前写入 provider 为保持用户已复制内容而保留，必须计入 Host 内存成本。Wayland 使用下述独立适配，不通过 Xwayland 假装覆盖整个 Wayland 桌面。本文的接入描述不替代实际测试或跨平台验收；完整 GUI 目标仍在进行。

## X11 原生输出与事件驱动

`clipboard_x11_writer.rs` 在既有 Host 剪贴板线程处理 selection 请求，不加载 GTK、不创建额外 provider 线程。PNG/SVG/文本使用原 `Bytes`；文本的三个 MIME 别名共享存储。RGBA 按行编码为 PNG，编码输出最多 128 MiB，并在每行和输出写入前检查取消。RGBA 输入和转换后的 PNG 是两份独立存储，不能按 PNG 原字节路径宣称无副本。

超过 64 KiB 的内容走 INCR；每收到 requestor 的属性删除后才发送下一段，单段最多 64 KiB。同一时刻最多 4 个 INCR 请求，同一窗口/属性不能重复占位。每次传输有 3 秒不活动和 30 秒总期限；requestor 销毁立即释放引用。当前内容和在途旧内容按不同底层 selection 计数，总保留上限 256 MiB；若替换会超限，保留原 selection 并报告写入失败。这不是整个 Host 的内存上限：候选解压、RGBA 转换、网络 wire buffer 和分配器保留另计。

已开始的 INCR 在新内容覆盖或失去 selection 所有权后继续完成，期间持有原内容；新本地 owner 到来后释放当前内容。支持 TARGETS、TIMESTAMP 和最多 16 对的 MULTIPLE，失败条目将对应 property 置为 None。所有权时间由真实 X11 PropertyNotify 取得；取消或撤权在提交所有权前再检查。协议语义参照 [X.org ICCCM](https://xorg.freedesktop.org/archive/current/doc/xorg-docs/icccm/icccm.html)，MULTIPLE 的失败表示与 [GTK4 X11 实现](https://raw.githubusercontent.com/GNOME/gtk/4.14.5/gdk/x11/gdkselectionoutputstream-x11.c)一致。

工作线程同时等待 eventfd、reader 和 writer 的 X11 FD，以及实际传输期限；没有内容/任务时阻塞等待，不定时读取剪贴板。读取对端 INCR 时继续派发本机 writer 请求。此前每个空事件轮固定休眠 5 ms，会让数千分块耗尽读取的 3 秒总期限；现改为可被 X11 数据立即唤醒的 poll，保留原期限和最多 5 ms 的取消检查间隔。X server 的同步请求/回复仍是平台依赖，不据此声称能从整体冻结恢复。

## Wayland 后台读写与能力边界

`clipboard_platform.rs` 根据 Wayland 环境明确选择后端；`clipboard_wayland.rs` 优先使用 `ext_data_control_v1`，其次为 `zwlr_data_control_v1`。它在既有 Host 剪贴板线程内处理事件，不创建 GTK 窗口、surface 或额外线程，也不请求焦点。仅支持一个明确的 seat 和 CLIPBOARD；忽略 primary selection。缺失协议/seat、多个 seat、设备或 manager 被撤销、连接失败时停止该后端并报告不可用，不能据只发送了请求就显示同步成功。

Reader/Writer 各自连接具名的 Wayland Unix socket。连接和初始化 roundtrip 均有三秒期限；连接路径、相关 global、offer 和 MIME 的数量/长度均受限。继承的 `WAYLAND_SOCKET` 明确拒绝，不消费或关闭该 FD、不改进程环境，也不另连具名 socket 绕开它可能代表的权限边界。相对 `WAYLAND_DISPLAY` 只在绝对 `XDG_RUNTIME_DIR` 下解析；这些约束意味着某些沙箱/多 seat 环境当前不支持。

Reader 先筛掉文件类型和自身标记，仅对获准格式请求内容；整个 selection 读取仍限三秒，单段最多 64 KiB，每段和每种格式前检查取消及 selection 代。给来源的写 FD 保持阻塞语义，本地读 FD 非阻塞；读取期间继续服务 writer。选择变更使旧候选失效。Writer 原字节共享、RGBA 有界 PNG 编码、四路传输和 256 MiB 独立 selection 保留额度与 X11 相同；每段最多 64 KiB，三秒不活动/三十秒总期限。源被替换或 cancelled 后，已开始的管道传输仍持有旧数据直至完成、超时或对端关闭。合成器不取消旧 source 时最多保留八个 source 对象。

事件循环等待 Wayland/传输 FD 和实际期限；没有来源时不扫描内容。合成器连接异常或输出背压导致明确失败，再由 Host 的有界重试恢复；不在 GTK 主线程阻塞。共享页显示后端状态，六个开关仍表示用户保存的策略，并非合成器授予能力的证明。尚未增加供远端显示的独立动态能力字段；平台接受 selection 也不代表目标应用完成粘贴。

`test-native-wayland-clipboard.sh supported` 在无宿主桌面/GPU 的私有 Sway 中逐一覆盖 ext 和 wlr 实际协议，各 24 项，包括 UTF-8、富文本、SVG、透明 RGBA、128 MiB PNG、四路/额度/取消、替换后旧传输完成、超时恢复、继承 FD 保留和卡住合成器的初始化期限。wlr 分支通过仅在测试构建启用的筛选模拟 ext 不可用；生产构建始终按真实能力协商。`unavailable` 使用不提供 data-control 的私有 Weston，Reader/Writer 均明确拒绝，不回落 Xwayland。它们是后台适配测试，尚不是 GNOME/KDE、真实 Host Wayland 采集或完整网络会话验收。
