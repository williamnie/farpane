import AppKit
import ConnectionCatalog

struct HomeDeviceItem: Equatable {
    let device: SavedDevice
    let hasSavedPassword: Bool
}

struct HomeSnapshot: Equatable {
    var server: ServerConfiguration?
    var devices: [HomeDeviceItem]
    var statusText: String
    var errorText: String
    var connectingPeerID: String?
}

enum HomeDeviceAction {
    case connect
    case toggleFavorite
    case rename
    case updatePassword
    case deletePassword
    case deleteDevice
}

final class HomeView: NSView, NSTextFieldDelegate, NSSearchFieldDelegate {
    var onQuickConnect: ((String) -> Void)?
    var onOpenServerSettings: (() -> Void)?
    var onDeviceAction: ((UUID, HomeDeviceAction) -> Void)?

    private let serverButton = NSButton()
    private let peerField = NSTextField()
    private let connectButton = NSButton(title: "连接", target: nil, action: nil)
    private let filterControl = NSSegmentedControl(
        labels: ["全部", "收藏"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let searchField = NSSearchField()
    private let listStack = FlippedStackView()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var snapshot = HomeSnapshot(
        server: nil,
        devices: [],
        statusText: "就绪",
        errorText: "",
        connectingPeerID: nil
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ snapshot: HomeSnapshot) {
        self.snapshot = snapshot
        serverButton.title = snapshot.server?.displayName.nonEmpty ?? "配置服务器"
        serverButton.contentTintColor = snapshot.server?.isComplete == true
            ? .secondaryLabelColor
            : .systemOrange
        statusLabel.stringValue = snapshot.statusText
        errorLabel.stringValue = snapshot.errorText
        errorLabel.isHidden = snapshot.errorText.isEmpty
        let canConnect = snapshot.server?.isComplete == true
            && snapshot.connectingPeerID == nil
            && !peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        connectButton.isEnabled = canConnect
        peerField.isEnabled = snapshot.connectingPeerID == nil
        connectButton.title = snapshot.connectingPeerID == nil ? "连接" : "连接中…"
        serverButton.isEnabled = snapshot.connectingPeerID == nil
        renderDevices()
    }

    func focusQuickConnect() {
        window?.makeFirstResponder(peerField)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let product = NSTextField(labelWithString: "RustDesk Native Viewer")
        product.font = .systemFont(ofSize: 13, weight: .semibold)
        product.textColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "控制远程设备")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        let subtitle = NSTextField(
            wrappingLabelWithString: "从最近设备快速连接，或输入新的 RustDesk 设备 ID。"
        )
        subtitle.textColor = .secondaryLabelColor

        serverButton.bezelStyle = .inline
        serverButton.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "服务器设置"
        )
        serverButton.imagePosition = .imageLeading
        serverButton.target = self
        serverButton.action = #selector(openServerSettings)
        serverButton.toolTip = "服务器设置"

        let headerText = NSStackView(views: [product, title, subtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 5
        let header = NSStackView(views: [headerText, NSView(), serverButton])
        header.orientation = .horizontal
        header.alignment = .top

        peerField.placeholderString = "输入对方设备 ID"
        peerField.font = .systemFont(ofSize: 17)
        peerField.focusRingType = .default
        peerField.delegate = self
        peerField.target = self
        peerField.action = #selector(connectQuickly)
        peerField.setAccessibilityLabel("远端设备 ID")

        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .large
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectQuickly)

        let quickRow = NSStackView(views: [peerField, connectButton])
        quickRow.orientation = .horizontal
        quickRow.alignment = .centerY
        quickRow.spacing = 12
        quickRow.translatesAutoresizingMaskIntoConstraints = false
        peerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            peerField.heightAnchor.constraint(equalToConstant: 34),
            connectButton.widthAnchor.constraint(equalToConstant: 92),
        ])

        let quickContainer = NSView()
        quickContainer.wantsLayer = true
        quickContainer.layer?.cornerRadius = 14
        quickContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        quickContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        quickContainer.layer?.borderWidth = 1
        quickContainer.addSubview(quickRow)
        NSLayoutConstraint.activate([
            quickRow.leadingAnchor.constraint(equalTo: quickContainer.leadingAnchor, constant: 18),
            quickRow.trailingAnchor.constraint(equalTo: quickContainer.trailingAnchor, constant: -18),
            quickRow.topAnchor.constraint(equalTo: quickContainer.topAnchor, constant: 18),
            quickRow.bottomAnchor.constraint(equalTo: quickContainer.bottomAnchor, constant: -18),
        ])

