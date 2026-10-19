# FarPane Linux 品牌资源

`org.farpane.FarPane.svg` 与 PNG 分别复制自仓库的 `App/Brand/FarPane-Mark.svg` 和 `FarPane-AppIcon-1024.png`，沿用现有 FarPane 品牌。原文件保持不变。GUI 使用资源包中的 SVG，PNG 用于安装包图标导出，Host 的纯 D-Bus 托盘也从该同一 canonical 资产生成 32×32 ARGB pixmap；生成 checkout 中的副本由 overlay pin 管理。
