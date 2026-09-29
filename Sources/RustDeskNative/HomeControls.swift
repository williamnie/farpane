import AppKit
import ConnectionCatalog

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class FlippedStackView: NSStackView { override var isFlipped: Bool { true } }

final class HomeSidebarButtonCell: NSButtonCell {
    private let horizontalPadding: CGFloat

    init(horizontalPadding: CGFloat) {
        self.horizontalPadding = horizontalPadding
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        horizontalPadding = 0
        super.init(coder: coder)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        super.imageRect(forBounds: rect.insetBy(dx: horizontalPadding, dy: 0))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: rect.insetBy(dx: horizontalPadding, dy: 0))
    }
}

final class HomeSidebarButton: NSButton {
    let page: HomePage

    var isSelected = false { didSet { updateAppearance() } }

    init(page: HomePage) {
        self.page = page
        super.init(frame: .zero)
        cell = HomeSidebarButtonCell(horizontalPadding: 10)
        title = page.title
        image = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: page.title)
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        font = .systemFont(ofSize: 12.5, weight: .medium)
        isBordered = false
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 9
        contentTintColor = .secondaryLabelColor
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    private func updateAppearance() {
        layer?.backgroundColor =
            isSelected ? HomePalette.accent.withAlphaComponent(0.13).cgColor : NSColor.clear.cgColor
        contentTintColor = isSelected ? HomePalette.accent : .secondaryLabelColor
        attributedTitle = NSAttributedString(
            string: page.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .medium),
                .foregroundColor: isSelected ? HomePalette.accent : NSColor.secondaryLabelColor,
            ])
    }
}

final class HomePermissionRowView: NSView {
    let kind: HomeSystemPermissionKind
    var onOpenSettings: ((HomeSystemPermissionKind) -> Void)?

    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "正在检测")
    private let settingsButton = NSButton()

    init(kind: HomeSystemPermissionKind) {
        self.kind = kind
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ state: HomeSystemPermissionState) {
        statusLabel.stringValue = state.statusText
        let color: NSColor = state.isGranted ? .systemGreen : .systemOrange
        statusLabel.textColor = color
        statusDot.layer?.backgroundColor = color.cgColor
        settingsButton.title = state.isGranted ? "系统设置" : "去授权"
        settingsButton.contentTintColor =
            state.isGranted ? .secondaryLabelColor : HomePalette.accent
    }

    private func configure() {
        let icon = NSImageView(
            image: NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.title)
                ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
        ])

        let title = NSTextField(labelWithString: kind.title)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let detail = NSTextField(labelWithString: kind.detail)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .tertiaryLabelColor
        let copy = NSStackView(
            views: [title, detail], axis: .vertical, alignment: .leading, spacing: 3)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),
        ])
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = .systemOrange
        let status = NSStackView(
            views: [statusDot, statusLabel], axis: .horizontal, alignment: .centerY, spacing: 6)

        settingsButton.title = "去授权"
        settingsButton.bezelStyle = .inline
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.setAccessibilityLabel("打开\(kind.title)系统设置")

        let row = NSStackView(
            views: [icon, copy, NSView(), status, settingsButton], axis: .horizontal,
            alignment: .centerY, spacing: 11)
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
    }

    @objc private func openSettings() { onOpenSettings?(kind) }
}

/// FarPane 品牌标：两块屏幕通过青色光桥连接。
