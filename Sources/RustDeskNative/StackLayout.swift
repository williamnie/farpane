import AppKit

extension NSStackView {
    /// 统一布局构造，省略的 spacing 继续使用 AppKit 默认值。
    convenience init(
        views: [NSView], axis: NSUserInterfaceLayoutOrientation,
        alignment: NSLayoutConstraint.Attribute, spacing: CGFloat? = nil
    ) {
        self.init(views: views)
        orientation = axis
        self.alignment = alignment
        if let spacing { self.spacing = spacing }
    }
}
