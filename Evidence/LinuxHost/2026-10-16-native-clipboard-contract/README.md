# FarPane Linux GPU 媒体重构（linux-host）：富剪贴板数据层

2026-10-16，分支 `codex/linux-host-gpu-media`，HEAD `b01c40b`。此阶段为富剪贴板接入的基础组件，尚未接入 GUI/Host 实际共享。现有 GUI 仍只支持此前的 8 KiB 文本；未生成富剪贴板 Release、安装、提交、推送或操作现有服务。

新增 canonical 类型/方向策略、Text/HTML/RTF/PNG/RGBA/SVG 验证、独立 seqpacket+SCM_RIGHTS 通道和封印 memfd 正文。每个方向一份在途数据，回执必须匹配 serial+revision；旧回执不释放新额度，重放/错误 FD/未封印文件/尺寸与布局错误均拒绝。正文不放入控制 JSON或视频帧队列。PNG 是结构/尺寸准入，未检查 CRC/IDAT 完整解码正确性；SVG 不渲染。

后端适配器使用现有 Clipboard/MultiClipboards protobuf；先授权后解压，输出大小及 8 MiB zstd 窗口都有限额。未压缩 Bytes 不先复制，发送方通过 Bytes owner 持有只读映射。仍会有网络序列化缓冲，不能据此宣称整个链路零拷贝或图片内存预算已通过。

验证：34 项协议测试、3 项原生核心适配测试、6 项 GUI 回归、59 个 canonical staging 文件和 pin/patch/overlay/lock 校验通过。协议父测试真实启动子进程，通过继承控制 socket 交付专用通道和 4 MiB RGBA memfd，子进程逐字节检查并回执；同时验证富文本大于控制消息上限时仍只有小 metadata。原帧租约/封印/描述符测试继续通过。核心只运行新增适配测试，日志中的 428 项 filtered 没有被计为通过。

后端测试实际序列化/解析 protobuf 和 zstd，核对中文/HTML/RTF bundle、释放原 Contents 后的映射所有权、权限先于无效压缩数据解码、解压输出越界、大窗口、无效尺寸、PNG 重复压缩及 SVG 拒绝条件。测试只处理合成数据，不访问用户配置/桌面/剪贴板或 GPU。

`contract-snapshot.md` 保存当前接口与接入顺序；canonical 文档为 [clipboard-contract.md](../../../Linux/docs/clipboard-contract.md)。下一步是 Viewer 通道/生命周期/独立网络额度、GUI MIME/ContentProvider 与六个开关、Host 持久策略/有界 owner/撤权，再做实际双向各格式粘贴、超限/焦点/回环、Wayland/Mac 和峰值内存验证。整体 GUI 与打包目标保持进行中，`runtime_ready=false`。

`source-state.json` 记录源码与测试可执行文件哈希；这里没有冒用旧 HUD Release 作为富剪贴板产物。构建复用现有缓存和 FFmpeg，没有修改 Mac/xuanwu、宿主 `/usr` 或现有 RustDesk/FarPane 服务。

```sh
Scripts/linux/native-container.sh -c 'cd Build/Linux/native/protocol && cargo test --offline --locked'
Scripts/linux/container.sh -c 'cd Build/Linux/src/rustdesk && cargo test --offline --locked --no-default-features --features farpane-native,linux-gpu-media --lib farpane_native::clipboard_wire::tests'
python3 -B Scripts/linux/prepare-native.py --check
```
