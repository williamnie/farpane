# FarPane 品牌与图标规范

状态：Implemented

## 1. 名称

产品对外名称为 **FarPane**，含义是“通往远端桌面的窗口”。中文语境可以解释为“远窗”，
但应用标题、菜单和 Logo 统一只使用英文 `FarPane`。

FarPane 是独立产品品牌。连接协议、身份验证、加密与网络传输仍由 pinned RustDesk Core
处理；需要说明实现来源时使用 `Powered by RustDesk Core`，不把 RustDesk 放进主 Logo。

## 2. 兼容边界

本次只更改用户可见品牌和安装包文件名，以下内部身份保持不变：

- Bundle ID：`io.rustdesknative.viewer`
- Swift Package、target 与可执行文件：`RustDeskNative`
- Keychain service：`io.rustdesknative.viewer.device-password`
- 数据目录：`~/Library/Application Support/RustDesk Native Viewer/`

这样既能沿用已有设备目录和 Keychain 凭据，也能保持稳定签名下的 macOS TCC 权限身份。
安装脚本会把旧的 `RustDesk Native Viewer.app` 移入同一备份目录，再安装 `FarPane.app`。

## 3. 图形语言

品牌标由两块抽象屏幕和中间的青色光桥组成：左侧蓝色代表本机入口，右侧紫色代表远端
画面，光桥代表低延迟的画面与输入传输。

主色：

- Deep Navy：`#080D4A`
- Connection Blue：`#0A91FF`
- Bridge Cyan：`#27D8FF`
- Remote Violet：`#A04AFF`

不得增加 RustDesk 图形、TeamViewer 双箭头、无限符号、云、盾牌或鼠标指针。

## 4. 资产

- `App/Brand/FarPane-AppIcon-1024.png`：1024×1024 RGBA App Icon 母版。
- `App/FarPane.icns`：随 macOS App Bundle 分发的多尺寸图标。
- `App/Brand/FarPane-Mark.svg`：透明背景独立图形标。
- `App/Brand/FarPane-Logo.svg`：透明背景横向 Logo。

App Icon 的深色圆角方形是图标主体，圆角以外必须是真透明 Alpha。不得把白色、浅灰色或
设计稿画板烘焙进 PNG；四个角像素的 alpha 必须为 `0`。Dock、Finder、浅色模式和深色
模式都使用同一母版。

## 5. 应用内使用

首页左上角使用透明背景图形标和 `FarPane` 字标，不把完整 App Icon 缩成装饰性小方块。
窗口标题、菜单栏应用名和安装包文件名统一为 `FarPane`。协议字段仍可写
“RustDesk 设备 ID”或“RustDesk ID 服务器”，因为它们描述的是兼容协议配置而不是品牌。