        let recentTitle = NSTextField(labelWithString: "最近连接")
        recentTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        searchField.placeholderString = "搜索"
        searchField.delegate = self
        searchField.setContentHuggingPriority(.required, for: .horizontal)
        searchField.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let listToolbar = NSStackView(views: [recentTitle, NSView(), filterControl, searchField])
        listToolbar.orientation = .horizontal
        listToolbar.alignment = .centerY
        listToolbar.spacing = 12

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = listStack
        NSLayoutConstraint.activate([
            listStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.isHidden = true
        let statusDot = NSTextField(labelWithString: "●")
        statusDot.textColor = .systemGreen
        statusDot.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        let footer = NSStackView(views: [statusDot, statusLabel, NSView()])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 7

        let content = NSStackView(views: [
            header,
            quickContainer,
            listToolbar,
            errorLabel,
            scrollView,
            footer,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.setCustomSpacing(26, after: header)
        content.setCustomSpacing(26, after: quickContainer)
        content.setCustomSpacing(8, after: listToolbar)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        for view in [header, quickContainer, listToolbar, errorLabel, scrollView, footer] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 42),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -42),
            content.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 34),
            content.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -22),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
        ])
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === peerField {
            let hasID = !peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            connectButton.isEnabled = hasID
                && snapshot.server?.isComplete == true
                && snapshot.connectingPeerID == nil
        } else {
            renderDevices()
        }
    }

    private func renderDevices() {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let favoritesOnly = filterControl.selectedSegment == 1
        let items = snapshot.devices.filter { item in
            guard !favoritesOnly || item.device.isFavorite else { return false }
            guard !query.isEmpty else { return true }
            return item.device.resolvedDisplayName.localizedCaseInsensitiveContains(query)
                || item.device.peerID.localizedCaseInsensitiveContains(query)
        }

        if items.isEmpty {
            let message: String
            if !query.isEmpty { message = "没有匹配设备" }
            else if favoritesOnly { message = "还没有收藏设备" }
            else { message = "还没有最近连接，输入对方设备 ID 开始连接。" }
            let label = NSTextField(wrappingLabelWithString: message)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.font = .systemFont(ofSize: 14)
            let container = NSView()
            container.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
                container.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
            ])
            listStack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            return
        }

        for (index, item) in items.enumerated() {
            let row = DeviceRowView(
                item: item,
                isConnecting: snapshot.connectingPeerID == item.device.peerID
            )
            row.onAction = { [weak self] action in
                self?.onDeviceAction?(item.device.id, action)
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            if index < items.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                listStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }
    }

    @objc private func connectQuickly() {
        let peerID = peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerID.isEmpty,
              snapshot.server?.isComplete == true,
              snapshot.connectingPeerID == nil else { return }
        onQuickConnect?(peerID)
    }

    @objc private func openServerSettings() { onOpenServerSettings?() }

    @objc private func filterChanged() { renderDevices() }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class DeviceRowView: NSView {
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
        layer?.cornerRadius = 10

        favoriteButton.bezelStyle = .inline
        favoriteButton.image = NSImage(
            systemSymbolName: item.device.isFavorite ? "star.fill" : "star",
            accessibilityDescription: item.device.isFavorite ? "取消收藏" : "收藏"
        )
        favoriteButton.contentTintColor = item.device.isFavorite ? .systemYellow : .tertiaryLabelColor
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)

        let name = NSTextField(labelWithString: item.device.resolvedDisplayName)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: detailText(item.device))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let identity = NSStackView(views: [name, detail])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 3
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let credential = NSImageView(image: NSImage(
            systemSymbolName: item.hasSavedPassword ? "lock.fill" : "lock.open",
            accessibilityDescription: item.hasSavedPassword ? "已保存密码" : "未保存密码"
        ) ?? NSImage())
        credential.contentTintColor = item.hasSavedPassword ? .secondaryLabelColor : .tertiaryLabelColor
        credential.toolTip = item.hasSavedPassword ? "密码已保存在此 Mac 的钥匙串" : "连接时需要输入密码"

        let connect = NSButton(title: isConnecting ? "连接中…" : "连接", target: self, action: #selector(connect))
        connect.bezelStyle = .rounded
        connect.isEnabled = !isConnecting

        let more = NSButton(
            image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作") ?? NSImage(),
            target: self,
            action: #selector(showMenu)
        )
        more.bezelStyle = .inline
        more.toolTip = "更多操作"

        let row = NSStackView(views: [favoriteButton, identity, NSView(), credential, connect, more])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 66),
            connect.widthAnchor.constraint(equalToConstant: 76),
            credential.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func detailText(_ device: SavedDevice) -> String {
        let id = formatPeerID(device.peerID)
        guard let date = device.lastSuccessfulConnectionAt else {
            return "\(id) · 尚未验证"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "\(id) · \(formatter.localizedString(for: date, relativeTo: Date()))"
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

    @objc private func connect() { onAction?(.connect) }

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
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY), in: sender)
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
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

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
