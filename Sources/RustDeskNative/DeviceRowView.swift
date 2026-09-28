import AppKit
import ConnectionCatalog

final class DeviceRowView: NSView {
    var onAction: ((HomeDeviceAction) -> Void)?

    private let item: HomeDeviceItem
    private let favoriteButton = NSButton()

    init(item: HomeDeviceItem, isConnecting: Bool) {
        self.item = item
        super.init(frame: .zero)
        configure(isConnecting: isConnecting)
    }

    required init?(coder: NSCoder) { nil }

    private func configure(isConnecting: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = HomePalette.panel.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor

        favoriteButton.bezelStyle = .inline
        favoriteButton.image = NSImage(
            systemSymbolName: item.device.isFavorite ? "star.fill" : "star",
            accessibilityDescription: item.device.isFavorite ? "取消收藏" : "收藏")
        favoriteButton.contentTintColor =
            item.device.isFavorite ? .systemYellow : .tertiaryLabelColor
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)

        // 设备类型图标
        let avatarView = NSView()
        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 6
        avatarView.layer?.backgroundColor =
            NSColor.quaternaryLabelColor.withAlphaComponent(0.14).cgColor
        let avatarIcon = NSImageView(
            image: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "电脑")
                ?? NSImage())
        avatarIcon.contentTintColor = .secondaryLabelColor
        avatarView.addSubview(avatarIcon)
        avatarIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 30),
            avatarView.heightAnchor.constraint(equalToConstant: 30),
            avatarIcon.widthAnchor.constraint(equalToConstant: 15),
            avatarIcon.heightAnchor.constraint(equalToConstant: 15),
            avatarIcon.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarIcon.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
        ])

        let name = NSTextField(labelWithString: item.device.resolvedDisplayName)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail

        // meta：ID（等宽数字）· 相对时间 · 已验证徽标
        let idLabel = NSTextField(labelWithString: formatPeerID(item.device.peerID))
        idLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        idLabel.textColor = .secondaryLabelColor
        idLabel.lineBreakMode = .byTruncatingTail

        var metaParts: [NSView] = [idLabel]
        if let date = item.device.lastSuccessfulConnectionAt {
            let timeLabel = NSTextField(labelWithString: relativeTime(date))
            timeLabel.font = .systemFont(ofSize: 12)
            timeLabel.textColor = .secondaryLabelColor
            let dotLabel = NSTextField(labelWithString: "·")
            dotLabel.font = .systemFont(ofSize: 12)
            dotLabel.textColor = .tertiaryLabelColor
            let badgeView = verifiedBadge()
            metaParts.append(contentsOf: [dotLabel, timeLabel, badgeView])
        }
        let detail = NSStackView(
            views: metaParts, axis: .horizontal, alignment: .centerY, spacing: 7)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let identity = NSStackView(
            views: [name, detail], axis: .vertical, alignment: .leading, spacing: 3)
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let credential = NSImageView(
            image: NSImage(
                systemSymbolName: item.hasSavedPassword ? "lock.fill" : "lock.open",
                accessibilityDescription: item.hasSavedPassword ? "已保存密码" : "未保存密码") ?? NSImage())
        credential.contentTintColor =
            item.hasSavedPassword ? .secondaryLabelColor : .tertiaryLabelColor
        credential.toolTip = item.hasSavedPassword ? "密码已保存在此 Mac 的钥匙串" : "连接时需要输入密码"

        let sendFiles = NSButton(title: "发文件", target: self, action: #selector(sendFiles))
        sendFiles.bezelStyle = .rounded
        sendFiles.toolTip = "连接后立即选择文件或文件夹发送到远端"
        sendFiles.setAccessibilityLabel("发送文件到此设备")
        sendFiles.isEnabled = !isConnecting

        let connect = NSButton(
            title: isConnecting ? "连接中…" : "连接", target: self, action: #selector(connect))
        connect.bezelStyle = .rounded
        connect.contentTintColor = isConnecting ? .tertiaryLabelColor : HomePalette.accent
        connect.font = .systemFont(ofSize: 12, weight: .semibold)
        connect.isEnabled = !isConnecting

        let more = NSButton(
            image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作")
                ?? NSImage(), target: self, action: #selector(showMenu))
        more.bezelStyle = .inline
        more.toolTip = "更多操作"

        let row = NSStackView(
            views: [
                avatarView, favoriteButton, identity, NSView(), credential, sendFiles, connect,
                more,
            ], axis: .horizontal, alignment: .centerY, spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            connect.widthAnchor.constraint(equalToConstant: 64),
            sendFiles.widthAnchor.constraint(equalToConstant: 68),
            credential.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func verifiedBadge() -> NSView {
        let badgeView = NSView()
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 8
        badgeView.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.12).cgColor
        let label = NSTextField(labelWithString: "已验证")
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .systemGreen
        badgeView.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            badgeView.heightAnchor.constraint(equalToConstant: 17),
        ])
        return badgeView
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = HomePalette.panelHover.cgColor
        layer?.borderColor = HomePalette.accent.withAlphaComponent(0.35).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = HomePalette.panel.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
    }

    private func formatPeerID(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty, compact.allSatisfy(\.isNumber) else { return value }
        return stride(from: 0, to: compact.count, by: 3).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(3, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: " ")
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @objc private func connect() { onAction?(.connect) }

    @objc private func sendFiles() { onAction?(.sendFiles) }

    @objc private func toggleFavorite() { onAction?(.toggleFavorite) }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        addItem(item.device.isFavorite ? "取消收藏" : "收藏", #selector(menuFavorite), to: menu)
        addItem("重命名…", #selector(menuRename), to: menu)
        menu.addItem(.separator())
        addItem("更新密码并连接…", #selector(menuUpdatePassword), to: menu)
        let deletePassword = addItem("删除已保存密码", #selector(menuDeletePassword), to: menu)
        deletePassword.isEnabled = item.hasSavedPassword
        menu.addItem(.separator())
        let deleteDevice = addItem("删除设备…", #selector(menuDeleteDevice), to: menu)
        deleteDevice.isEnabled = true
        menu.popUp(
            positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY), in: sender)
    }

    @discardableResult private func addItem(_ title: String, _ action: Selector, to menu: NSMenu)
        -> NSMenuItem
    {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menu.addItem(menuItem)
        return menuItem
    }

    @objc private func menuFavorite() { onAction?(.toggleFavorite) }
    @objc private func menuRename() { onAction?(.rename) }
    @objc private func menuUpdatePassword() { onAction?(.updatePassword) }
    @objc private func menuDeletePassword() { onAction?(.deletePassword) }
    @objc private func menuDeleteDevice() { onAction?(.deleteDevice) }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
