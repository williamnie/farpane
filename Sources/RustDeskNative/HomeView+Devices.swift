import AppKit
import ConnectionCatalog

extension HomeView {
    func renderDevices() {
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
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
            if !query.isEmpty {
                message = "没有匹配设备"
            } else if favoritesOnly {
                message = "还没有收藏设备"
            } else {
                message = "还没有最近连接，输入对方设备 ID 开始连接。"
            }
            let label = NSTextField(wrappingLabelWithString: message)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.font = .systemFont(ofSize: 14)
            let icon = NSImageView(
                image: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
                    ?? NSImage())
            icon.contentTintColor = .tertiaryLabelColor
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            let container = NSView()
            container.addSubview(label)
            container.addSubview(icon)
            label.translatesAutoresizingMaskIntoConstraints = false
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -16),
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
                label.leadingAnchor.constraint(
                    greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(
                    lessThanOrEqualTo: container.trailingAnchor, constant: -24),
                container.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            ])
            listStack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            return
        }

        for item in items {
            let row = DeviceRowView(
                item: item, isConnecting: snapshot.connectingPeerID == item.device.peerID)
            row.onAction = { [weak self] action in self?.onDeviceAction?(item.device.id, action) }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    @objc func connectQuickly() { performQuickAction(onQuickConnect) }

    @objc func sendFilesQuickly() { performQuickAction(onQuickSendFiles) }
}
